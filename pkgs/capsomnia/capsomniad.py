#!/usr/bin/env python3
"""User session daemon for Capsomnia on NixOS/Sway."""

from __future__ import annotations

import glob
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from capsomnia_core import (  # noqa: E402
    VERSION,
    AutoOffTimerState,
    LidOpenLockTracker,
    clamp_auto_off_minutes,
    err_response,
    format_compact_duration,
    format_countdown,
    is_mobile_hotspot_route,
    load_prefs,
    normalize_prefs,
    ok_response,
    parse_bool_str,
    parse_default_route_json,
    parse_duration_seconds,
    parse_lid_state_text,
    resolve_language,
    save_prefs,
    should_reassert_on_external_off,
    xdg_config_path,
    xdg_state_dir,
    runtime_dir,
)

HELPER_SOCKET_DEFAULT = "/run/capsomnia/helper.sock"
WAYBAR_SIGNAL_NUM = signal.SIGRTMIN + 15
POLL_INTERVAL_MS = 250
SLEEP_VERIFY_INTERVAL_SEC = 10.0
HELPER_RETRY_INTERVAL_SEC = 5.0
HOTSPOT_INTERVAL_SEC = 60.0
OFF_DEBOUNCE_SEC = 0.35
USER_BYPASS_EXTERNAL_GUARD_SEC = 3.0


def log(msg: str) -> None:
    print(f"capsomniad: {msg}", flush=True)


def find_sway_socket() -> str | None:
    env_sock = os.environ.get("SWAYSOCK")
    if env_sock and Path(env_sock).is_socket():
        return env_sock
    rt = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    matches = sorted(glob.glob(f"{rt}/sway-ipc.{os.getuid()}.*.sock"))
    for m in matches:
        if Path(m).is_socket():
            return m
    return None


