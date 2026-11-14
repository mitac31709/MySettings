#!/usr/bin/env python3
"""Bridge JQuake's offscreen XEmbed tray icon (stalonetray) to Waybar SNI."""
from __future__ import annotations

import asyncio
import os
import signal
import sys
import time
from typing import Any

from dbus_next import BusType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method, signal as dbus_signal
from Xlib import X, display, error as xerror
from Xlib.ext import composite, damage, shape

WATCHER_BUS = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
SNI_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"

# Waybar's sideBar background (#0b0f14). Anti-aliased edges blend onto this
# exact RGB inside stalonetray; near-matching pixels are keyed to transparent.
BG_R, BG_G, BG_B = 0x0B, 0x0F, 0x14
DEBOUNCE_SEC = 0.08
RESCAN_SEC = 2.0


def _decode_wm_class(win) -> tuple[str, ...]:
    try:
        cls = win.get_wm_class()
    except Exception:
        return ()
    if not cls:
        return ()
    return tuple(str(x) for x in cls)


def _decode_wm_name(win) -> str:
    try:
        name = win.get_wm_name()
    except Exception:
        return ""
    if isinstance(name, bytes):
        return name.decode("utf-8", errors="replace")
    return str(name) if name else ""


def _walk_windows(win):
    yield win
    try:
        children = win.query_tree().children
    except Exception:
        return
    for child in children:
        yield from _walk_windows(child)


def _find_jquake_windows(dpy):
    """Return (stalonetray_win, eframe_win, canvas_win), any may be None."""
    root = dpy.screen().root
    tray_win = None
    eframe_win = None
    canvas_win = None

    for w in _walk_windows(root):
        cls = _decode_wm_class(w)
        name = _decode_wm_name(w)
        if "stalonetray" in cls:
            tray_win = w
        if name == "JavaEmbeddedFrame" or (
            "sun-awt-X11-XEmbeddedFramePeer" in cls and "net-jquake-app-Main" in cls
        ):
            eframe_win = w

    if eframe_win is not None:
        for w in _walk_windows(eframe_win):
            if "sun-awt-X11-XCanvasPeer" in _decode_wm_class(w):
                canvas_win = w
                break
        if canvas_win is None:
            canvas_win = eframe_win

    return tray_win, eframe_win, canvas_win


def _rgba_pixmap_from_window(dpy, win) -> tuple[int, int, bytes] | None:
    """Capture redirected X11 window via XComposite as ARGB32 network-order bytes."""
    geom = win.get_geometry()
    width, height, depth = int(geom.width), int(geom.height), int(geom.depth)
    if width <= 0 or height <= 0:
        return None

    pm = composite.name_window_pixmap(win)
    try:
        img = pm.get_image(0, 0, width, height, X.ZPixmap, 0xFFFFFFFF)
    finally:
        pm.free()

    raw = img.data
    if isinstance(raw, str):
        raw = raw.encode("latin-1")
    expected = width * height * 4
    if len(raw) < expected:
        return None

    out = bytearray(expected)
    has_visible = False
    for i in range(0, expected, 4):
        b = raw[i]
        g = raw[i + 1]
        r = raw[i + 2]
        x_a = raw[i + 3]

        if abs(r - BG_R) <= 2 and abs(g - BG_G) <= 2 and abs(b - BG_B) <= 2:
            a = 0
            r = g = b = 0
        elif depth == 32 and x_a == 0 and r == 0 and g == 0 and b == 0:
            a = 0
        else:
            a = x_a if depth == 32 and 0 < x_a < 255 else 255
            if r != 0 or g != 0 or b != 0:
                has_visible = True

        out[i] = a
        out[i + 1] = r
        out[i + 2] = g
        out[i + 3] = b

    if not has_visible:
        return None
    return width, height, bytes(out)


async def _run_cmd(*args: str) -> int:
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        return await proc.wait()
    except Exception:
        return 1


