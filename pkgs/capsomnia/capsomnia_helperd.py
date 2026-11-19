#!/usr/bin/env python3
"""Privileged helper daemon for Capsomnia: Caps Lock key/LED + suspend."""

from __future__ import annotations

import glob
import grp
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from evdev import InputDevice, UInput, ecodes, list_devices

KEYD_NAME = "keyd virtual keyboard"
DEFAULT_SOCKET_PATH = "/run/capsomnia/helper.sock"
LED_GLOB = "/sys/class/leds/*::capslock"
REOPEN_INTERVAL_SEC = 1.0
LED_SYNC_INTERVAL_SEC = 1.5


def log(msg: str) -> None:
    print(f"capsomnia-helperd: {msg}", flush=True)


def list_capslock_leds() -> list[Path]:
    return [Path(p) for p in sorted(glob.glob(LED_GLOB)) if Path(p).is_dir()]


def read_led_brightness(led_dir: Path) -> int | None:
    try:
        return int((led_dir / "brightness").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def read_active_trigger(led_dir: Path) -> str | None:
    try:
        raw = (led_dir / "trigger").read_text(encoding="utf-8")
    except OSError:
        return None
    for tok in raw.split():
        if tok.startswith("[") and tok.endswith("]"):
            return tok[1:-1]
    return None


def apply_led_state(dedicated: bool, led_on: bool) -> dict[str, Any]:
    leds = list_capslock_leds()
    updated = 0
    errors: list[str] = []
    for led in leds:
        try:
            trig_path = led / "trigger"
            bright_path = led / "brightness"
            desired_trig = "none" if dedicated else "kbd-capslock"
            current_trig = read_active_trigger(led)
            if current_trig != desired_trig:
                trig_path.write_text(desired_trig, encoding="utf-8")
            if dedicated:
                desired_b = "1" if led_on else "0"
                current_b = read_led_brightness(led)
                if str(current_b) != desired_b:
                    bright_path.write_text(desired_b, encoding="utf-8")
            updated += 1
        except OSError as err:
            errors.append(f"{led.name}: {err}")
    return {
        "led_count": len(leds),
        "updated": updated,
        "errors": errors,
    }


def snapshot_leds() -> dict[str, Any]:
    leds = list_capslock_leds()
    items = []
    any_on = False
    for led in leds:
        b = read_led_brightness(led)
        t = read_active_trigger(led)
        if b is not None and b > 0:
            any_on = True
        items.append({"name": led.name, "brightness": b, "trigger": t})
    return {
        "led_count": len(leds),
        "any_led_on": any_on,
        "leds": items,
    }


def find_keyd_keyboard() -> InputDevice | None:
    for path in list_devices():
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        caps = dev.capabilities().get(ecodes.EV_KEY, ())
        if dev.name == KEYD_NAME and ecodes.KEY_CAPSLOCK in caps:
            return dev
        try:
            dev.close()
        except OSError:
            pass
    return None


def inject_capslock_toggle(use_shift: bool = True) -> None:
    """Emit a synthetic Caps Lock tap so XKB/LED toggle in non-dedicated mode."""
    caps = {ecodes.EV_KEY: [ecodes.KEY_LEFTSHIFT, ecodes.KEY_CAPSLOCK]}
    with UInput(caps, name="capsomnia-virtual-toggle") as ui:
        time.sleep(0.05)
        if use_shift:
            ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 1)
            ui.syn()
        ui.write(ecodes.EV_KEY, ecodes.KEY_CAPSLOCK, 1)
        ui.syn()
        time.sleep(0.02)
        ui.write(ecodes.EV_KEY, ecodes.KEY_CAPSLOCK, 0)
        ui.syn()
        if use_shift:
            ui.write(ecodes.EV_KEY, ecodes.KEY_LEFTSHIFT, 0)
            ui.syn()


