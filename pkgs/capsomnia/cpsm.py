#!/usr/bin/env python3
"""cpsm — Capsomnia CLI for NixOS/Hyprland."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from typing import Any

from capsomnia_core import (
    VERSION,
    format_countdown,
    runtime_dir,
)


def control_socket_path() -> str:
    return str(runtime_dir() / "control.sock")


def ensure_daemon_running() -> bool:
    sock_path = control_socket_path()
    if os.path.exists(sock_path):
        return True
    subprocess.run(
        ["systemctl", "--user", "start", "capsomniad.service"],
        capture_output=True,
        check=False,
    )
    for _ in range(25):
        if os.path.exists(sock_path):
            return True
        time.sleep(0.1)
    return os.path.exists(sock_path)


def send_control(args: list[str], *, auto_start: bool = True) -> dict[str, Any]:
    sock_path = control_socket_path()
    if auto_start and not os.path.exists(sock_path):
        ensure_daemon_running()

    req = {"version": 1, "arguments": args}
    last_err = "daemon unavailable"
    for attempt in range(3):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(8.0)
        try:
            sock.connect(sock_path)
            sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
            buf = b""
            while b"\n" not in buf and len(buf) < 65536:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
            if not buf:
                return {"ok": False, "error": "empty response from daemon"}
            return json.loads(buf.decode("utf-8", errors="replace").splitlines()[0])
        except OSError as err:
            last_err = str(err)
            if attempt < 2 and auto_start:
                ensure_daemon_running()
                time.sleep(0.1)
                continue
            return {"ok": False, "error": last_err}
        except json.JSONDecodeError as err:
            return {"ok": False, "error": f"invalid response: {err}"}
        finally:
            try:
                sock.close()
            except OSError:
                pass
    return {"ok": False, "error": last_err}


def print_help() -> None:
    print(
        f"""cpsm {VERSION} — Capsomnia CLI

Usage:
  cpsm [--json] <command> [args...]

Commands:
  status                    Show awake, lid, LED, inhibitor, and timer state
  doctor                    Show daemon, helper, keyd, Hyprland, and LED diagnostics
  on                        Enable keep-awake mode
  off [--no-sleep]          Disable keep-awake mode (requests sleep unless --no-sleep)
  toggle [--no-sleep]       Toggle keep-awake mode (off requests sleep unless --no-sleep)
  timer set <duration>      Enable keep-awake and set one-shot timer (e.g. 90s, 30m, 2h)
  timer status              Show active timer state
  timer restart             Restart active timer countdown
  timer cancel              Cancel active timer without turning awake off
  settings get [key]        Read all settings or one setting
  settings set <key> <val>  Update a saved setting
  menu                      Open Rofi quick menu
  ui                        Open GTK4 Settings window
  welcome                   Open Welcome Guide window
  version                   Show version
  help                      Show this help"""
    )


def format_human(cmd: str, result: Any) -> str:
    if cmd == "status" and isinstance(result, dict):
        state = "ERROR" if result.get("status_error") else ("ON" if result.get("awake_on") else "OFF")
        lid = "closed" if result.get("lid_closed") is True else ("open" if result.get("lid_closed") is False else "unknown")
        timer = result.get("timer") or {}
        if timer.get("active") and timer.get("remaining_seconds") is not None:
            t_str = format_countdown(timer["remaining_seconds"])
        else:
            t_str = "none"
        return (
            f"Capsomnia: {state}\n"
            f"Sleep inhibited: {result.get('sleep_inhibited')}\n"
            f"Lid: {lid}\n"
            f"Timer: {t_str}\n"
            f"Keep display awake: {result.get('settings', {}).get('keep_display_awake')}"
        )
    return json.dumps(result, indent=2, ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    raw_args = list(sys.argv[1:] if argv is None else argv)
    as_json = False
    filtered: list[str] = []
    for a in raw_args:
        if a == "--json":
            as_json = True
        else:
            filtered.append(a)

    if not filtered or filtered[0] in ("help", "--help", "-h"):
        print_help()
        return 0

    if filtered[0] in ("version", "--version", "-v"):
        if as_json:
            print(json.dumps({"ok": True, "result": {"version": VERSION}}))
        else:
            print(f"cpsm {VERSION}")
        return 0

    if filtered[0] == "waybar":
        wf = runtime_dir() / "waybar.json"
        if wf.is_file():
            sys.stdout.write(wf.read_text(encoding="utf-8"))
        else:
            print('{"text":"<span color=\'#6b7785\'>●</span>","class":"off","tooltip":"Capsomnia: starting"}')
        return 0

    if filtered[0] == "menu":
        os.execvp("capsomnia-menu", ["capsomnia-menu"])
    if filtered[0] == "ui":
        os.execvp("capsomnia-settings", ["capsomnia-settings"])
    if filtered[0] == "welcome":
        os.execvp("capsomnia-settings", ["capsomnia-settings", "--welcome"])

    resp = send_control(filtered)
    if as_json:
        print(json.dumps(resp, ensure_ascii=False))
    else:
        if resp.get("ok"):
            print(format_human(filtered[0], resp.get("result")))
        else:
            print(f"error: {resp.get('error')}", file=sys.stderr)
    return 0 if resp.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
