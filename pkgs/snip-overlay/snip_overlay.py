#!/usr/bin/env python3
"""Windows Snipping Tool-style interactive screenshot overlay for Hyprland (GTK4 + layer-shell)."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import cairo
import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Gtk4LayerShell  # noqa: E402

from snip_core import (  # noqa: E402
    MonitorInfo,
    WindowRect,
    crop_freeform_surface,
    crop_rect_surface,
    hit_test_window,
    logical_rect_to_pixel_rect,
    normalize_rect,
    parse_monitors,
    windows_for_monitor,
)


DEFAULT_THEME = {
    "bg": "#0d1117",
    "surface": "#131922",
    "surfaceAlt": "#1a2330",
    "surfaceHover": "#222e3f",
    "border": "#263344",
    "borderStrong": "#35475e",
    "fg": "#e8eef5",
    "fgSecondary": "#a3b1c2",
    "fgMuted": "#637286",
    "accent": "#56d4c8",
    "accentAlt": "#4ea8de",
    "accentSoft": "#16333a",
    "danger": "#f07178",
    "dangerSoft": "#3b1c24",
    "radiusPopup": 12,
    "radiusControl": 8,
}


def hex_to_rgb(hex_color: str) -> tuple[float, float, float]:
    h = hex_color.lstrip("#")
    if len(h) != 6:
        return (0.34, 0.83, 0.78)
    return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0, int(h[4:6], 16) / 255.0)


def load_theme(path: str | None) -> dict:
    theme = dict(DEFAULT_THEME)
    if path and os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                theme.update(data)
        except Exception:
            pass
    return theme


def run_hyprctl_json(subcmd: str) -> list[dict]:
    proc = subprocess.run(
        ["hyprctl", subcmd, "-j"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    try:
        data = json.loads(proc.stdout)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def capture_monitors(monitors: list[MonitorInfo], tmp_dir: str) -> dict[str, cairo.ImageSurface]:
    def _grab(mon: MonitorInfo) -> tuple[str, str]:
        out_path = os.path.join(tmp_dir, f"mon-{mon.name}.png")
        subprocess.run(["grim", "-o", mon.name, out_path], check=True)
        return (mon.name, out_path)

    surfaces: dict[str, cairo.ImageSurface] = {}
    with ThreadPoolExecutor(max_workers=max(1, len(monitors))) as pool:
        for name, png_path in pool.map(_grab, monitors):
            surfaces[name] = cairo.ImageSurface.create_from_png(png_path)
    return surfaces


def build_css(t: dict) -> bytes:
    css = f"""
    window.snip-window {{
      background: transparent;
    }}

    .snip-toolbar {{
      background-color: alpha({t["surface"]}, 0.94);
      border: 1px solid {t["borderStrong"]};
      border-radius: {t["radiusPopup"]}px;
      padding: 6px 8px;
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.50);
    }}

    .snip-toolbar button {{
      background: transparent;
      color: {t["fg"]};
      border: 1px solid transparent;
      border-radius: {t["radiusControl"]}px;
      padding: 6px 11px;
      min-height: 28px;
      font-weight: 600;
      font-size: 13px;
      transition: background-color 120ms ease, border-color 120ms ease, color 120ms ease;
    }}

    .snip-toolbar button:hover {{
      background-color: {t["surfaceHover"]};
      border-color: {t["borderStrong"]};
    }}

    .snip-toolbar button.active-mode {{
      background-color: {t["accentSoft"]};
      color: {t["accent"]};
      border-color: {t["accent"]};
    }}

    .snip-toolbar button.action-quick {{
      background-color: {t["surfaceAlt"]};
      color: {t["accentAlt"]};
      border-color: {t["accentAlt"]};
    }}

    .snip-toolbar button.close-btn {{
      color: {t["fgSecondary"]};
      padding: 6px 10px;
    }}

    .snip-toolbar button.close-btn:hover {{
      background-color: {t["dangerSoft"]};
      color: {t["danger"]};
      border-color: {t["danger"]};
    }}

    .snip-sep {{
      background-color: {t["border"]};
      min-width: 1px;
      margin: 4px 4px;
    }}

    .snip-hint {{
      background-color: alpha({t["bg"]}, 0.84);
      color: {t["fgSecondary"]};
      border: 1px solid {t["border"]};
      border-radius: 999px;
      padding: 5px 14px;
      font-size: 12px;
    }}
    """
    return css.encode("utf-8")


MODE_HINTS = {
    "region": "ドラッグで範囲選択  │  1:範囲  2:自由  3:ウィンドウ  4:全画面  E:編集切替  Esc:閉じる",
    "freeform": "ドラッグで自由選択（閉じた範囲を切り抜き）  │  1:範囲  2:自由  3:ウィンドウ  4:全画面  Esc:閉じる",
    "window": "ウィンドウをクリックして撮影  │  1:範囲  2:自由  3:ウィンドウ  4:全画面  Esc:閉じる",
    "full": "クリックまたは Enter で全画面撮影  │  1:範囲  2:自由  3:ウィンドウ  4:全画面  Esc:閉じる",
}


class SnipOverlayApp(Gtk.Application):
    def __init__(
        self,
        initial_mode: str,
        initial_action: str,
        output_path: str,
        theme: dict,
        monitors: list[MonitorInfo],
        surfaces: dict[str, cairo.ImageSurface],
        windows_by_mon: dict[str, list[WindowRect]],
    ) -> None:
        super().__init__(
            application_id="dev.mitac.snip-overlay",
            flags=Gio.ApplicationFlags.NON_UNIQUE,
        )
        self.mode = initial_mode
        self.action = initial_action  # "edit" or "quick"
        self.output_path = output_path
        self.theme = theme
        self.accent_rgb = hex_to_rgb(theme["accent"])
        self.bg_rgb = hex_to_rgb(theme["bg"])
        self.fg_rgb = hex_to_rgb(theme["fg"])

        self.monitors = monitors
        self.surfaces = surfaces
        self.windows_by_mon = windows_by_mon
        self.overlay_windows: list[MonitorOverlayWindow] = []
        self.result: dict | None = None
        self.finished = False

        self.mode_buttons: dict[str, Gtk.Button] = {}
        self.action_button: Gtk.Button | None = None
        self.hint_label: Gtk.Label | None = None
        self.toolbar_box: Gtk.Box | None = None
        self.hint_box: Gtk.Box | None = None

    def do_activate(self) -> None:
        display = Gdk.Display.get_default()
        if display is None:
            self.quit()
            return

        provider = Gtk.CssProvider()
        provider.load_from_data(build_css(self.theme))
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        gdk_monitors: dict[str, Gdk.Monitor] = {}
        mon_list = display.get_monitors()
        for i in range(mon_list.get_n_items()):
            gm = mon_list.get_item(i)
            if isinstance(gm, Gdk.Monitor) and gm.get_connector():
                gdk_monitors[gm.get_connector()] = gm

        focused_mon = next((m for m in self.monitors if m.focused), self.monitors[0])

        for mon in self.monitors:
            surf = self.surfaces.get(mon.name)
            if surf is None:
                continue
            is_primary = mon.name == focused_mon.name
            win = MonitorOverlayWindow(
                app=self,
                monitor=mon,
                gdk_monitor=gdk_monitors.get(mon.name),
                surface=surf,
                windows=self.windows_by_mon.get(mon.name, []),
                show_toolbar=is_primary,
            )
            self.overlay_windows.append(win)
            win.present()

        self.sync_ui_state()

    def set_mode(self, mode: str, from_user_trigger: bool = False) -> None:
        if mode not in ("region", "freeform", "window", "full"):
            return
        self.mode = mode
        for w in self.overlay_windows:
            w.reset_interaction()
        self.sync_ui_state()

        # On single-monitor setups, explicitly clicking/pressing "Full" captures immediately
        # just like Windows Snipping Tool.
        if mode == "full" and from_user_trigger and len(self.overlay_windows) == 1:
            self.capture_fullscreen(self.overlay_windows[0])

    def toggle_action(self) -> None:
        self.action = "quick" if self.action == "edit" else "edit"
        self.sync_ui_state()

    def set_dragging_ui_hidden(self, dragging: bool) -> None:
        if self.toolbar_box is not None:
            self.toolbar_box.set_opacity(0.15 if dragging else 1.0)
            self.toolbar_box.set_can_target(not dragging)
        if self.hint_box is not None:
            self.hint_box.set_visible(not dragging)

    def sync_ui_state(self) -> None:
        for m, btn in self.mode_buttons.items():
            if m == self.mode:
                btn.add_css_class("active-mode")
            else:
                btn.remove_css_class("active-mode")

        if self.action_button is not None:
            if self.action == "edit":
                self.action_button.set_label("󰏫 編集")
                self.action_button.set_tooltip_text("撮影後に Satty で編集（クリックまたは E で即コピーへ切替）")
                self.action_button.remove_css_class("action-quick")
            else:
                self.action_button.set_label("󰆏 即コピー")
                self.action_button.set_tooltip_text("撮影後にクリップボードへ即コピー（クリックまたは E で編集へ切替）")
                self.action_button.add_css_class("action-quick")

        if self.hint_label is not None:
            self.hint_label.set_text(MODE_HINTS.get(self.mode, ""))

        cursor_name = "crosshair" if self.mode in ("region", "freeform") else "pointer"
        for w in self.overlay_windows:
            w.canvas.set_cursor_from_name(cursor_name)
            w.canvas.queue_draw()

    def handle_key(self, keyval: int) -> bool:
        if keyval == Gdk.KEY_Escape:
            self.cancel()
            return True
        if keyval in (Gdk.KEY_1, Gdk.KEY_r, Gdk.KEY_R):
            self.set_mode("region", from_user_trigger=True)
            return True
        if keyval in (Gdk.KEY_2, Gdk.KEY_f, Gdk.KEY_F):
            self.set_mode("freeform", from_user_trigger=True)
            return True
        if keyval in (Gdk.KEY_3, Gdk.KEY_w, Gdk.KEY_W):
            self.set_mode("window", from_user_trigger=True)
            return True
        if keyval in (Gdk.KEY_4, Gdk.KEY_s, Gdk.KEY_S):
            self.set_mode("full", from_user_trigger=True)
            return True
        if keyval in (Gdk.KEY_e, Gdk.KEY_E):
            self.toggle_action()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            if self.mode == "full" and self.overlay_windows:
                target = next((w for w in self.overlay_windows if w.pointer_inside), self.overlay_windows[0])
                self.capture_fullscreen(target)
                return True
        return False

    def capture_rect(self, win: MonitorOverlayWindow, lx: float, ly: float, lw: float, lh: float) -> None:
        if self.finished:
            return
        alloc_w = float(win.canvas.get_width())
        alloc_h = float(win.canvas.get_height())
        px, py, pw, ph = logical_rect_to_pixel_rect(
            lx, ly, lw, lh, alloc_w, alloc_h, win.surface.get_width(), win.surface.get_height()
        )
        out = crop_rect_surface(win.surface, px, py, pw, ph)
        self._finish_with_surface(out, self.mode)

    def capture_freeform(self, win: MonitorOverlayWindow, points: list[tuple[float, float]]) -> None:
        if self.finished:
            return
        alloc_w = float(win.canvas.get_width())
        alloc_h = float(win.canvas.get_height())
        out = crop_freeform_surface(win.surface, points, alloc_w, alloc_h)
        if out is None:
            return
        self._finish_with_surface(out, "freeform")

    def capture_fullscreen(self, win: MonitorOverlayWindow) -> None:
        if self.finished:
            return
        self._finish_with_surface(win.surface, "full")

    def _finish_with_surface(self, surface: cairo.ImageSurface, mode: str) -> None:
        self.finished = True
        Path(self.output_path).parent.mkdir(parents=True, exist_ok=True)
        surface.write_to_png(self.output_path)
        self.result = {
            "ok": True,
            "mode": mode,
            "action": self.action,
            "path": self.output_path,
        }
        self._close_all()

    def cancel(self) -> None:
        if self.finished:
            return
        self.finished = True
        self.result = None
        self._close_all()

    def _close_all(self) -> None:
        for w in list(self.overlay_windows):
            w.close()
        self.quit()


class MonitorOverlayWindow(Gtk.ApplicationWindow):
    def __init__(
        self,
        app: SnipOverlayApp,
        monitor: MonitorInfo,
        gdk_monitor: Gdk.Monitor | None,
        surface: cairo.ImageSurface,
        windows: list[WindowRect],
        show_toolbar: bool,
    ) -> None:
        super().__init__(application=app)
        self.app = app
        self.monitor = monitor
        self.surface = surface
        self.windows = windows
        self.pointer_inside = show_toolbar

        self.dragging = False
        self.drag_start = (0.0, 0.0)
        self.drag_current = (0.0, 0.0)
        self.freeform_points: list[tuple[float, float]] = []
        self.hovered_window: WindowRect | None = None

        self.add_css_class("snip-window")
        self.set_decorated(False)

        Gtk4LayerShell.init_for_window(self)
        Gtk4LayerShell.set_layer(self, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_namespace(self, "snip-overlay")
        Gtk4LayerShell.set_exclusive_zone(self, -1)
        for edge in (
            Gtk4LayerShell.Edge.TOP,
            Gtk4LayerShell.Edge.BOTTOM,
            Gtk4LayerShell.Edge.LEFT,
            Gtk4LayerShell.Edge.RIGHT,
        ):
            Gtk4LayerShell.set_anchor(self, edge, True)
        if gdk_monitor is not None:
            Gtk4LayerShell.set_monitor(self, gdk_monitor)
        Gtk4LayerShell.set_keyboard_mode(
            self,
            Gtk4LayerShell.KeyboardMode.EXCLUSIVE
            if show_toolbar
            else Gtk4LayerShell.KeyboardMode.ON_DEMAND,
        )

        overlay = Gtk.Overlay()
        self.canvas = Gtk.DrawingArea()
        self.canvas.set_hexpand(True)
        self.canvas.set_vexpand(True)
        self.canvas.set_draw_func(self._on_draw)
        overlay.set_child(self.canvas)

        if show_toolbar:
            toolbar = self._build_toolbar()
            overlay.add_overlay(toolbar)
            app.toolbar_box = toolbar

            hint_box = self._build_hint()
            overlay.add_overlay(hint_box)
            app.hint_box = hint_box

        self.set_child(overlay)
        self._setup_controllers()

    def _build_toolbar(self) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        box.add_css_class("snip-toolbar")
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.START)
        box.set_margin_top(18)

        modes = [
            ("region", "󰆞 範囲", "四角形モード (1 / R)"),
            ("freeform", "󰙴 自由", "フリーフォームモード (2 / F)"),
            ("window", "󰖯 ウィンドウ", "ウィンドウモード (3 / W)"),
            ("full", "󰊓 全画面", "全画面モード (4 / S)"),
        ]
        for key, label, tip in modes:
            btn = Gtk.Button(label=label)
            btn.set_tooltip_text(tip)
            btn.set_focusable(False)
            btn.connect("clicked", lambda _b, m=key: self.app.set_mode(m, from_user_trigger=True))
            box.append(btn)
            self.app.mode_buttons[key] = btn

        sep1 = Gtk.Box()
        sep1.add_css_class("snip-sep")
        box.append(sep1)

        action_btn = Gtk.Button(label="󰏫 編集")
        action_btn.set_focusable(False)
        action_btn.connect("clicked", lambda _b: self.app.toggle_action())
        box.append(action_btn)
        self.app.action_button = action_btn

        sep2 = Gtk.Box()
        sep2.add_css_class("snip-sep")
        box.append(sep2)

        close_btn = Gtk.Button(label="✕")
        close_btn.add_css_class("close-btn")
        close_btn.set_tooltip_text("キャンセル (Esc)")
        close_btn.set_focusable(False)
        close_btn.connect("clicked", lambda _b: self.app.cancel())
        box.append(close_btn)

        return box

    def _build_hint(self) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.END)
        box.set_margin_bottom(22)
        box.set_can_target(False)

        lbl = Gtk.Label(label="")
        lbl.add_css_class("snip-hint")
        box.append(lbl)
        self.app.hint_label = lbl
        return box

    def _setup_controllers(self) -> None:
        key_ctrl = Gtk.EventControllerKey()
        key_ctrl.connect("key-pressed", self._on_key_pressed)
        self.add_controller(key_ctrl)

        motion = Gtk.EventControllerMotion()
        motion.connect("enter", self._on_motion_enter)
        motion.connect("motion", self._on_motion)
        motion.connect("leave", self._on_motion_leave)
        self.canvas.add_controller(motion)

        drag = Gtk.GestureDrag()
        drag.set_button(Gdk.BUTTON_PRIMARY)
        drag.connect("drag-begin", self._on_drag_begin)
        drag.connect("drag-update", self._on_drag_update)
        drag.connect("drag-end", self._on_drag_end)
        self.canvas.add_controller(drag)

        rclick = Gtk.GestureClick()
        rclick.set_button(Gdk.BUTTON_SECONDARY)
        rclick.connect("pressed", self._on_right_click)
        self.canvas.add_controller(rclick)

    def reset_interaction(self) -> None:
        self.dragging = False
        self.freeform_points = []
        self.app.set_dragging_ui_hidden(False)
        self.canvas.queue_draw()

    def _on_key_pressed(self, _ctrl, keyval: int, _keycode: int, _state) -> bool:
        return self.app.handle_key(keyval)

    def _on_motion_enter(self, _ctrl, x: float, y: float) -> None:
        self.pointer_inside = True
        self._update_hover(x, y)

    def _on_motion(self, _ctrl, x: float, y: float) -> None:
        self.pointer_inside = True
        self._update_hover(x, y)

    def _on_motion_leave(self, _ctrl) -> None:
        self.pointer_inside = False
        self.hovered_window = None
        self.canvas.queue_draw()

    def _update_hover(self, x: float, y: float) -> None:
        if self.app.mode == "window":
            hit = hit_test_window(self.windows, x, y)
            if hit != self.hovered_window:
                self.hovered_window = hit
                self.canvas.queue_draw()
        elif self.app.mode == "full":
            self.canvas.queue_draw()

    def _on_right_click(self, _gesture, _n_press: int, _x: float, _y: float) -> None:
        if self.dragging:
            self.reset_interaction()
        else:
            self.app.cancel()

    def _on_drag_begin(self, _gesture, start_x: float, start_y: float) -> None:
        mode = self.app.mode
        if mode == "full":
            self.app.capture_fullscreen(self)
            return
        if mode == "window":
            hit = hit_test_window(self.windows, start_x, start_y)
            if hit is not None:
                self.app.capture_rect(self, hit.x, hit.y, hit.w, hit.h)
            else:
                self.app.capture_fullscreen(self)
            return

        self.dragging = True
        self.drag_start = (start_x, start_y)
        self.drag_current = (start_x, start_y)
        self.freeform_points = [(start_x, start_y)]
        self.app.set_dragging_ui_hidden(True)
        self.canvas.queue_draw()

    def _on_drag_update(self, _gesture, offset_x: float, offset_y: float) -> None:
        if not self.dragging:
            return
        cx = self.drag_start[0] + offset_x
        cy = self.drag_start[1] + offset_y
        self.drag_current = (cx, cy)
        if self.app.mode == "freeform":
            lx, ly = self.freeform_points[-1]
            if math.hypot(cx - lx, cy - ly) >= 3.0:
                self.freeform_points.append((cx, cy))
        self.canvas.queue_draw()

    def _on_drag_end(self, _gesture, offset_x: float, offset_y: float) -> None:
        if not self.dragging:
            return
        cx = self.drag_start[0] + offset_x
        cy = self.drag_start[1] + offset_y
        self.dragging = False
        self.app.set_dragging_ui_hidden(False)

        if self.app.mode == "region":
            x, y, w, h = normalize_rect(self.drag_start[0], self.drag_start[1], cx, cy)
            if w >= 4.0 and h >= 4.0:
                self.app.capture_rect(self, x, y, w, h)
                return
        elif self.app.mode == "freeform":
            self.freeform_points.append((cx, cy))
            if len(self.freeform_points) >= 3:
                self.app.capture_freeform(self, self.freeform_points)
                return

        self.freeform_points = []
        self.canvas.queue_draw()

    def _draw_frozen_bg(self, cr: cairo.Context, width: int, height: int) -> None:
        cr.save()
        img_w = self.surface.get_width()
        img_h = self.surface.get_height()
        if img_w > 0 and img_h > 0:
            cr.scale(width / img_w, height / img_h)
            cr.set_source_surface(self.surface, 0, 0)
            cr.paint()
        cr.restore()

    def _draw_badge(self, cr: cairo.Context, x: float, y: float, text: str, max_w: int, max_h: int) -> None:
        cr.save()
        cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(12.5)
        ext = cr.text_extents(text)
        pad_x = 9.0
        pad_y = 5.0
        bw = ext.width + pad_x * 2
        bh = ext.height + pad_y * 2
        bx = max(8.0, min(max_w - bw - 8.0, x))
        by = max(8.0, min(max_h - bh - 8.0, y))

        r = 6.0
        cr.new_sub_path()
        cr.arc(bx + bw - r, by + r, r, -math.pi / 2, 0)
        cr.arc(bx + bw - r, by + bh - r, r, 0, math.pi / 2)
        cr.arc(bx + r, by + bh - r, r, math.pi / 2, math.pi)
        cr.arc(bx + r, by + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

        br, bg, bb = self.app.bg_rgb
        cr.set_source_rgba(br, bg, bb, 0.88)
        cr.fill_preserve()
        ar, ag, ab = self.app.accent_rgb
        cr.set_source_rgba(ar, ag, ab, 0.85)
        cr.set_line_width(1.0)
        cr.stroke()

        fr, fg, fb = self.app.fg_rgb
        cr.set_source_rgba(fr, fg, fb, 0.96)
        cr.move_to(bx + pad_x - ext.x_bearing, by + pad_y - ext.y_bearing)
        cr.show_text(text)
        cr.restore()

    def _on_draw(self, _area, cr: cairo.Context, width: int, height: int) -> None:
        if width <= 0 or height <= 0:
            return

        # 1. Frozen screenshot
        self._draw_frozen_bg(cr, width, height)

        # 2. Dark dim veil
        br, bg, bb = self.app.bg_rgb
        ar, ag, ab = self.app.accent_rgb
        mode = self.app.mode

        dim_alpha = 0.22 if (mode == "full" and self.pointer_inside) else 0.50
        cr.set_source_rgba(br, bg, bb, dim_alpha)
        cr.rectangle(0, 0, width, height)
        cr.fill()

        # 3. Mode-specific clear cutout & highlight
        if mode == "region" and self.dragging:
            rx, ry, rw, rh = normalize_rect(
                self.drag_start[0], self.drag_start[1], self.drag_current[0], self.drag_current[1]
            )
            if rw >= 1.0 and rh >= 1.0:
                cr.save()
                cr.rectangle(rx, ry, rw, rh)
                cr.clip()
                self._draw_frozen_bg(cr, width, height)
                cr.restore()

                cr.set_source_rgba(ar, ag, ab, 0.95)
                cr.set_line_width(2.0)
                cr.rectangle(rx + 0.5, ry + 0.5, max(1.0, rw - 1.0), max(1.0, rh - 1.0))
                cr.stroke()

                # Corner ticks
                tick = min(10.0, rw / 3.0, rh / 3.0)
                cr.set_line_width(3.0)
                for cx, cy, dx, dy in (
                    (rx, ry, tick, tick),
                    (rx + rw, ry, -tick, tick),
                    (rx, ry + rh, tick, -tick),
                    (rx + rw, ry + rh, -tick, -tick),
                ):
                    cr.move_to(cx, cy + dy)
                    cr.line_to(cx, cy)
                    cr.line_to(cx + dx, cy)
                    cr.stroke()

                _, _, pw, ph = logical_rect_to_pixel_rect(
                    rx, ry, rw, rh, width, height, self.surface.get_width(), self.surface.get_height()
                )
                badge_y = ry - 32.0 if ry >= 38.0 else ry + 8.0
                self._draw_badge(cr, rx, badge_y, f"{pw} × {ph}", width, height)

        elif mode == "freeform" and self.dragging and len(self.freeform_points) >= 2:
            cr.save()
            cr.move_to(*self.freeform_points[0])
            for pt in self.freeform_points[1:]:
                cr.line_to(*pt)
            cr.close_path()
            cr.clip()
            self._draw_frozen_bg(cr, width, height)
            cr.restore()

            cr.save()
            cr.move_to(*self.freeform_points[0])
            for pt in self.freeform_points[1:]:
                cr.line_to(*pt)
            cr.close_path()
            cr.set_source_rgba(ar, ag, ab, 0.95)
            cr.set_line_width(2.2)
            cr.stroke()
            cr.restore()

        elif mode == "window" and self.hovered_window is not None:
            w = self.hovered_window
            cr.save()
            cr.rectangle(w.x, w.y, w.w, w.h)
            cr.clip()
            self._draw_frozen_bg(cr, width, height)
            cr.restore()

            cr.set_source_rgba(ar, ag, ab, 0.95)
            cr.set_line_width(2.5)
            cr.rectangle(w.x + 1.0, w.y + 1.0, max(1.0, w.w - 2.0), max(1.0, w.h - 2.0))
            cr.stroke()

            _, _, pw, ph = logical_rect_to_pixel_rect(
                w.x, w.y, w.w, w.h, width, height, self.surface.get_width(), self.surface.get_height()
            )
            title = w.title.strip() or w.class_name.strip() or "Window"
            if len(title) > 36:
                title = title[:35] + "…"
            badge_y = w.y - 32.0 if w.y >= 38.0 else w.y + 10.0
            self._draw_badge(cr, w.x + 8.0, badge_y, f"{title}  ({pw} × {ph})", width, height)

        elif mode == "full" and self.pointer_inside:
            cr.set_source_rgba(ar, ag, ab, 0.95)
            cr.set_line_width(4.0)
            cr.rectangle(2.0, 2.0, max(1.0, width - 4.0), max(1.0, height - 4.0))
            cr.stroke()
            label = f"全画面: {self.monitor.name} ({self.surface.get_width()} × {self.surface.get_height()})"
            self._draw_badge(cr, width / 2.0 - 110.0, height - 76.0, label, width, height)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Windows Snipping Tool-style interactive screenshot overlay for Hyprland."
    )
    parser.add_argument(
        "--mode",
        choices=("region", "freeform", "window", "full"),
        default="region",
        help="Initial capture mode.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output PNG file path.",
    )
    action_group = parser.add_mutually_exclusive_group()
    action_group.add_argument(
        "--edit",
        dest="action",
        action="store_const",
        const="edit",
        help="Default post-capture action: open in Satty.",
    )
    action_group.add_argument(
        "--quick",
        dest="action",
        action="store_const",
        const="quick",
        help="Default post-capture action: copy to clipboard immediately.",
    )
    parser.set_defaults(action="edit")
    parser.add_argument(
        "--theme-json",
        default=None,
        help="Optional JSON file overriding UI theme colors.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    lock_path = os.path.join(runtime_dir, "snip-overlay.lock")
    lock_file = open(lock_path, "w", encoding="utf-8")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 1

    try:
        monitors = parse_monitors(run_hyprctl_json("monitors"))
        if not monitors:
            print("snip-overlay: no active Hyprland monitors found", file=sys.stderr)
            return 2

        clients_raw = run_hyprctl_json("clients")
        windows_by_mon = {m.name: windows_for_monitor(clients_raw, m) for m in monitors}
        theme = load_theme(args.theme_json)

        with tempfile.TemporaryDirectory(prefix="snip-overlay-") as tmp_dir:
            surfaces = capture_monitors(monitors, tmp_dir)
            app = SnipOverlayApp(
                initial_mode=args.mode,
                initial_action=args.action,
                output_path=args.output,
                theme=theme,
                monitors=monitors,
                surfaces=surfaces,
                windows_by_mon=windows_by_mon,
            )
            app.run(None)

        if app.result is None:
            return 1

        print(json.dumps(app.result, ensure_ascii=False))
        return 0
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock_file.close()


if __name__ == "__main__":
    raise SystemExit(main())