class DbusMenu(ServiceInterface):
    """Minimal com.canonical.dbusmenu for right-clicking JQuake in Waybar tray."""

    def __init__(self, on_activate) -> None:
        super().__init__("com.canonical.dbusmenu")
        self._revision = 1
        self._on_activate = on_activate
        self._items: dict[int, dict[str, Variant]] = {
            0: {"children-display": Variant("s", "submenu")},
            1: {
                "label": Variant("s", "JQuake を開く"),
                "enabled": Variant("b", True),
                "visible": Variant("b", True),
            },
            2: {
                "type": Variant("s", "separator"),
                "visible": Variant("b", True),
            },
            3: {
                "label": Variant("s", "JQuake を再起動"),
                "enabled": Variant("b", True),
                "visible": Variant("b", True),
            },
            4: {
                "label": Variant("s", "JQuake を停止"),
                "enabled": Variant("b", True),
                "visible": Variant("b", True),
            },
        }
        self._children: dict[int, list[int]] = {0: [1, 2, 3, 4]}

    @dbus_property(PropertyAccess.READ)
    def Version(self) -> "u":
        return 3

    @dbus_property(PropertyAccess.READ)
    def TextDirection(self) -> "s":
        return "ltr"

    @dbus_property(PropertyAccess.READ)
    def Status(self) -> "s":
        return "normal"

    @dbus_property(PropertyAccess.READ)
    def IconThemePath(self) -> "as":
        return []

    def _filter_props(self, item_id: int, names: list[str]) -> dict[str, Variant]:
        props = self._items.get(item_id, {})
        if not names:
            return dict(props)
        return {k: v for k, v in props.items() if k in names}

    def _build_node(
        self, item_id: int, depth: int, names: list[str]
    ) -> list[Any]:
        props = self._filter_props(item_id, names)
        children_variants: list[Variant] = []
        if depth != 0 and item_id in self._children:
            next_depth = depth - 1 if depth > 0 else -1
            for cid in self._children[item_id]:
                child_node = self._build_node(cid, next_depth, names)
                children_variants.append(Variant("(ia{sv}av)", child_node))
        return [item_id, props, children_variants]

    @method()
    def GetLayout(
        self, parentId: "i", recursionDepth: "i", propertyNames: "as"
    ) -> "u(ia{sv}av)":
        return [self._revision, self._build_node(parentId, recursionDepth, propertyNames)]

    @method()
    def GetGroupProperties(self, ids: "ai", propertyNames: "as") -> "a(ia{sv})":
        return [[i, self._filter_props(i, propertyNames)] for i in ids if i in self._items]

    @method()
    def GetProperty(self, id: "i", name: "s") -> "v":
        return self._items.get(id, {}).get(name, Variant("s", ""))

    @method()
    def Event(self, id: "i", eventId: "s", data: "v", timestamp: "u"):
        if eventId != "clicked":
            return
        if id == 1:
            asyncio.create_task(self._on_activate())
        elif id == 3:
            asyncio.create_task(_run_cmd("systemctl", "--user", "restart", "jquake.service"))
        elif id == 4:
            asyncio.create_task(_run_cmd("systemctl", "--user", "stop", "jquake.service"))

    @method()
    def EventGroup(self, events: "a(isvu)") -> "ai":
        for id_, event_id, data, ts in events:
            self.Event(id_, event_id, data, ts)
        return []

    @method()
    def AboutToShow(self, id: "i") -> "b":
        return False

    @method()
    def AboutToShowGroup(self, ids: "ai") -> "aiai":
        return [[], []]


