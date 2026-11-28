"""User-space power-save mode controller and battery/AC auto-switch watcher.

Manages:
  - CPU power profile (via system oneshot units power-save-cpu-on/off.service)
  - Hyprland visual effects (animations, blur, shadow, inactive_opacity)
  - Display brightness cap + restore (via brightnessctl)
  - Bluetooth power-off when no device is connected + restore (via bluetoothctl)
  - Optional background user services pause + restore (via systemctl --user)
  - Automatic ON on low battery and OFF on AC reconnect (`power-save watch`)

State files:
  - Config (persistent): ~/.config/power-save/config.json
  - State  (runtime):    $XDG_RUNTIME_DIR/power-save/state.json
  - Status (runtime):    $XDG_RUNTIME_DIR/power-save/status.json (watched by Colorshell)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

DEFAULT_SERVICES = [
    "activitywatch-watcher-wayland.service",
    "activitywatch.service",
    "whatpulse.service",
    "lan-mouse.service",
    "uniclipd.service",
    "taildrop-receive.service",
]

DEFAULT_CONFIG: dict[str, Any] = {
    "cpu": True,
    "hyprland": True,
    "brightness": True,
    "brightness_cap": 35,
    "bluetooth": True,
    "services": True,
    "auto_on_low_battery": True,
    "low_battery_threshold": 20,
    "auto_off_on_ac": True,
    "show_bar_icon": True,
}

HYPR_RESTORE_DEFAULTS = {
    "animations:enabled": "1",
    "decoration:blur:enabled": "1",
    "decoration:shadow:enabled": "1",
    "decoration:inactive_opacity": "0.96",
}

HYPR_POWERSAVE_VALUES = {
    "animations:enabled": "0",
    "decoration:blur:enabled": "0",
    "decoration:shadow:enabled": "0",
    "decoration:inactive_opacity": "1.0",
}

BOOL_KEYS = {
    "cpu",
    "hyprland",
    "brightness",
    "bluetooth",
    "services",
    "auto_on_low_battery",
    "auto_off_on_ac",
    "show_bar_icon",
}
INT_KEYS = {
    "brightness_cap": (5, 100),
    "low_battery_threshold": (5, 80),
}


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "power-save"


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/power-save-{os.getuid()}"
    return Path(base) / "power-save"


def config_path() -> Path:
    return config_dir() / "config.json"


def state_path() -> Path:
    return runtime_dir() / "state.json"


def status_path() -> Path:
    return runtime_dir() / "status.json"


def lock_path() -> Path:
    return runtime_dir() / "lock"


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def load_config() -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    p = config_path()
    if p.is_file():
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                for k, v in raw.items():
                    if k in BOOL_KEYS and isinstance(v, bool):
                        cfg[k] = v
                    elif k in INT_KEYS and isinstance(v, (int, float)):
                        lo, hi = INT_KEYS[k]
                        cfg[k] = max(lo, min(hi, int(v)))
        except Exception:
            pass
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    atomic_write_json(config_path(), cfg)


def default_state() -> dict[str, Any]:
    return {
        "active": False,
        "reason": "off",
        "applied": {
            "cpu": False,
            "hyprland": False,
            "brightness": False,
            "bluetooth": False,
            "services": False,
        },
        "saved_brightness": None,
        "saved_hypr": {},
        "bt_powered_off": False,
        "paused_services": [],
        "manual_dismiss_low_battery": False,
        "error": None,
    }


def load_state() -> dict[str, Any]:
    st = default_state()
    p = state_path()
    if p.is_file():
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                st.update(raw)
                applied = default_state()["applied"]
                if isinstance(raw.get("applied"), dict):
                    applied.update({k: bool(v) for k, v in raw["applied"].items() if k in applied})
                st["applied"] = applied
        except Exception:
            pass
    return st


def save_state(st: dict[str, Any]) -> None:
    atomic_write_json(state_path(), st)


def run_cmd(argv: list[str], timeout: float = 10.0) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"command not found: {argv[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout: {' '.join(argv)}"
    except Exception as exc:
        return 1, "", str(exc)


def read_sysfs_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def read_battery_info() -> dict[str, Any]:
    ps_dir = Path("/sys/class/power_supply")
    info: dict[str, Any] = {
        "present": False,
        "capacity": None,
        "status": "Unknown",
        "ac_online": False,
    }
    if not ps_dir.is_dir():
        return info

    preferred_bat = os.environ.get("POWER_SAVE_BATTERY_DEV", "").strip()
    preferred_ac = os.environ.get("POWER_SAVE_ADAPTER_DEV", "").strip()

    bats: list[Path] = []
    acs: list[Path] = []
    for entry in sorted(ps_dir.iterdir()):
        ptype = read_sysfs_text(entry / "type")
        if ptype == "Battery":
            if preferred_bat and entry.name == preferred_bat:
                bats.insert(0, entry)
            else:
                bats.append(entry)
        elif ptype in ("Mains", "USB", "USB_PD", "USB_C"):
            if preferred_ac and entry.name == preferred_ac:
                acs.insert(0, entry)
            else:
                acs.append(entry)

    for ac in acs:
        online = read_sysfs_text(ac / "online")
        if online == "1":
            info["ac_online"] = True
            break

    if bats:
        bat = bats[0]
        cap_s = read_sysfs_text(bat / "capacity")
        st_s = read_sysfs_text(bat / "status") or "Unknown"
        info["present"] = True
        info["status"] = st_s
        if cap_s and cap_s.isdigit():
            info["capacity"] = int(cap_s)
        if st_s in ("Charging", "Full"):
            info["ac_online"] = True

    return info


def send_notification(title: str, body: str) -> None:
    notify = shutil.which("notify-send")
    if not notify:
        return
    try:
        subprocess.Popen(
            [
                notify,
                "-a",
                "省電力モード",
                "-i",
                "power-profile-power-saver-symbolic",
                "-h",
                "string:x-canonical-private-synchronous:power-save",
                title,
                body,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


# --- Feature controllers ---


def apply_cpu(enable: bool) -> tuple[bool, str | None]:
    unit = "power-save-cpu-on.service" if enable else "power-save-cpu-off.service"
    rc, _out, err = run_cmd(["systemctl", "start", "--no-block", unit], timeout=5.0)
    if rc != 0:
        return False, f"CPU切替失敗 ({unit}): {err or f'rc={rc}'}"
    return True, None


def _hypr_get_option(opt: str) -> str | None:
    if not shutil.which("hyprctl") or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    rc, out, _ = run_cmd(["hyprctl", "-j", "getoption", opt], timeout=3.0)
    if rc != 0 or not out:
        return None
    try:
        data = json.loads(out)
        if "int" in data and data["int"] is not None:
            return str(data["int"])
        if "float" in data and data["float"] is not None:
            return f"{float(data['float']):.2f}"
    except Exception:
        return None
    return None


def apply_hyprland(enable: bool, st: dict[str, Any]) -> tuple[bool, str | None]:
    if not shutil.which("hyprctl") or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return False, None
    if enable:
        saved: dict[str, str] = {}
        for k, default_val in HYPR_RESTORE_DEFAULTS.items():
            cur = _hypr_get_option(k)
            saved[k] = cur if cur is not None else default_val
        st["saved_hypr"] = saved
        batch = "; ".join(f"keyword {k} {v}" for k, v in HYPR_POWERSAVE_VALUES.items())
    else:
        restore = dict(HYPR_RESTORE_DEFAULTS)
        if isinstance(st.get("saved_hypr"), dict):
            for k in HYPR_RESTORE_DEFAULTS:
                val = st["saved_hypr"].get(k)
                if isinstance(val, str) and val:
                    restore[k] = val
        batch = "; ".join(f"keyword {k} {v}" for k, v in restore.items())
        st["saved_hypr"] = {}

    rc, _out, err = run_cmd(["hyprctl", "--batch", batch], timeout=5.0)
    if rc != 0:
        return False, f"Hyprland設定失敗: {err or f'rc={rc}'}"
    return True, None


def apply_brightness(enable: bool, cap_pct: int, st: dict[str, Any]) -> tuple[bool, str | None]:
    bctl = shutil.which("brightnessctl")
    if not bctl:
        return False, None
    if enable:
        rc1, cur_s, _ = run_cmd([bctl, "get"], timeout=3.0)
        rc2, max_s, _ = run_cmd([bctl, "max"], timeout=3.0)
        if rc1 != 0 or rc2 != 0 or not cur_s.isdigit() or not max_s.isdigit():
            return False, None
        cur_val = int(cur_s)
        max_val = max(1, int(max_s))
        target_val = max(1, int(round(max_val * cap_pct / 100.0)))
        if cur_val > target_val:
            st["saved_brightness"] = cur_val
            rc, _out, err = run_cmd([bctl, "set", str(target_val)], timeout=3.0)
            if rc != 0:
                st["saved_brightness"] = None
                return False, f"輝度変更失敗: {err or f'rc={rc}'}"
            return True, None
        # Already at or below cap; nothing to lower/restore.
        st["saved_brightness"] = None
        return True, None
    else:
        saved = st.get("saved_brightness")
        st["saved_brightness"] = None
        if isinstance(saved, int) and saved > 0:
            rc, _out, err = run_cmd([bctl, "set", str(saved)], timeout=3.0)
            if rc != 0:
                return False, f"輝度復帰失敗: {err or f'rc={rc}'}"
        return True, None


def apply_bluetooth(enable: bool, st: dict[str, Any]) -> tuple[bool, str | None]:
    bt = shutil.which("bluetoothctl")
    if not bt:
        return False, None
    if enable:
        rc, out, _ = run_cmd([bt, "show"], timeout=4.0)
        if rc != 0 or "Powered: yes" not in out:
            st["bt_powered_off"] = False
            return False, None
        # Do not cut off Bluetooth if any device is actively connected.
        rc_c, out_c, _ = run_cmd([bt, "devices", "Connected"], timeout=4.0)
        if rc_c == 0 and any(line.strip().startswith("Device ") for line in out_c.splitlines()):
            st["bt_powered_off"] = False
            return False, None
        rc_off, _o, err = run_cmd([bt, "power", "off"], timeout=5.0)
        if rc_off != 0:
            return False, f"Bluetooth停止失敗: {err or f'rc={rc_off}'}"
        st["bt_powered_off"] = True
        return True, None
    else:
        was_off = bool(st.get("bt_powered_off"))
        st["bt_powered_off"] = False
        if was_off:
            rc_on, _o, err = run_cmd([bt, "power", "on"], timeout=5.0)
            if rc_on != 0:
                return False, f"Bluetooth復帰失敗: {err or f'rc={rc_on}'}"
        return True, None


def apply_services(enable: bool, st: dict[str, Any]) -> tuple[bool, str | None]:
    if enable:
        rc, out, _ = run_cmd(
            ["systemctl", "--user", "show", "-p", "ActiveState", "--value", *DEFAULT_SERVICES],
            timeout=3.0,
        )
        if rc != 0:
            st["paused_services"] = []
            return False, None
        states = [line.strip() for line in out.splitlines()]
        active_units = [
            unit for unit, state in zip(DEFAULT_SERVICES, states) if state in ("active", "activating")
        ]
        if active_units:
            rc_stop, _o, err = run_cmd(
                ["systemctl", "--user", "stop", "--no-block", *active_units],
                timeout=4.0,
            )
            if rc_stop != 0:
                st["paused_services"] = []
                return False, f"裏方サービス停止失敗: {err or f'rc={rc_stop}'}"
        st["paused_services"] = active_units
        return True, None
    else:
        paused = st.get("paused_services") or []
        st["paused_services"] = []
        if paused:
            # Start in reverse order so servers (e.g. activitywatch) are queued before watchers.
            run_cmd(
                ["systemctl", "--user", "start", "--no-block", *reversed(paused)],
                timeout=4.0,
            )
        return True, None


def build_status(cfg: dict[str, Any], st: dict[str, Any]) -> dict[str, Any]:
    bat = read_battery_info()
    return {
        "active": bool(st.get("active")),
        "reason": st.get("reason") or ("manual" if st.get("active") else "off"),
        "applied": dict(st.get("applied") or {}),
        "paused_services": list(st.get("paused_services") or []),
        "saved_brightness": st.get("saved_brightness"),
        "bt_powered_off": bool(st.get("bt_powered_off")),
        "error": st.get("error"),
        "config": dict(cfg),
        "battery": bat,
        "updated_at": int(time.time()),
    }


def write_status(cfg: dict[str, Any], st: dict[str, Any]) -> dict[str, Any]:
    payload = build_status(cfg, st)
    atomic_write_json(status_path(), payload)
    return payload


def turn_on(reason: str = "manual", notify: bool = True) -> dict[str, Any]:
    cfg = load_config()
    st = load_state()
    if st["active"]:
        return write_status(cfg, st)

    errors: list[str] = []
    applied = default_state()["applied"]

    if cfg["hyprland"]:
        ok, err = apply_hyprland(True, st)
        applied["hyprland"] = ok
        if err:
            errors.append(err)

    if cfg["brightness"]:
        ok, err = apply_brightness(True, cfg["brightness_cap"], st)
        applied["brightness"] = ok
        if err:
            errors.append(err)

    if cfg["cpu"]:
        ok, err = apply_cpu(True)
        applied["cpu"] = ok
        if err:
            errors.append(err)

    if cfg["services"]:
        ok, err = apply_services(True, st)
        applied["services"] = ok
        if err:
            errors.append(err)

    if cfg["bluetooth"]:
        ok, err = apply_bluetooth(True, st)
        applied["bluetooth"] = ok
        if err:
            errors.append(err)

    st["active"] = True
    st["reason"] = reason
    st["applied"] = applied
    st["manual_dismiss_low_battery"] = False
    st["error"] = " / ".join(errors) if errors else None
    save_state(st)
    payload = write_status(cfg, st)

    if notify:
        summary_parts = []
        if applied["cpu"]:
            summary_parts.append("CPU省電力")
        if applied["hyprland"]:
            summary_parts.append("描画軽量化")
        if applied["brightness"] and st.get("saved_brightness") is not None:
            summary_parts.append(f"輝度{cfg['brightness_cap']}%")
        if applied["bluetooth"] and st.get("bt_powered_off"):
            summary_parts.append("BTオフ")
        if applied["services"] and st.get("paused_services"):
            summary_parts.append(f"裏方{len(st['paused_services'])}件停止")
        detail = "・".join(summary_parts) if summary_parts else "有効化しました"
        title = "省電力モード ON（バッテリー低下）" if reason == "low-battery" else "省電力モード ON"
        send_notification(title, detail)

    return payload


def turn_off(reason: str = "manual", notify: bool = True) -> dict[str, Any]:
    cfg = load_config()
    st = load_state()
    if not st["active"]:
        return write_status(cfg, st)

    errors: list[str] = []
    applied = st.get("applied") or {}

    if applied.get("hyprland"):
        _ok, err = apply_hyprland(False, st)
        if err:
            errors.append(err)

    if applied.get("brightness"):
        _ok, err = apply_brightness(False, cfg["brightness_cap"], st)
        if err:
            errors.append(err)

    if applied.get("cpu"):
        _ok, err = apply_cpu(False)
        if err:
            errors.append(err)

    if applied.get("services"):
        _ok, err = apply_services(False, st)
        if err:
            errors.append(err)

    if applied.get("bluetooth"):
        _ok, err = apply_bluetooth(False, st)
        if err:
            errors.append(err)

    bat = read_battery_info()
    st["active"] = False
    st["reason"] = "off"
    st["applied"] = default_state()["applied"]
    # If the user manually turned off power-save while battery is low, do not
    # immediately re-enable it until AC is connected or battery recovers.
    if (
        reason == "manual"
        and bat["present"]
        and not bat["ac_online"]
        and bat["capacity"] is not None
        and bat["capacity"] <= cfg["low_battery_threshold"]
    ):
        st["manual_dismiss_low_battery"] = True
    elif reason == "ac":
        st["manual_dismiss_low_battery"] = False

    st["error"] = " / ".join(errors) if errors else None
    save_state(st)
    payload = write_status(cfg, st)

    if notify:
        title = "省電力モード OFF（AC接続）" if reason == "ac" else "省電力モード OFF"
        send_notification(title, "通常モードに復帰しました")

    return payload


def parse_bool(raw: str) -> bool:
    v = raw.strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"invalid boolean: {raw}")


def set_config_key(key: str, raw_value: str) -> dict[str, Any]:
    norm_key = key.replace("-", "_")
    cfg = load_config()
    st = load_state()

    if norm_key in BOOL_KEYS:
        val = parse_bool(raw_value)
        old_val = cfg[norm_key]
        cfg[norm_key] = val
        save_config(cfg)

        # Live-apply or revert when power-save is currently active.
        if st["active"] and val != old_val:
            err: str | None = None
            if norm_key == "cpu":
                ok, err = apply_cpu(val)
                st["applied"]["cpu"] = ok if val else False
            elif norm_key == "hyprland":
                ok, err = apply_hyprland(val, st)
                st["applied"]["hyprland"] = ok if val else False
            elif norm_key == "brightness":
                ok, err = apply_brightness(val, cfg["brightness_cap"], st)
                st["applied"]["brightness"] = ok if val else False
            elif norm_key == "bluetooth":
                ok, err = apply_bluetooth(val, st)
                st["applied"]["bluetooth"] = ok if val else False
            elif norm_key == "services":
                ok, err = apply_services(val, st)
                st["applied"]["services"] = ok if val else False
            st["error"] = err
            save_state(st)
    elif norm_key in INT_KEYS:
        lo, hi = INT_KEYS[norm_key]
        val = max(lo, min(hi, int(raw_value)))
        cfg[norm_key] = val
        save_config(cfg)
        if norm_key == "brightness_cap" and st["active"] and cfg["brightness"]:
            # Re-apply new brightness cap without overwriting original saved_brightness.
            bctl = shutil.which("brightnessctl")
            if bctl:
                rc1, cur_s, _ = run_cmd([bctl, "get"], timeout=3.0)
                rc2, max_s, _ = run_cmd([bctl, "max"], timeout=3.0)
                if rc1 == 0 and rc2 == 0 and cur_s.isdigit() and max_s.isdigit():
                    max_val = max(1, int(max_s))
                    if st.get("saved_brightness") is None:
                        st["saved_brightness"] = int(cur_s)
                    target_val = max(1, int(round(max_val * val / 100.0)))
                    run_cmd([bctl, "set", str(target_val)], timeout=3.0)
                    st["applied"]["brightness"] = True
                    save_state(st)
    else:
        raise ValueError(f"unknown config key: {key}")

    return write_status(cfg, st)


def with_lock(fn, *args, **kwargs):
    lp = lock_path()
    lp.parent.mkdir(parents=True, exist_ok=True)
    with lp.open("w", encoding="utf-8") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            return fn(*args, **kwargs)
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def watch_loop(interval: float = 15.0) -> int:
    stop = False

    def handle_sig(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    prev_ac: bool | None = None

    def tick() -> None:
        nonlocal prev_ac
        cfg = load_config()
        st = load_state()
        bat = read_battery_info()

        ac_now = bool(bat["ac_online"])
        cap = bat["capacity"]
        discharging = bat["present"] and not ac_now

        # Clear manual low-battery dismissal once AC connects or battery recovers.
        if st.get("manual_dismiss_low_battery"):
            if ac_now or (cap is not None and cap > cfg["low_battery_threshold"] + 5):
                st["manual_dismiss_low_battery"] = False
                save_state(st)

        # Edge-triggered AC plug-in -> auto OFF.
        if cfg["auto_off_on_ac"] and prev_ac is False and ac_now and st["active"]:
            turn_off(reason="ac", notify=True)
            prev_ac = ac_now
            return

        # Low battery while discharging -> auto ON.
        if (
            cfg["auto_on_low_battery"]
            and discharging
            and cap is not None
            and cap <= cfg["low_battery_threshold"]
            and not st["active"]
            and not st.get("manual_dismiss_low_battery")
        ):
            turn_on(reason="low-battery", notify=True)
            prev_ac = ac_now
            return

        prev_ac = ac_now
        write_status(cfg, st)

    while not stop:
        try:
            with_lock(tick)
        except Exception as exc:
            print(f"power-save watch error: {exc}", file=sys.stderr, flush=True)
        # Sleep in short slices so SIGTERM exits promptly.
        deadline = time.monotonic() + interval
        while not stop and time.monotonic() < deadline:
            time.sleep(0.5)

    return 0


def format_human(payload: dict[str, Any]) -> str:
    state = "ON" if payload["active"] else "OFF"
    reason = payload.get("reason", "off")
    bat = payload.get("battery", {})
    cap = bat.get("capacity")
    bat_str = f"{cap}% ({bat.get('status', '?')})" if cap is not None else "N/A"
    lines = [f"power-save: {state} (reason={reason}, battery={bat_str})"]
    if payload["active"]:
        ap = payload.get("applied", {})
        parts = [k for k, v in ap.items() if v]
        lines.append(f"  applied: {', '.join(parts) if parts else 'none'}")
        if payload.get("paused_services"):
            lines.append(f"  paused:  {', '.join(payload['paused_services'])}")
    if payload.get("error"):
        lines.append(f"  error:   {payload['error']}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="power-save", description="Power-save mode controller")
    parser.add_argument("--json", action="store_true", help="Output JSON status")
    sub = parser.add_subparsers(dest="cmd")

    p_on = sub.add_parser("on", help="Enable power-save mode")
    p_on.add_argument("--reason", default="manual", choices=["manual", "low-battery"])
    p_on.add_argument("--no-notify", action="store_true")

    p_off = sub.add_parser("off", help="Disable power-save mode")
    p_off.add_argument("--reason", default="manual", choices=["manual", "ac"])
    p_off.add_argument("--no-notify", action="store_true")

    p_toggle = sub.add_parser("toggle", help="Toggle power-save mode")
    p_toggle.add_argument("--no-notify", action="store_true")

    sub.add_parser("status", help="Show current status")

    p_cfg = sub.add_parser("config", help="Read or update configuration")
    cfg_sub = p_cfg.add_subparsers(dest="cfg_cmd", required=True)
    p_set = cfg_sub.add_parser("set", help="Set a config key")
    p_set.add_argument("key")
    p_set.add_argument("value")

    p_watch = sub.add_parser("watch", help="Run battery/AC auto-switch watcher")
    p_watch.add_argument("--interval", type=float, default=15.0)

    args = parser.parse_args(argv)
    cmd = args.cmd or "status"

    if cmd == "watch":
        return watch_loop(interval=args.interval)

    if cmd == "on":
        payload = with_lock(turn_on, reason=args.reason, notify=not args.no_notify)
    elif cmd == "off":
        payload = with_lock(turn_off, reason=args.reason, notify=not args.no_notify)
    elif cmd == "toggle":
        def _toggle():
            st = load_state()
            if st["active"]:
                return turn_off(reason="manual", notify=not args.no_notify)
            return turn_on(reason="manual", notify=not args.no_notify)

        payload = with_lock(_toggle)
    elif cmd == "config" and args.cfg_cmd == "set":
        payload = with_lock(set_config_key, args.key, args.value)
    else:
        payload = with_lock(lambda: write_status(load_config(), load_state()))

    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(format_human(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