class HelperServer:
    def __init__(self, socket_path: str, socket_group: str) -> None:
        self.socket_path = Path(socket_path)
        self.socket_group = socket_group
        self.running = True
        self.dedicated = True
        self.led_on = False
        self.last_observed_any_led: bool | None = None
        self.keyd_dev: InputDevice | None = None
        self.next_keyd_probe = 0.0
        self.next_led_sync = 0.0
        self.server_sock: socket.socket | None = None
        self.subscribers: list[socket.socket] = []

    def setup_socket(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.socket_path.parent, 0o755)
        if self.socket_path.exists():
            self.socket_path.unlink()
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(self.socket_path))
        srv.listen(16)
        srv.setblocking(False)
        gid = -1
        try:
            gid = grp.getgrnam(self.socket_group).gr_gid
        except KeyError:
            log(f"group {self.socket_group!r} not found; keeping default group")
        if gid >= 0:
            os.chown(self.socket_path, 0, gid)
        os.chmod(self.socket_path, 0o660)
        self.server_sock = srv

    def ensure_keyd(self, now: float) -> None:
        if self.keyd_dev is not None or now < self.next_keyd_probe:
            return
        self.next_keyd_probe = now + REOPEN_INTERVAL_SEC
        dev = find_keyd_keyboard()
        if dev is not None:
            log(f"watching {dev.path} ({dev.name})")
            self.keyd_dev = dev

    def broadcast_event(self, payload: dict[str, Any]) -> None:
        raw = (json.dumps(payload) + "\n").encode("utf-8")
        dead: list[socket.socket] = []
        for sub in self.subscribers:
            try:
                sub.sendall(raw)
            except OSError:
                dead.append(sub)
        for sub in dead:
            self.subscribers.remove(sub)
            try:
                sub.close()
            except OSError:
                pass

    def handle_command(self, conn: socket.socket, line: str) -> None:
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            self.send_json(conn, {"ok": False, "error": "invalid json"})
            return

        if not isinstance(req, dict):
            self.send_json(conn, {"ok": False, "error": "invalid request"})
            return

        cmd = req.get("cmd")
        if cmd == "subscribe":
            self.subscribers.append(conn)
            snap = snapshot_leds()
            self.last_observed_any_led = snap["any_led_on"]
            self.send_json(
                conn,
                {
                    "ok": True,
                    "event": "subscribed",
                    "dedicated": self.dedicated,
                    "led_on": self.led_on,
                    **snap,
                },
            )
            return

        if cmd == "set_mode":
            self.dedicated = bool(req.get("dedicated", True))
            self.led_on = bool(req.get("led_on", False))
            res = apply_led_state(self.dedicated, self.led_on)
            snap = snapshot_leds()
            self.last_observed_any_led = snap["any_led_on"]
            self.send_json(conn, {"ok": not res["errors"], **res, **snap})
        elif cmd == "set_led":
            target = bool(req.get("on", False))
            use_shift = bool(req.get("use_shift", True))
            self.led_on = target
            if self.dedicated:
                res = apply_led_state(True, target)
                snap = snapshot_leds()
                self.send_json(conn, {"ok": not res["errors"], **res, **snap})
            else:
                snap = snapshot_leds()
                if snap["any_led_on"] != target:
                    try:
                        inject_capslock_toggle(use_shift=use_shift)
                    except OSError as err:
                        self.send_json(conn, {"ok": False, "error": f"uinput failed: {err}"})
                        return
                self.send_json(conn, {"ok": True, **snapshot_leds()})
        elif cmd == "get_state":
            snap = snapshot_leds()
            self.send_json(
                conn,
                {
                    "ok": True,
                    "dedicated": self.dedicated,
                    "led_on": self.led_on,
                    "keyd_connected": self.keyd_dev is not None,
                    **snap,
                },
            )
        elif cmd == "suspend":
            log("executing systemctl suspend")
            proc = subprocess.run(["systemctl", "suspend"], check=False)
            self.send_json(conn, {"ok": proc.returncode == 0, "returncode": proc.returncode})
        else:
            self.send_json(conn, {"ok": False, "error": f"unknown command: {cmd!r}"})

        if conn not in self.subscribers:
            try:
                conn.close()
            except OSError:
                pass

    @staticmethod
    def send_json(conn: socket.socket, payload: dict[str, Any]) -> None:
        try:
            conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        except OSError:
            pass

    def poll_leds(self, now: float) -> None:
        if now < self.next_led_sync:
            return
        self.next_led_sync = now + LED_SYNC_INTERVAL_SEC
        if self.dedicated:
            apply_led_state(True, self.led_on)
            return
        snap = snapshot_leds()
        any_on = bool(snap["any_led_on"])
        if self.last_observed_any_led is None:
            self.last_observed_any_led = any_on
        elif any_on != self.last_observed_any_led:
            self.last_observed_any_led = any_on
            self.broadcast_event({"event": "led_changed", "on": any_on})

    def run(self) -> int:
        self.setup_socket()
        assert self.server_sock is not None

        def _stop(_signum: int, _frame: Any) -> None:
            self.running = False

        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)

        log(f"listening on {self.socket_path}")
        try:
            while self.running:
                now = time.monotonic()
                self.ensure_keyd(now)
                self.poll_leds(now)

                read_fds: list[Any] = [self.server_sock]
                if self.keyd_dev is not None:
                    read_fds.append(self.keyd_dev)

                try:
                    r, _, _ = select.select(read_fds, [], [], 0.25)
                except (OSError, ValueError):
                    if self.keyd_dev is not None:
                        try:
                            self.keyd_dev.close()
                        except OSError:
                            pass
                        self.keyd_dev = None
                    continue

                for item in r:
                    if item is self.server_sock:
                        try:
                            conn, _ = self.server_sock.accept()
                            conn.settimeout(2.0)
                            data = conn.recv(4096)
                            if not data:
                                conn.close()
                                continue
                            line = data.decode("utf-8", errors="replace").splitlines()[0]
                            conn.settimeout(None)
                            self.handle_command(conn, line)
                        except OSError:
                            pass
                    elif item is self.keyd_dev:
                        try:
                            for ev in self.keyd_dev.read():
                                if (
                                    ev.type == ecodes.EV_KEY
                                    and ev.code == ecodes.KEY_CAPSLOCK
                                    and ev.value == 1
                                ):
                                    self.broadcast_event(
                                        {"event": "capslock_key_down", "ts": time.time()}
                                    )
                        except OSError as err:
                            log(f"keyd device read error: {err}")
                            try:
                                self.keyd_dev.close()
                            except OSError:
                                pass
                            self.keyd_dev = None
        finally:
            log("shutting down; restoring kbd-capslock LED trigger")
            apply_led_state(False, False)
            for sub in self.subscribers:
                try:
                    sub.close()
                except OSError:
                    pass
            if self.keyd_dev is not None:
                try:
                    self.keyd_dev.close()
                except OSError:
                    pass
            if self.server_sock is not None:
                try:
                    self.server_sock.close()
                except OSError:
                    pass
            try:
                self.socket_path.unlink(missing_ok=True)
            except OSError:
                pass
        return 0


def main() -> int:
    sock_path = os.environ.get("CAPS_HELPER_SOCKET", DEFAULT_SOCKET_PATH)
    sock_group = os.environ.get("CAPS_HELPER_GROUP", "wheel")
    server = HelperServer(sock_path, sock_group)
    return server.run()


if __name__ == "__main__":
    sys.exit(main())