class JQuakeSni(ServiceInterface):
    """org.kde.StatusNotifierItem backed by JQuake's offscreen stalonetray icon."""

    def __init__(self, on_activate) -> None:
        super().__init__("org.kde.StatusNotifierItem")
        self._on_activate = on_activate
        self._status = "Passive"
        self._pixmap: list[list[Any]] = []
        self._last_digest: bytes | None = None

    @dbus_property(PropertyAccess.READ)
    def Category(self) -> "s":
        return "ApplicationStatus"

    @dbus_property(PropertyAccess.READ)
    def Id(self) -> "s":
        return "jquake"

    @dbus_property(PropertyAccess.READ)
    def Title(self) -> "s":
        return "JQuake"

    @dbus_property(PropertyAccess.READ)
    def Status(self) -> "s":
        return self._status

    @dbus_property(PropertyAccess.READ)
    def WindowId(self) -> "u":
        return 0

    @dbus_property(PropertyAccess.READ)
    def IconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def IconPixmap(self) -> "a(iiay)":
        return self._pixmap

    @dbus_property(PropertyAccess.READ)
    def OverlayIconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def OverlayIconPixmap(self) -> "a(iiay)":
        return []

    @dbus_property(PropertyAccess.READ)
    def AttentionIconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def AttentionIconPixmap(self) -> "a(iiay)":
        return []

    @dbus_property(PropertyAccess.READ)
    def AttentionMovieName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def ToolTip(self) -> "(sa(iiay)ss)":
        desc = (
            "強震モニタ / EEW（クリックで表示）"
            if self._status == "Active"
            else "JQuake 待機中"
        )
        return ["", [], "JQuake", desc]

    @dbus_property(PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        return False

    @dbus_property(PropertyAccess.READ)
    def Menu(self) -> "o":
        return MENU_PATH

    @method()
    def Activate(self, x: "i", y: "i"):
        asyncio.create_task(self._on_activate())

    @method()
    def SecondaryActivate(self, x: "i", y: "i"):
        asyncio.create_task(self._on_activate())

    @method()
    def ContextMenu(self, x: "i", y: "i"):
        pass

    @method()
    def Scroll(self, delta: "i", orientation: "s"):
        pass

    @dbus_signal()
    def NewIcon(self):
        pass

    @dbus_signal()
    def NewStatus(self, status: "s") -> "s":
        return status

    @dbus_signal()
    def NewTitle(self):
        pass

    @dbus_signal()
    def NewToolTip(self):
        pass

    def update_icon(self, pix: tuple[int, int, bytes] | None) -> None:
        if pix is None:
            changed_status = self._status != "Passive"
            if changed_status or self._pixmap:
                self._status = "Passive"
                self._pixmap = []
                self._last_digest = None
                self.emit_properties_changed({"Status": "Passive", "IconPixmap": []})
                self.NewStatus("Passive")
                self.NewToolTip()
            return

        w, h, data = pix
        if data != self._last_digest:
            self._last_digest = data
            self._pixmap = [[w, h, data]]
            self.emit_properties_changed({"IconPixmap": self._pixmap})
            self.NewIcon()

        if self._status != "Active":
            self._status = "Active"
            self.emit_properties_changed({"Status": "Active"})
            self.NewStatus("Active")
            self.NewToolTip()


class Bridge:
    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.bus: MessageBus | None = None
        self.bus_name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        self.sni = JQuakeSni(self.activate_jquake)
        self.menu = DbusMenu(self.activate_jquake)

        self.dpy: display.Display | None = None
        self.dpy_fd: int | None = None
        self.tray_id: int | None = None
        self.eframe_id: int | None = None
        self.canvas_id: int | None = None
        self.damage_obj: int | None = None
        self.damage_event_base: int | None = None
        self._pending_refresh: asyncio.TimerHandle | None = None
        self._last_refresh = 0.0
        self._stopping = False

    async def start(self) -> None:
        self.bus = await MessageBus(bus_type=BusType.SESSION).connect()
        await self.bus.request_name(self.bus_name)
        self.bus.export(SNI_PATH, self.sni)
        self.bus.export(MENU_PATH, self.menu)

        await self._watch_status_notifier_watcher()
        await self._register_sni()

        while not self._stopping:
            if self.dpy is None:
                self._connect_x11()
            if self.dpy is not None:
                self._attach_and_refresh()
            await asyncio.sleep(RESCAN_SEC)

    def stop(self) -> None:
        self._stopping = True
        self._detach_x11()

    async def _watch_status_notifier_watcher(self) -> None:
        assert self.bus is not None
        introspect = await self.bus.introspect("org.freedesktop.DBus", "/org/freedesktop/DBus")
        proxy = self.bus.get_proxy_object("org.freedesktop.DBus", "/org/freedesktop/DBus", introspect)
        dbus_iface = proxy.get_interface("org.freedesktop.DBus")

        def on_name_owner_changed(name: str, old_owner: str, new_owner: str) -> None:
            if name == WATCHER_BUS and new_owner:
                asyncio.create_task(self._register_sni())

        dbus_iface.on_name_owner_changed(on_name_owner_changed)

    async def _register_sni(self) -> None:
        assert self.bus is not None
        try:
            intro = await self.bus.introspect(WATCHER_BUS, WATCHER_PATH)
            obj = self.bus.get_proxy_object(WATCHER_BUS, WATCHER_PATH, intro)
            watcher = obj.get_interface(WATCHER_BUS)
            await watcher.call_register_status_notifier_item(self.bus_name)
            try:
                watcher.on_status_notifier_host_registered(
                    lambda: asyncio.create_task(self._register_sni())
                )
            except Exception:
                pass
        except Exception:
            pass

    async def activate_jquake(self) -> None:
        disp = os.environ.get("DISPLAY", ":0")
        rc = await _run_cmd(
            "stalonetray",
            "-display",
            disp,
            "--remote-click-icon",
            "JavaEmbeddedFrame",
            "--remote-click-button",
            "1",
            "--remote-click-type",
            "single",
        )
        if rc != 0:
            await _run_cmd("swaymsg", '[class="^net-jquake-app-Main$"]', "focus")

    def _connect_x11(self) -> None:
        disp_name = os.environ.get("DISPLAY") or ":0"
        try:
            dpy = display.Display(disp_name)
        except Exception:
            return

        comp = dpy.query_extension("Composite")
        dmg = dpy.query_extension("DAMAGE")
        if not comp or not comp.present or not dmg or not dmg.present:
            dpy.close()
            return

        composite.query_version(dpy)
        damage.query_version(dpy)
        dpy.screen().root.change_attributes(event_mask=X.SubstructureNotifyMask)
        dpy.flush()

        self.dpy = dpy
        self.damage_event_base = dmg.first_event
        self.dpy_fd = dpy.fileno()
        self.loop.add_reader(self.dpy_fd, self._on_x11_readable)

    def _detach_x11(self) -> None:
        if self._pending_refresh is not None:
            self._pending_refresh.cancel()
            self._pending_refresh = None
        if self.dpy_fd is not None:
            try:
                self.loop.remove_reader(self.dpy_fd)
            except Exception:
                pass
            self.dpy_fd = None
        if self.dpy is not None:
            try:
                self.dpy.close()
            except Exception:
                pass
            self.dpy = None
        self.tray_id = None
        self.eframe_id = None
        self.canvas_id = None
        self.damage_obj = None
        self.sni.update_icon(None)

    def _on_x11_readable(self) -> None:
        dpy = self.dpy
        if dpy is None:
            return
        need_refresh = False
        need_rescan = False
        try:
            while dpy.pending_events():
                ev = dpy.next_event()
                if ev.type == X.DestroyNotify:
                    wid = getattr(ev.window, "id", None)
                    if wid in (self.tray_id, self.eframe_id, self.canvas_id):
                        self.canvas_id = None
                        self.eframe_id = None
                        self.damage_obj = None
                        need_rescan = True
                elif ev.type in (X.CreateNotify, X.MapNotify, X.ReparentNotify):
                    if self.canvas_id is None:
                        need_rescan = True
                elif self.damage_event_base is not None and ev.type == self.damage_event_base:
                    need_refresh = True
        except (xerror.ConnectionClosedError, OSError):
            self._detach_x11()
            return
        except Exception:
            need_rescan = True

        if need_rescan:
            self._attach_and_refresh()
        elif need_refresh:
            self._schedule_refresh()

    def _schedule_refresh(self) -> None:
        if self._pending_refresh is not None:
            return
        elapsed = time.monotonic() - self._last_refresh
        delay = max(0.0, DEBOUNCE_SEC - elapsed)
        self._pending_refresh = self.loop.call_later(delay, self._run_scheduled_refresh)

    def _run_scheduled_refresh(self) -> None:
        self._pending_refresh = None
        self._refresh_icon()

    def _attach_and_refresh(self) -> None:
        dpy = self.dpy
        if dpy is None:
            return
        if self.canvas_id is not None and self._last_digest is not None:
            try:
                win = dpy.create_resource_object("window", self.canvas_id)
                win.get_geometry()
                return
            except (xerror.ConnectionClosedError, OSError):
                self._detach_x11()
                return
            except Exception:
                self.canvas_id = None
                self.damage_obj = None

        try:
            tray_win, eframe_win, canvas_win = _find_jquake_windows(dpy)
            if tray_win is not None and tray_win.id != self.tray_id:
                try:
                    tray_win.shape_rectangles(
                        shape.SO.Set, shape.SK.Input, X.Unsorted, 0, 0, []
                    )
                except Exception:
                    pass
                self.tray_id = tray_win.id

            if canvas_win is None or eframe_win is None or tray_win is None:
                self.eframe_id = None
                self.canvas_id = None
                self.damage_obj = None
                self.sni.update_icon(None)
                dpy.flush()
                return

            if canvas_win.id != self.canvas_id:
                composite.redirect_window(canvas_win, composite.RedirectAutomatic)
                eframe_win.change_attributes(event_mask=X.StructureNotifyMask)
                canvas_win.change_attributes(event_mask=X.StructureNotifyMask)
                self.damage_obj = damage.damage_create(
                    canvas_win, damage.ReportLevelRawRectangles
                )
                dpy.sync()
                self.eframe_id = eframe_win.id
                self.canvas_id = canvas_win.id
        except (xerror.ConnectionClosedError, OSError):
            self._detach_x11()
            return
        except Exception:
            self.canvas_id = None
            self.sni.update_icon(None)
            return

        self._refresh_icon()

    def _refresh_icon(self) -> None:
        dpy = self.dpy
        if dpy is None or self.canvas_id is None:
            self.sni.update_icon(None)
            return
        self._last_refresh = time.monotonic()
        try:
            win = dpy.create_resource_object("window", self.canvas_id)
            if self.damage_obj is not None:
                try:
                    damage.damage_subtract(win, self.damage_obj, X.NONE, X.NONE)
                except Exception:
                    pass
            pix = _rgba_pixmap_from_window(dpy, win)
            dpy.flush()
        except (xerror.ConnectionClosedError, OSError):
            self._detach_x11()
            return
        except Exception:
            self.canvas_id = None
            self.sni.update_icon(None)
            return

        self.sni.update_icon(pix)


def main() -> int:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    bridge = Bridge(loop)

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, bridge.stop)

    try:
        loop.run_until_complete(bridge.start())
    finally:
        bridge.stop()
        loop.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