def run_swaymsg(*args: str, timeout: float = 2.0) -> tuple[bool, str]:
    sock = find_sway_socket()
    if not sock:
        return False, "sway socket unavailable"
    try:
        proc = subprocess.run(
            ["swaymsg", "-s", sock, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode == 0, proc.stdout.strip()
    except (OSError, subprocess.SubprocessError) as err:
        return False, str(err)


def get_builtin_output_name() -> str | None:
    ok, out = run_swaymsg("-t", "get_outputs")
    if not ok or not out:
        return None
    try:
        outputs = json.loads(out)
    except json.JSONDecodeError:
        return None
    if not isinstance(outputs, list):
        return None
    for item in outputs:
        name = str(item.get("name") or "")
        if name.startswith("eDP"):
            return name
    return None


def read_lid_closed() -> bool | None:
    paths = sorted(glob.glob("/proc/acpi/button/lid/*/state"))
    for p in paths:
        try:
            text = Path(p).read_text(encoding="utf-8")
        except OSError:
            continue
        parsed = parse_lid_state_text(text)
        if parsed is not None:
            return parsed
    return None


def is_swaylock_running() -> bool | None:
    try:
        proc = subprocess.run(
            ["pgrep", "-x", "swaylock"],
            capture_output=True,
            check=False,
        )
        if proc.returncode == 0:
            return True
        proc2 = subprocess.run(
            ["pgrep", "-x", ".swaylock-wrapped"],
            capture_output=True,
            check=False,
        )
        return proc2.returncode == 0
    except OSError:
        return None


def read_backlight_info() -> tuple[str, int, int] | None:
    """Return (device_name, raw_brightness, max_brightness)."""
    try:
        proc = subprocess.run(
            ["brightnessctl", "-m", "-c", "backlight", "info"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        if proc.returncode != 0:
            return None
        line = proc.stdout.strip().splitlines()[0]
        parts = line.split(",")
        if len(parts) < 5:
            return None
        return parts[0], int(parts[2]), int(parts[4])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def set_backlight_raw(device: str, raw: int) -> bool:
    try:
        proc = subprocess.run(
            ["brightnessctl", "-q", "-d", device, "set", str(max(0, raw))],
            capture_output=True,
            timeout=2.0,
            check=False,
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def notify_waybar() -> None:
    try:
        subprocess.run(
            [
                "systemctl",
                "--user",
                "kill",
                "--kill-who=main",
                "--signal=RTMIN+15",
                "waybar.service",
            ],
            capture_output=True,
            check=False,
        )
    except OSError:
        pass


class CapsomniaDaemon:
    def __init__(self) -> None:
        self.helper_socket = os.environ.get("CAPS_HELPER_SOCKET", HELPER_SOCKET_DEFAULT)
        self.rt_dir = runtime_dir()
        self.state_dir = xdg_state_dir()
        self.config_path = xdg_config_path()
        self.control_socket_path = self.rt_dir / "control.sock"
        self.waybar_json_path = self.rt_dir / "waybar.json"
        self.keep_display_marker = self.rt_dir / "keep-display-awake"
        self.brightness_backup_path = self.state_dir / "saved-brightness.json"

        self.prefs = load_prefs(self.config_path)
        self.timer = AutoOffTimerState()
        self.timer.set_saved_default(self.prefs["auto_off_minutes"])
        self.lid_lock_tracker = LidOpenLockTracker()

        self.awake_on = False
        self.confirmed_sleep_inhibited = False
        self.helper_connected = False
        self.status_error = False
        self.last_error_msg: str | None = None
        self.inhibit_fd: int | None = None

        self.did_power_off_builtin_display = False
        self.dimmed_device: str | None = None
        self.applied_xkb_dedicated: bool | None = None
        self.applied_shortcut: str | None = None

        self.user_action_bypass_until = 0.0
        self.pending_off_at: float | None = None
        self.auto_off_in_progress = False
        self.next_verify_at = 0.0
        self.next_helper_retry_at = 0.0
        self.next_hotspot_probe_at = 0.0
        self.hotspot_active = False

        self.last_waybar_payload: str | None = None
        self.last_waybar_tick_sec: int | None = None

        self.bus: Gio.DBusConnection | None = None
        self.loop = GLib.MainLoop()
        self.lock = threading.RLock()
        self._stop_event = threading.Event()
        self._helper_sub_sock: socket.socket | None = None

    def helper_call(self, payload: dict[str, Any], timeout: float = 2.0) -> dict[str, Any]:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            sock.connect(self.helper_socket)
            sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if not buf:
                return {"ok": False, "error": "empty helper response"}
            return json.loads(buf.decode("utf-8", errors="replace").splitlines()[0])
        except (OSError, json.JSONDecodeError) as err:
            return {"ok": False, "error": str(err)}
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def acquire_inhibitor(self) -> bool:
        if self.inhibit_fd is not None:
            return True
        try:
            if self.bus is None:
                self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            msg_params = GLib.Variant(
                "(ssss)",
                (
                    "handle-lid-switch:sleep:idle",
                    "Capsomnia",
                    "Caps Lock keep-awake switch is ON",
                    "block",
                ),
            )
            res, fd_list = self.bus.call_with_unix_fd_list_sync(
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "Inhibit",
                msg_params,
                GLib.VariantType("(h)"),
                Gio.DBusCallFlags.NONE,
                3000,
                None,
                None,
            )
            idx = res.unpack()[0]
            raw_fd = fd_list.get(idx)
            self.inhibit_fd = os.dup(raw_fd)
            return True
        except Exception as err:
            self.last_error_msg = f"logind Inhibit failed: {err}"
            log(self.last_error_msg)
            return False

    def release_inhibitor(self) -> bool:
        if self.inhibit_fd is not None:
            try:
                os.close(self.inhibit_fd)
            except OSError:
                pass
            self.inhibit_fd = None
        return True

    def verify_inhibitor_present(self) -> bool:
        try:
            if self.bus is None:
                self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            res = self.bus.call_sync(
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "ListInhibitors",
                None,
                GLib.VariantType("(a(ssssuu))"),
                Gio.DBusCallFlags.NONE,
                3000,
                None,
            )
            my_pid = os.getpid()
            for what, who, _why, mode, _uid, pid in res.unpack()[0]:
                if who == "Capsomnia" and mode == "block" and int(pid) == my_pid:
                    if "handle-lid-switch" in what and "sleep" in what:
                        return True
            return False
        except Exception as err:
            self.last_error_msg = f"ListInhibitors failed: {err}"
            return False

    def sync_sway_xkb(self) -> None:
        dedicated = bool(self.prefs["dedicated_caps_lock_mode"])
        if self.applied_xkb_dedicated == dedicated:
            return
        if find_sway_socket() is None:
            return
        opt = "caps:none" if dedicated else ""
        ok, err = run_swaymsg("input", "type:keyboard", "xkb_options", opt)
        if ok:
            self.applied_xkb_dedicated = dedicated
        else:
            log(f"sway xkb_options update failed: {err}")

    def sync_sway_shortcut(self) -> None:
        desired = str(self.prefs.get("shortcut") or "").strip()
        if self.applied_shortcut == desired:
            return
        if find_sway_socket() is None:
            return
        if self.applied_shortcut:
            run_swaymsg("unbindsym", "--inhibited", "--locked", self.applied_shortcut)
        if desired:
            ok, err = run_swaymsg(
                "bindsym",
                "--inhibited",
                "--locked",
                desired,
                "exec",
                "cpsm",
                "toggle",
                "--no-sleep",
            )
            if ok:
                self.applied_shortcut = desired
            else:
                log(f"sway shortcut bind failed ({desired}): {err}")
        else:
            self.applied_shortcut = ""

    def save_brightness_backup(self, device: str, raw: int) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.brightness_backup_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"device": device, "raw": raw}) + "\n", encoding="utf-8")
        tmp.replace(self.brightness_backup_path)

    def restore_saved_brightness(self, reason: str) -> None:
        if not self.brightness_backup_path.exists():
            self.dimmed_device = None
            return
        try:
            data = json.loads(self.brightness_backup_path.read_text(encoding="utf-8"))
            device = str(data.get("device") or "")
            raw = int(data["raw"])
            if device:
                if set_backlight_raw(device, raw):
                    log(f"restored brightness={raw} on {device} ({reason})")
                else:
                    log(f"failed to restore brightness on {device} ({reason})")
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as err:
            log(f"brightness backup read failed ({reason}): {err}")
        finally:
            try:
                self.brightness_backup_path.unlink(missing_ok=True)
            except OSError:
                pass
            self.dimmed_device = None

    def sync_keep_display_marker(self) -> None:
        self.rt_dir.mkdir(parents=True, exist_ok=True)
        active = bool(self.awake_on and self.prefs["keep_display_awake"])
        if active:
            self.keep_display_marker.touch(exist_ok=True)
        else:
            self.keep_display_marker.unlink(missing_ok=True)

    def sync_display_for_lid(self, lid_closed: bool | None) -> None:
        self.sync_keep_display_marker()
        keep_disp = bool(self.prefs["keep_display_awake"])

        if not self.awake_on:
            self.restore_saved_brightness("awake_off")
            if self.did_power_off_builtin_display and lid_closed is False:
                out_name = get_builtin_output_name()
                if out_name:
                    run_swaymsg("output", out_name, "power", "on")
                self.did_power_off_builtin_display = False
            return

        if keep_disp:
            if self.did_power_off_builtin_display:
                out_name = get_builtin_output_name()
                if out_name:
                    run_swaymsg("output", out_name, "power", "on")
                self.did_power_off_builtin_display = False

            if lid_closed is True:
                if not self.brightness_backup_path.exists():
                    info = read_backlight_info()
                    if info is not None:
                        dev, raw, max_raw = info
                        min_raw = 1 if max_raw >= 1 else 0
                        self.save_brightness_backup(dev, raw)
                        if raw > min_raw:
                            set_backlight_raw(dev, min_raw)
                        self.dimmed_device = dev
            elif lid_closed is False:
                self.restore_saved_brightness("lid_open")
        else:
            self.restore_saved_brightness("keep_display_awake_off")
            if lid_closed is True:
                if not self.did_power_off_builtin_display:
                    out_name = get_builtin_output_name()
                    if out_name:
                        ok, _ = run_swaymsg("output", out_name, "power", "off")
                        if ok:
                            self.did_power_off_builtin_display = True
            elif lid_closed is False:
                if self.did_power_off_builtin_display:
                    out_name = get_builtin_output_name()
                    if out_name:
                        run_swaymsg("output", out_name, "power", "on")
                    self.did_power_off_builtin_display = False

    def apply_awake_state(self, target_on: bool, *, reason: str, is_user_action: bool = False) -> bool:
        with self.lock:
            now = time.monotonic()
            if is_user_action:
                self.user_action_bypass_until = now + USER_BYPASS_EXTERNAL_GUARD_SEC

            was_on = self.awake_on
            self.awake_on = target_on

            if target_on and not was_on:
                self.timer.start_for_awake_on(now)
            elif not target_on:
                self.timer.clear()

            if target_on:
                inh_ok = self.acquire_inhibitor()
                present = self.verify_inhibitor_present() if inh_ok else False
                self.confirmed_sleep_inhibited = present
            else:
                self.release_inhibitor()
                present = self.verify_inhibitor_present()
                self.confirmed_sleep_inhibited = present

            dedicated = bool(self.prefs["dedicated_caps_lock_mode"])
            self.sync_sway_xkb()
            h_res = self.helper_call(
                {
                    "cmd": "set_mode",
                    "dedicated": dedicated,
                    "led_on": target_on,
                }
            )
            if h_res.get("ok") and not dedicated and is_user_action:
                # Non-dedicated mode: toggle XKB Caps_Lock via uinput if needed.
                h_res = self.helper_call({"cmd": "set_led", "on": target_on, "use_shift": True})

            self.helper_connected = bool(h_res.get("ok"))
            if not self.helper_connected:
                self.last_error_msg = str(h_res.get("error") or "helper unavailable")
                self.status_error = True
                self.next_helper_retry_at = now + HELPER_RETRY_INTERVAL_SEC
            elif target_on and not self.confirmed_sleep_inhibited:
                self.status_error = True
                self.next_helper_retry_at = now + HELPER_RETRY_INTERVAL_SEC
            elif (not target_on) and self.confirmed_sleep_inhibited:
                self.status_error = True
                self.last_error_msg = "inhibitor still present after release"
                self.next_helper_retry_at = now + HELPER_RETRY_INTERVAL_SEC
            else:
                self.status_error = False
                self.last_error_msg = None

            self.next_verify_at = now + SLEEP_VERIFY_INTERVAL_SEC
            lid_closed = read_lid_closed()
            self.sync_display_for_lid(lid_closed)
            self.write_waybar_status(lid_closed=lid_closed, force_signal=True)
            log(f"apply_awake_state target={target_on} reason={reason} error={self.status_error}")
            return not self.status_error

    def write_waybar_status(self, *, lid_closed: bool | None, force_signal: bool = False) -> None:
        self.rt_dir.mkdir(parents=True, exist_ok=True)
        now = time.monotonic()
        lang = resolve_language(self.prefs["language"])
        rem = self.timer.remaining_seconds(now) if self.awake_on else None
        show_icon = bool(self.prefs["show_menu_bar_icon"])

        if self.status_error:
            cls = "error"
            text = "<span color='#e06c75'>●</span>"
            state_label = "ERROR" if lang == "en" else "エラー"
        elif self.awake_on:
            cls = "on"
            if rem is not None:
                text = f"<span color='#34c759'>●</span> <span color='#9fe7e7'>{format_countdown(rem)}</span>"
            else:
                text = "<span color='#34c759'>●</span>"
            state_label = "ON"
        else:
            cls = "off"
            text = "<span color='#6b7785'>●</span>" if show_icon else ""
            state_label = "OFF"

        if not show_icon and not self.status_error and not self.awake_on:
            cls = "hidden"

        lid_str = (
            ("閉" if lang == "ja" else "Closed")
            if lid_closed is True
            else (("開" if lang == "ja" else "Open") if lid_closed is False else ("不明" if lang == "ja" else "Unknown"))
        )
        disp_str = (
            ("常時維持" if lang == "ja" else "Keep awake")
            if self.prefs["keep_display_awake"]
            else ("蓋閉じで消灯" if lang == "ja" else "Sleep on lid close")
        )
        timer_str = (
            format_countdown(rem)
            if rem is not None
            else (
                format_compact_duration(self.prefs["auto_off_minutes"])
                if self.prefs["auto_off_minutes"] > 0
                else "∞"
            )
        )
        if lang == "ja":
            tip_lines = [
                f"Capsomnia: {state_label}",
                f"タイマー: {timer_str}",
                f"画面動作: {disp_str}",
                f"蓋の状態: {lid_str}",
            ]
            if self.last_error_msg:
                tip_lines.append(f"エラー: {self.last_error_msg}")
            tip_lines.append("")
            tip_lines.append("左クリック: メニュー / 右クリック: 切替 / 中クリック: 設定")
        else:
            tip_lines = [
                f"Capsomnia: {state_label}",
                f"Timer: {timer_str}",
                f"Display: {disp_str}",
                f"Lid: {lid_str}",
            ]
            if self.last_error_msg:
                tip_lines.append(f"Error: {self.last_error_msg}")
            tip_lines.append("")
            tip_lines.append("Left click: Menu / Right click: Toggle / Middle click: Settings")

        payload = json.dumps(
            {
                "text": text,
                "tooltip": "\n".join(tip_lines),
                "class": cls,
            },
            ensure_ascii=False,
        )
        cur_sec = int(rem) if rem is not None else -1
        if force_signal or payload != self.last_waybar_payload or cur_sec != self.last_waybar_tick_sec:
            tmp = self.waybar_json_path.with_suffix(".tmp")
            tmp.write_text(payload + "\n", encoding="utf-8")
            tmp.replace(self.waybar_json_path)
            self.last_waybar_payload = payload
            self.last_waybar_tick_sec = cur_sec
            notify_waybar()

    def handle_hardware_event(self, event: dict[str, Any]) -> None:
        ev_type = event.get("event")
        with self.lock:
            now = time.monotonic()
            dedicated = bool(self.prefs["dedicated_caps_lock_mode"])
            if ev_type == "capslock_key_down":
                if dedicated:
                    self.apply_awake_state(
                        not self.awake_on,
                        reason="hardware_capslock_key",
                        is_user_action=True,
                    )
            elif ev_type == "led_changed":
                if dedicated:
                    return
                led_on = bool(event.get("on", False))
                if led_on:
                    self.pending_off_at = None
                    if not self.awake_on:
                        self.apply_awake_state(True, reason="hardware_led_on")
                else:
                    lid_closed = read_lid_closed()
                    recent_user = now < self.user_action_bypass_until
                    if should_reassert_on_external_off(
                        preference_enabled=bool(
                            self.prefs["ignore_external_caps_lock_off_while_lid_closed"]
                        ),
                        sleep_prevention_active=self.awake_on,
                        recent_user_action=recent_user,
                        auto_off_in_progress=self.auto_off_in_progress,
                        clamshell_closed=lid_closed,
                    ):
                        log("external Caps Lock off while lid closed -> reasserting ON")
                        self.helper_call({"cmd": "set_led", "on": True, "use_shift": True})
                    else:
                        self.pending_off_at = now + OFF_DEBOUNCE_SEC

    def helper_subscriber_loop(self) -> None:
        while not self._stop_event.is_set():
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(self.helper_socket)
                sock.sendall(b'{"cmd":"subscribe"}\n')
                self._helper_sub_sock = sock
                buf = b""
                while not self._stop_event.is_set():
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        raw_line, buf = buf.split(b"\n", 1)
                        line = raw_line.decode("utf-8", errors="replace").strip()
                        if not line:
                            continue
                        try:
                            ev = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if ev.get("event") == "subscribed":
                            with self.lock:
                                self.helper_connected = True
                                self.sync_sway_xkb()
                                self.helper_call(
                                    {
                                        "cmd": "set_mode",
                                        "dedicated": bool(self.prefs["dedicated_caps_lock_mode"]),
                                        "led_on": self.awake_on,
                                    }
                                )
                        else:
                            GLib.idle_add(self._on_helper_event_main, ev)
            except OSError:
                pass
            finally:
                self._helper_sub_sock = None
                try:
                    sock.close()
                except OSError:
                    pass
            if not self._stop_event.wait(2.0):
                continue

    def _on_helper_event_main(self, ev: dict[str, Any]) -> bool:
        self.handle_hardware_event(ev)
        return False

    def maybe_probe_hotspot(self, now: float) -> None:
        if not (self.awake_on and self.prefs["keep_hotspot_alive"]):
            self.hotspot_active = False
            return
        if now < self.next_hotspot_probe_at:
            return
        self.next_hotspot_probe_at = now + HOTSPOT_INTERVAL_SEC

        def _probe() -> None:
            try:
                proc = subprocess.run(
                    ["ip", "-j", "route", "show", "default"],
                    capture_output=True,
                    text=True,
                    timeout=2.0,
                    check=False,
                )
                if proc.returncode != 0:
                    return
                _dev, gw, src = parse_default_route_json(proc.stdout)
                if not is_mobile_hotspot_route(gw, src):
                    self.hotspot_active = False
                    return
                self.hotspot_active = True
                assert gw is not None
                subprocess.run(
                    ["ping", "-n", "-c", "1", "-W", "1", gw],
                    capture_output=True,
                    timeout=3.0,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                pass

        threading.Thread(target=_probe, daemon=True).start()

    def request_system_sleep_if_closed(self) -> bool:
        lid_closed = read_lid_closed()
        if lid_closed is not True:
            log(f"skipping immediate sleep (lid_closed={lid_closed})")
            return False
        res = self.helper_call({"cmd": "suspend"}, timeout=5.0)
        return bool(res.get("ok"))

    def on_poll_tick(self) -> bool:
        with self.lock:
            now = time.monotonic()
            self.sync_sway_xkb()
            self.sync_sway_shortcut()

            # Debounced off in non-dedicated mode.
            if self.pending_off_at is not None and now >= self.pending_off_at:
                self.pending_off_at = None
                if self.awake_on:
                    self.apply_awake_state(False, reason="hardware_led_off")

            # Auto-off timer expiry.
            if self.awake_on and self.timer.is_expired(now):
                log("auto-off timer expired")
                self.auto_off_in_progress = True
                try:
                    ok = self.apply_awake_state(False, reason="auto_off_timer", is_user_action=True)
                    if ok and not self.confirmed_sleep_inhibited:
                        self.request_system_sleep_if_closed()
                finally:
                    self.auto_off_in_progress = False

            # Periodic verification / error recovery.
            if now >= self.next_verify_at or (self.status_error and now >= self.next_helper_retry_at):
                self.next_verify_at = now + SLEEP_VERIFY_INTERVAL_SEC
                present = self.verify_inhibitor_present()
                self.confirmed_sleep_inhibited = present
                h_res = self.helper_call({"cmd": "get_state"})
                self.helper_connected = bool(h_res.get("ok"))
                if self.awake_on and (not present or not self.helper_connected):
                    self.status_error = True
                    self.next_helper_retry_at = now + HELPER_RETRY_INTERVAL_SEC
                    self.apply_awake_state(True, reason="verify_retry")
                elif (not self.awake_on) and (present or not self.helper_connected):
                    self.status_error = True
                    self.next_helper_retry_at = now + HELPER_RETRY_INTERVAL_SEC
                    self.apply_awake_state(False, reason="verify_retry")
                else:
                    self.status_error = False
                    self.last_error_msg = None

            # Lid monitoring: display sleep/dimming + lock-on-lid-open.
            lid_closed = read_lid_closed()
            self.sync_display_for_lid(lid_closed)

            eligible_lock = bool(
                self.awake_on and self.prefs["keep_display_awake"] and self.prefs["lock_on_lid_open"]
            )
            locked_now = is_swaylock_running() if eligible_lock else None
            if self.lid_lock_tracker.update(
                eligible=eligible_lock,
                clamshell_closed=lid_closed,
                is_locked=locked_now,
                now=time.time(),
            ) == "lock":
                log("lid opened while active -> locking screen with swaylock")
                try:
                    subprocess.Popen(["swaylock", "-f", "-c", "0b0f14"])
                except OSError as err:
                    log(f"swaylock failed: {err}")

            self.maybe_probe_hotspot(now)
            self.write_waybar_status(lid_closed=lid_closed)
        return True

    def status_payload(self) -> dict[str, Any]:
        with self.lock:
            now = time.monotonic()
            lid_closed = read_lid_closed()
            h_res = self.helper_call({"cmd": "get_state"})
            return {
                "version": VERSION,
                "awake_on": self.awake_on,
                "sleep_inhibited": self.confirmed_sleep_inhibited,
                "status_error": self.status_error,
                "error_message": self.last_error_msg,
                "helper_connected": bool(h_res.get("ok")),
                "leds": h_res.get("leds", []),
                "any_led_on": h_res.get("any_led_on"),
                "keyd_connected": h_res.get("keyd_connected"),
                "lid_closed": lid_closed,
                "hotspot_active": self.hotspot_active,
                "dimmed_device": self.dimmed_device,
                "timer": self.timer.status_dict(self.awake_on, now),
                "settings": dict(self.prefs),
            }

    def handle_control_request(self, req: dict[str, Any]) -> dict[str, Any]:
        if req.get("version") != 1:
            return err_response("unsupported protocol version")
        args = req.get("arguments")
        if not isinstance(args, list) or not args:
            return err_response("missing command")
        args = [str(a) for a in args]
        cmd = args[0]

        if cmd == "status":
            return ok_response(self.status_payload())

        if cmd == "doctor":
            st = self.status_payload()
            return ok_response(
                {
                    "version": VERSION,
                    "daemon_pid": os.getpid(),
                    "control_socket": str(self.control_socket_path),
                    "helper_socket": self.helper_socket,
                    "helper_connected": st["helper_connected"],
                    "keyd_connected": st["keyd_connected"],
                    "leds": st["leds"],
                    "sway_socket": find_sway_socket(),
                    "lid_closed": st["lid_closed"],
                    "sleep_inhibited": st["sleep_inhibited"],
                    "status_error": st["status_error"],
                    "error_message": st["error_message"],
                }
            )

        if cmd == "on":
            ok = self.apply_awake_state(True, reason="cli_on", is_user_action=True)
            st = self.status_payload()
            return ok_response(st) if ok else err_response(st.get("error_message") or "failed to enable")

        if cmd == "off":
            no_sleep = "--no-sleep" in args[1:]
            ok = self.apply_awake_state(False, reason="cli_off", is_user_action=True)
            if not ok:
                return err_response(self.last_error_msg or "failed to disable")
            sleep_req = False
            if not no_sleep:
                res = self.helper_call({"cmd": "suspend"}, timeout=5.0)
                sleep_req = bool(res.get("ok"))
            st = self.status_payload()
            st["sleep_requested"] = sleep_req
            return ok_response(st)

        if cmd == "toggle":
            no_sleep = "--no-sleep" in args[1:]
            with self.lock:
                target = not self.awake_on
            if target:
                ok = self.apply_awake_state(True, reason="cli_toggle", is_user_action=True)
                st = self.status_payload()
                return ok_response(st) if ok else err_response(st.get("error_message") or "failed")
            ok = self.apply_awake_state(False, reason="cli_toggle", is_user_action=True)
            if not ok:
                return err_response(self.last_error_msg or "failed")
            sleep_req = False
            if not no_sleep:
                res = self.helper_call({"cmd": "suspend"}, timeout=5.0)
                sleep_req = bool(res.get("ok"))
            st = self.status_payload()
            st["sleep_requested"] = sleep_req
            return ok_response(st)

        if cmd == "timer":
            if len(args) < 2:
                return err_response("missing timer subcommand")
            sub = args[1]
            with self.lock:
                now = time.monotonic()
                if sub == "status":
                    return ok_response(self.timer.status_dict(self.awake_on, now))
                if sub == "set":
                    if len(args) < 3:
                        return err_response("missing duration")
                    try:
                        secs = parse_duration_seconds(args[2])
                    except ValueError as err:
                        return err_response(str(err))
                    if not self.awake_on:
                        self.apply_awake_state(True, reason="cli_timer_set", is_user_action=True)
                    self.timer.set_one_shot(secs, time.monotonic())
                    self.write_waybar_status(lid_closed=read_lid_closed(), force_signal=True)
                    return ok_response(self.timer.status_dict(self.awake_on, time.monotonic()))
                if sub == "restart":
                    if not self.awake_on or not self.timer.restart(now):
                        return err_response("no active timer")
                    self.write_waybar_status(lid_closed=read_lid_closed(), force_signal=True)
                    return ok_response(self.timer.status_dict(self.awake_on, now))
                if sub == "cancel":
                    self.timer.cancel()
                    self.write_waybar_status(lid_closed=read_lid_closed(), force_signal=True)
                    return ok_response(self.timer.status_dict(self.awake_on, now))
                return err_response(f"unknown timer subcommand: {sub}")

        if cmd == "settings":
            if len(args) < 2:
                return err_response("missing settings subcommand")
            sub = args[1]
            with self.lock:
                if sub == "get":
                    if len(args) >= 3:
                        from capsomnia_core import CLI_KEY_ALIASES

                        key = CLI_KEY_ALIASES.get(args[2], args[2])
                        if key not in self.prefs:
                            return err_response(f"unknown setting: {args[2]}")
                        return ok_response({key: self.prefs[key]})
                    return ok_response(dict(self.prefs))
                if sub == "set":
                    if len(args) < 4:
                        return err_response("usage: settings set <key> <value>")
                    from capsomnia_core import CLI_KEY_ALIASES

                    key = CLI_KEY_ALIASES.get(args[2], args[2])
                    if key not in self.prefs:
                        return err_response(f"unknown setting: {args[2]}")
                    raw_val = args[3]
                    new_prefs = dict(self.prefs)
                    try:
                        if key == "auto_off_minutes":
                            new_prefs[key] = clamp_auto_off_minutes(int(raw_val))
                        elif key in ("language", "shortcut"):
                            new_prefs[key] = raw_val
                        else:
                            new_prefs[key] = parse_bool_str(raw_val)
                    except ValueError as err:
                        return err_response(str(err))
                    self.prefs = save_prefs(new_prefs, self.config_path)
                    if key == "auto_off_minutes":
                        self.timer.apply_saved_default_while_on(
                            self.prefs["auto_off_minutes"], time.monotonic()
                        )
                    elif key == "dedicated_caps_lock_mode":
                        self.applied_xkb_dedicated = None
                        self.apply_awake_state(self.awake_on, reason="settings_dedicated_mode")
                    elif key == "shortcut":
                        self.sync_sway_shortcut()
                    self.sync_display_for_lid(read_lid_closed())
                    self.write_waybar_status(lid_closed=read_lid_closed(), force_signal=True)
                    return ok_response(dict(self.prefs))
                return err_response(f"unknown settings subcommand: {sub}")

        if cmd == "quit":
            GLib.idle_add(self.shutdown)
            return ok_response({"quitting": True})

        return err_response(f"unknown command: {cmd}")

    def control_server_loop(self) -> None:
        self.rt_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.rt_dir, 0o700)
        if self.control_socket_path.exists():
            self.control_socket_path.unlink()
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(self.control_socket_path))
        os.chmod(self.control_socket_path, 0o600)
        srv.listen(16)
        srv.settimeout(0.5)
        try:
            while not self._stop_event.is_set():
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    conn.settimeout(2.0)
                    buf = b""
                    while b"\n" not in buf and len(buf) < 65536:
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        buf += chunk
                    line = buf.decode("utf-8", errors="replace").splitlines()[0]
                    req = json.loads(line)
                    resp = self.handle_control_request(req)
                except Exception as err:
                    resp = err_response(str(err))
                try:
                    conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
                except OSError:
                    pass
                finally:
                    try:
                        conn.close()
                    except OSError:
                        pass
        finally:
            try:
                srv.close()
            except OSError:
                pass
            try:
                self.control_socket_path.unlink(missing_ok=True)
            except OSError:
                pass

    def shutdown(self) -> bool:
        log("shutting down; restoring normal sleep and display")
        self._stop_event.set()
        if self.awake_on:
            self.apply_awake_state(False, reason="shutdown", is_user_action=True)
        else:
            self.release_inhibitor()
            self.restore_saved_brightness("shutdown")
            self.keep_display_marker.unlink(missing_ok=True)
        # Restore XKB caps:none only if quitting cleanly? Wait: keep user's
        # XKB clean on daemon exit.
        if self.applied_xkb_dedicated:
            run_swaymsg("input", "type:keyboard", "xkb_options", "")
        self.loop.quit()
        return False

    def run(self) -> int:
        # Crash recovery on startup.
        self.restore_saved_brightness("startup")
        self.keep_display_marker.unlink(missing_ok=True)

        # Initial mode sync.
        if not self.prefs["dedicated_caps_lock_mode"]:
            h_res = self.helper_call({"cmd": "get_state"})
            if h_res.get("ok") and h_res.get("any_led_on"):
                self.apply_awake_state(True, reason="startup_led_on")
            else:
                self.apply_awake_state(False, reason="startup")
        else:
            self.apply_awake_state(False, reason="startup")

        self.sync_sway_shortcut()

        # First-launch Welcome Guide.
        if not self.prefs.get("did_complete_initial_setup", False):
            try:
                subprocess.Popen(["capsomnia-settings", "--welcome"])
            except OSError as err:
                log(f"failed to launch welcome guide: {err}")

        def _on_signal(_signum: int, _frame: Any) -> None:
            GLib.idle_add(self.shutdown)

        signal.signal(signal.SIGTERM, _on_signal)
        signal.signal(signal.SIGINT, _on_signal)

        threading.Thread(target=self.helper_subscriber_loop, daemon=True).start()
        threading.Thread(target=self.control_server_loop, daemon=True).start()
        GLib.timeout_add(POLL_INTERVAL_MS, self.on_poll_tick)

        self.loop.run()
        return 0


def main() -> int:
    daemon = CapsomniaDaemon()
    return daemon.run()


if __name__ == "__main__":
    sys.exit(main())
