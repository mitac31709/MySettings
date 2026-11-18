#!/usr/bin/env python3
"""Rofi quick menu for Capsomnia."""

from __future__ import annotations

import subprocess
import sys

from capsomnia_core import (
    AUTO_OFF_PRESETS,
    format_compact_duration,
    format_countdown,
    resolve_language,
)
from cpsm import send_control


def run_rofi(lines: list[str], prompt: str) -> str:
    proc = subprocess.run(
        ["rofi", "-dmenu", "-i", "-p", prompt],
        input="\n".join(lines),
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def main() -> int:
    resp = send_control(["status"])
    if not resp.get("ok"):
        subprocess.run(
            ["notify-send", "Capsomnia", f"Daemon error: {resp.get('error')}"],
            check=False,
        )
        return 1

    st = resp["result"]
    settings = st["settings"]
    lang = resolve_language(settings.get("language", "auto"))
    awake = bool(st["awake_on"])
    timer = st["timer"]
    keep_disp = bool(settings.get("keep_display_awake"))
    lock_open = bool(settings.get("lock_on_lid_open"))
    saved_mins = int(settings.get("auto_off_minutes", 0))

    actions: list[tuple[str, callable]] = []

    if lang == "ja":
        if awake:
            rem = timer.get("remaining_seconds")
            rem_txt = f" (残り {format_countdown(rem)})" if timer.get("active") and rem is not None else ""
            actions.append((f"● Capsomnia ON{rem_txt} │ OFF にする（通常スリープへ）", lambda: send_control(["off", "--no-sleep"])))
            actions.append(("Capsomnia │ OFF にして今すぐスリープ", lambda: send_control(["off"])))
        else:
            actions.append(("○ Capsomnia OFF │ ON にする（蓋閉じでも起き続ける）", lambda: send_control(["on"])))

        disp_label = "ON" if keep_disp else "OFF"
        actions.append((f"画面をスリープさせない (Computer Use) [{disp_label}] │ 切替", lambda: send_control(["settings", "set", "keep-display-awake", "false" if keep_disp else "true"])))

        if keep_disp:
            lock_label = "ON" if lock_open else "OFF"
            actions.append((f"蓋を開けたら画面をロック [{lock_label}] │ 切替", lambda: send_control(["settings", "set", "lock-on-lid-open", "false" if lock_open else "true"])))

        if timer.get("active"):
            actions.append(("タイマー │ 今すぐリセット (リスタート)", lambda: send_control(["timer", "restart"])))
            actions.append(("タイマー │ 一時停止/キャンセル", lambda: send_control(["timer", "cancel"])))

        mark_inf = "✓ " if saved_mins == 0 else ""
        actions.append((f"既定タイマー │ {mark_inf}無制限 (∞)", lambda: send_control(["settings", "set", "auto-off-minutes", "0"])))
        for mins in AUTO_OFF_PRESETS:
            mark = "✓ " if saved_mins == mins else ""
            lbl = format_compact_duration(mins)
            actions.append((f"既定タイマー │ {mark}{lbl}", lambda m=mins: send_control(["settings", "set", "auto-off-minutes", str(m)])))

        def _custom_ja() -> None:
            val = run_rofi(["10m", "45m", "90m", "3h", "6h", "12h"], "今回限りのタイマー (例: 45m, 2h)")
            if val:
                res = send_control(["timer", "set", val])
                if not res.get("ok"):
                    subprocess.run(["notify-send", "Capsomnia", f"エラー: {res.get('error')}"], check=False)

        actions.append(("タイマー │ カスタム時間（今回限り）…", _custom_ja))
        actions.append(("設定ウィンドウを開く…", lambda: subprocess.Popen(["capsomnia-settings"])))
        actions.append(("ウェルカムガイドを開く…", lambda: subprocess.Popen(["capsomnia-settings", "--welcome"])))
        actions.append(("終了（通常スリープに戻して停止）", lambda: subprocess.run(["systemctl", "--user", "stop", "capsomniad.service"], check=False)))
        prompt = "Capsomnia"
    else:
        if awake:
            rem = timer.get("remaining_seconds")
            rem_txt = f" ({format_countdown(rem)})" if timer.get("active") and rem is not None else ""
            actions.append((f"● Capsomnia ON{rem_txt} │ Turn OFF", lambda: send_control(["off", "--no-sleep"])))
            actions.append(("Capsomnia │ Turn OFF & Sleep Now", lambda: send_control(["off"])))
        else:
            actions.append(("○ Capsomnia OFF │ Turn ON", lambda: send_control(["on"])))

        disp_label = "ON" if keep_disp else "OFF"
        actions.append((f"Keep display awake (Computer Use) [{disp_label}] │ Toggle", lambda: send_control(["settings", "set", "keep-display-awake", "false" if keep_disp else "true"])))

        if keep_disp:
            lock_label = "ON" if lock_open else "OFF"
            actions.append((f"Lock when lid opens [{lock_label}] │ Toggle", lambda: send_control(["settings", "set", "lock-on-lid-open", "false" if lock_open else "true"])))

        if timer.get("active"):
            actions.append(("Timer │ Restart countdown", lambda: send_control(["timer", "restart"])))
            actions.append(("Timer │ Cancel active timer", lambda: send_control(["timer", "cancel"])))

        mark_inf = "✓ " if saved_mins == 0 else ""
        actions.append((f"Default timer │ {mark_inf}Off (∞)", lambda: send_control(["settings", "set", "auto-off-minutes", "0"])))
        for mins in AUTO_OFF_PRESETS:
            mark = "✓ " if saved_mins == mins else ""
            lbl = format_compact_duration(mins)
            actions.append((f"Default timer │ {mark}{lbl}", lambda m=mins: send_control(["settings", "set", "auto-off-minutes", str(m)])))

        def _custom_en() -> None:
            val = run_rofi(["10m", "45m", "90m", "3h", "6h", "12h"], "One-shot timer (e.g. 45m, 2h)")
            if val:
                res = send_control(["timer", "set", val])
                if not res.get("ok"):
                    subprocess.run(["notify-send", "Capsomnia", f"Error: {res.get('error')}"], check=False)

        actions.append(("Timer │ Custom one-shot duration…", _custom_en))
        actions.append(("Open Settings…", lambda: subprocess.Popen(["capsomnia-settings"])))
        actions.append(("Show Welcome Guide…", lambda: subprocess.Popen(["capsomnia-settings", "--welcome"])))
        actions.append(("Quit Capsomnia (restore normal sleep)", lambda: subprocess.run(["systemctl", "--user", "stop", "capsomniad.service"], check=False)))
        prompt = "Capsomnia"

    choice = run_rofi([lbl for lbl, _ in actions], prompt)
    if not choice:
        return 0

    for lbl, fn in actions:
        if lbl == choice:
            res = fn()
            if isinstance(res, dict) and not res.get("ok"):
                subprocess.run(
                    ["notify-send", "Capsomnia", f"Error: {res.get('error')}"],
                    check=False,
                )
                return 1
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
