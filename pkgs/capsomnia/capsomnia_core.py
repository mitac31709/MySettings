"""Core state, policies, timers, and i18n for Capsomnia on NixOS/Hyprland."""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

VERSION = "4.3.5-nixos.1"

AUTO_OFF_PRESETS: tuple[int, ...] = (15, 30, 60, 120, 240, 480)
MIN_CUSTOM_MINUTES = 1
MAX_CUSTOM_MINUTES = 24 * 60
DEFAULT_SHORTCUT = "SUPER + ALT + C"

HOTSPOT_GATEWAYS: frozenset[str] = frozenset(
    {
        "172.20.10.1",  # iPhone Personal Hotspot
        "192.168.43.1",  # Android Personal Hotspot
        "192.168.137.1",  # Windows Mobile Hotspot / ICS
    }
)
HOTSPOT_PREFIXES: tuple[str, ...] = (
    "172.20.10.",
    "192.168.43.",
    "192.168.137.",
)

SUPPORTED_LANGUAGES: tuple[str, ...] = ("auto", "ja", "en")

DEFAULT_PREFS: dict[str, Any] = {
    "dedicated_caps_lock_mode": True,
    "show_menu_bar_icon": True,
    "keep_display_awake": True,
    "lock_on_lid_open": False,
    "keep_hotspot_alive": False,
    "ignore_external_caps_lock_off_while_lid_closed": False,
    "auto_off_minutes": 0,
    "language": "auto",
    "launch_at_login": True,
    "shortcut": DEFAULT_SHORTCUT,
    "did_complete_initial_setup": False,
}

CLI_KEY_ALIASES: dict[str, str] = {
    "dedicated-caps-lock-mode": "dedicated_caps_lock_mode",
    "dedicated_caps_lock_mode": "dedicated_caps_lock_mode",
    "prevent-all-caps": "dedicated_caps_lock_mode",
    "show-menu-bar-icon": "show_menu_bar_icon",
    "show_menu_bar_icon": "show_menu_bar_icon",
    "keep-display-awake": "keep_display_awake",
    "keep_display_awake": "keep_display_awake",
    "lock-on-lid-open": "lock_on_lid_open",
    "lock_on_lid_open": "lock_on_lid_open",
    "keep-hotspot-alive": "keep_hotspot_alive",
    "keep_hotspot_alive": "keep_hotspot_alive",
    "ignore-external-caps-lock-off-while-lid-closed": "ignore_external_caps_lock_off_while_lid_closed",
    "ignore_external_caps_lock_off_while_lid_closed": "ignore_external_caps_lock_off_while_lid_closed",
    "auto-off-minutes": "auto_off_minutes",
    "auto_off_minutes": "auto_off_minutes",
    "language": "language",
    "launch-at-login": "launch_at_login",
    "launch_at_login": "launch_at_login",
    "shortcut": "shortcut",
    "did-complete-initial-setup": "did_complete_initial_setup",
    "did_complete_initial_setup": "did_complete_initial_setup",
}


def clamp_auto_off_minutes(minutes: int) -> int:
    return min(max(int(minutes), 0), MAX_CUSTOM_MINUTES)


def normalize_prefs(raw: dict[str, Any] | None) -> dict[str, Any]:
    merged = dict(DEFAULT_PREFS)
    if isinstance(raw, dict):
        for k, v in raw.items():
            key = CLI_KEY_ALIASES.get(k, k)
            if key in merged:
                merged[key] = v
    merged["dedicated_caps_lock_mode"] = bool(merged["dedicated_caps_lock_mode"])
    merged["show_menu_bar_icon"] = bool(merged["show_menu_bar_icon"])
    merged["keep_display_awake"] = bool(merged["keep_display_awake"])
    merged["lock_on_lid_open"] = bool(merged["lock_on_lid_open"])
    merged["keep_hotspot_alive"] = bool(merged["keep_hotspot_alive"])
    merged["ignore_external_caps_lock_off_while_lid_closed"] = bool(
        merged["ignore_external_caps_lock_off_while_lid_closed"]
    )
    merged["launch_at_login"] = bool(merged["launch_at_login"])
    merged["did_complete_initial_setup"] = bool(merged["did_complete_initial_setup"])
    try:
        merged["auto_off_minutes"] = clamp_auto_off_minutes(int(merged["auto_off_minutes"]))
    except (TypeError, ValueError):
        merged["auto_off_minutes"] = 0
    lang = str(merged.get("language", "auto"))
    if lang not in SUPPORTED_LANGUAGES:
        lang = "auto"
    merged["language"] = lang
    merged["shortcut"] = str(merged.get("shortcut") or DEFAULT_SHORTCUT)
    return merged


def resolve_language(pref_lang: str, env_lang: str | None = None) -> str:
    if pref_lang in ("ja", "en"):
        return pref_lang
    probe = (env_lang or os.environ.get("LC_ALL") or os.environ.get("LANG") or "ja").lower()
    return "ja" if probe.startswith("ja") else "en"


def parse_bool_str(value: str) -> bool:
    low = value.strip().lower()
    if low in ("1", "true", "yes", "on"):
        return True
    if low in ("0", "false", "no", "off"):
        return False
    raise ValueError(f"invalid boolean: {value!r}")


_DUR_PART_RE = re.compile(r"(\d+)\s*([smh])", re.IGNORECASE)


def parse_duration_seconds(spec: str) -> int:
    """Parse cpsm duration strings like '90s', '30m', '2h', '1h30m' into seconds (1..86400)."""
    text = spec.strip()
    if not text:
        raise ValueError("empty duration")
    if text.isdigit():
        secs = int(text)
    else:
        pos = 0
        secs = 0
        for m in _DUR_PART_RE.finditer(text):
            if m.start() != pos:
                raise ValueError(f"invalid duration: {spec!r}")
            pos = m.end()
            num = int(m.group(1))
            unit = m.group(2).lower()
            if unit == "s":
                secs += num
            elif unit == "m":
                secs += num * 60
            elif unit == "h":
                secs += num * 3600
        if pos != len(text):
            raise ValueError(f"invalid duration: {spec!r}")
    if secs < 1 or secs > MAX_CUSTOM_MINUTES * 60:
        raise ValueError(f"duration must be between 1s and 24h: {spec!r}")
    return secs


def format_countdown(remaining_sec: float) -> str:
    total = max(0, int(remaining_sec))
    hours = total // 3600
    minutes = (total % 3600) // 60
    seconds = total % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def format_compact_duration(minutes: int) -> str:
    if minutes <= 0:
        return "∞"
    hours, mins = divmod(minutes, 60)
    if hours == 0:
        return f"{mins}m"
    if mins == 0:
        return f"{hours}h"
    return f"{hours}h {mins}m"


class AutoOffTimerState:
    """Tracks auto-off countdown with support for one-shot CLI overrides."""

    def __init__(self) -> None:
        self.saved_default_minutes: int = 0
        self.active_duration_seconds: int | None = None
        self.is_one_shot: bool = False
        self.deadline_monotonic: float | None = None

    def set_saved_default(self, minutes: int) -> None:
        self.saved_default_minutes = clamp_auto_off_minutes(minutes)

    def start_for_awake_on(self, now: float) -> None:
        if self.saved_default_minutes > 0:
            self.active_duration_seconds = self.saved_default_minutes * 60
            self.is_one_shot = False
            self.deadline_monotonic = now + self.active_duration_seconds
        else:
            self.clear()

    def set_one_shot(self, seconds: int, now: float) -> None:
        if seconds < 1 or seconds > MAX_CUSTOM_MINUTES * 60:
            raise ValueError("seconds out of range")
        self.active_duration_seconds = seconds
        self.is_one_shot = True
        self.deadline_monotonic = now + seconds

    def apply_saved_default_while_on(self, minutes: int, now: float) -> None:
        self.set_saved_default(minutes)
        if self.is_one_shot:
            return
        if self.saved_default_minutes <= 0:
            self.clear()
        else:
            self.active_duration_seconds = self.saved_default_minutes * 60
            self.deadline_monotonic = now + self.active_duration_seconds

    def restart(self, now: float) -> bool:
        if self.active_duration_seconds is None or self.active_duration_seconds <= 0:
            return False
        self.deadline_monotonic = now + self.active_duration_seconds
        return True

    def cancel(self) -> None:
        self.clear()

    def clear(self) -> None:
        self.active_duration_seconds = None
        self.is_one_shot = False
        self.deadline_monotonic = None

    def remaining_seconds(self, now: float) -> float | None:
        if self.deadline_monotonic is None:
            return None
        return max(0.0, self.deadline_monotonic - now)

    def is_expired(self, now: float) -> bool:
        return self.deadline_monotonic is not None and now >= self.deadline_monotonic

    def status_dict(self, awake_on: bool, now: float) -> dict[str, Any]:
        rem = self.remaining_seconds(now) if awake_on else None
        return {
            "active": bool(awake_on and self.deadline_monotonic is not None),
            "saved_default_minutes": self.saved_default_minutes,
            "one_shot": bool(awake_on and self.is_one_shot),
            "duration_seconds": self.active_duration_seconds if awake_on else None,
            "remaining_seconds": int(rem) if rem is not None else None,
            "remaining_formatted": format_countdown(rem) if rem is not None else None,
        }


def should_reassert_on_external_off(
    *,
    preference_enabled: bool,
    sleep_prevention_active: bool,
    recent_user_action: bool,
    auto_off_in_progress: bool,
    clamshell_closed: bool | None,
) -> bool:
    """Re-assert awake state if an external Caps Lock off happens while lid is closed."""
    return (
        preference_enabled
        and sleep_prevention_active
        and not recent_user_action
        and not auto_off_in_progress
        and clamshell_closed is True
    )


@dataclass
class LidOpenLockEvent:
    opened_at: float
    outcome: str  # locked | already_locked | unavailable | state_unavailable


class LidOpenLockTracker:
    """Detects closed -> open lid transitions while eligible and triggers screen lock."""

    def __init__(self) -> None:
        self._last_closed: bool | None = None
        self.last_event: LidOpenLockEvent | None = None

    def needs_lock_check(
        self,
        *,
        eligible: bool,
        clamshell_closed: bool | None,
    ) -> bool:
        return bool(eligible and self._last_closed is True and clamshell_closed is False)

    def update(
        self,
        *,
        eligible: bool,
        clamshell_closed: bool | None,
        is_locked: bool | None,
        now: float,
    ) -> str | None:
        """Returns 'lock' if a lock should be requested now, else None."""
        if not eligible or clamshell_closed is None:
            self._last_closed = None
            return None

        opened = self._last_closed is True and clamshell_closed is False
        self._last_closed = clamshell_closed
        if not opened:
            return None

        if is_locked is True:
            self.last_event = LidOpenLockEvent(opened_at=now, outcome="already_locked")
            return None
        if is_locked is None:
            self.last_event = LidOpenLockEvent(opened_at=now, outcome="state_unavailable")
            return None

        self.last_event = LidOpenLockEvent(opened_at=now, outcome="locked")
        return "lock"


def is_mobile_hotspot_route(gateway: str | None, src_ip: str | None) -> bool:
    if not gateway or not src_ip:
        return False
    return gateway in HOTSPOT_GATEWAYS and any(src_ip.startswith(p) for p in HOTSPOT_PREFIXES)


def parse_default_route_json(raw_json: str) -> tuple[str | None, str | None, str | None]:
    """Parse `ip -j route show default` -> (dev, gateway, prefsrc)."""
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError:
        return (None, None, None)
    if not isinstance(data, list) or not data:
        return (None, None, None)
    best = sorted(data, key=lambda r: int(r.get("metric", 0)))[0]
    return (
        best.get("dev"),
        best.get("gateway"),
        best.get("prefsrc"),
    )


def parse_lid_state_text(text: str) -> bool | None:
    """Parse /proc/acpi/button/lid/*/state content -> True (closed), False (open), None."""
    low = text.lower()
    if "closed" in low:
        return True
    if "open" in low:
        return False
    return None


def xdg_config_path() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    return base / "capsomnia" / "settings.json"


def xdg_state_dir() -> Path:
    base = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
    return base / "capsomnia"


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(base) / "capsomnia"


def load_prefs(path: Path | None = None) -> dict[str, Any]:
    target = path or xdg_config_path()
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
        return normalize_prefs(raw)
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULT_PREFS)


def save_prefs(prefs: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
    target = path or xdg_config_path()
    normalized = normalize_prefs(prefs)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(normalized, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(target)
    return normalized


STRINGS: dict[str, dict[str, str]] = {
    "ja": {
        "app_name": "画面常時オン (Capsomnia)",
        "subtitle_on": "画面常時オン・蓋閉じ処理継続中（自動減光・ロック・スリープを抑止）",
        "subtitle_off": "通常のスリープ・自動消灯動作",
        "subtitle_err": "スリープ抑止の検証に失敗しました（再試行中）",
        "btn_turn_on": "ON にする",
        "btn_turn_off": "OFF にする",
        "sec_daily": "日常のコントロール",
        "keep_display_awake": "蓋閉じ中も画面セッションを維持（最小輝度 / Computer Use）",
        "keep_display_awake_desc": "蓋を閉じた後も内蔵画面の輝度を最小に下げてセッションを維持します（OFF 時は蓋閉じ中のみ消灯し処理は継続）。",
        "lock_on_lid_open": "蓋を開けたら画面をロック",
        "lock_on_lid_open_desc": "画面常時オンの間、蓋が開いたことを検出すると hyprlock で画面をロックします。",
        "auto_off_timer": "自動オフタイマー",
        "auto_off_timer_desc": "満了すると画面常時オンをオフにし、蓋が閉じていればスリープします。",
        "timer_off": "無制限 (∞)",
        "timer_custom": "カスタム",
        "timer_restart": "リセット",
        "timer_remaining": "残り時間",
        "sec_advanced": "詳細設定",
        "show_menubar": "バーにステータスを表示",
        "prevent_all_caps": "Caps Lock でオン/オフ（大文字固定を防ぐ）",
        "prevent_all_caps_desc": "オンの間、Caps Lock キーを大文字ロックせず画面常時オンの物理スイッチ兼ランプとして使います（Shift での大文字入力は維持）。",
        "shortcut_label": "切り替えショートカット",
        "ignore_external_off": "蓋閉じ中の外部 Caps Lock オフを無視",
        "keep_hotspot": "テザリング時に接続を維持",
        "keep_hotspot_desc": "モバイル共有ゲートウェイへ1分ごとに疎通確認を送りアイドル切断を防ぎます。",
        "language": "言語",
        "show_welcome": "ウェルカムガイドを表示…",
        "lid_open": "蓋: 開",
        "lid_closed": "蓋: 閉",
        "lid_unknown": "蓋: 不明",
        "welcome_title": "画面常時オン (Capsomnia) へようこそ",
        "welcome_body": "バーのボタン・Caps Lock キー・ショートカットから「画面常時オン」を切り替えられます。\nオンの間は自動減光・ロック・消灯を抑止し、蓋を閉じても AI エージェントや SSH・ビルドを継続できます。",
        "welcome_start": "始める",
        "custom_hours": "時間",
        "custom_minutes": "分",
        "custom_apply": "適用",
    },
    "en": {
        "app_name": "Keep Screen On (Capsomnia)",
        "subtitle_on": "Keep Screen On active (keeps display & closed-lid tasks running)",
        "subtitle_off": "Normal idle & sleep behavior",
        "subtitle_err": "Sleep prevention verification failed (retrying)",
        "btn_turn_on": "Turn ON",
        "btn_turn_off": "Turn OFF",
        "sec_daily": "Day-to-day Controls",
        "keep_display_awake": "Keep display session alive while lid closed (min backlight)",
        "keep_display_awake_desc": "Dims built-in backlight to minimum while lid is closed; if off, blanks built-in display on lid close while keeping tasks running.",
        "lock_on_lid_open": "Lock when lid opens",
        "lock_on_lid_open_desc": "Locks the screen with hyprlock after detecting a closed-to-open lid transition while active.",
        "auto_off_timer": "Auto-off timer",
        "auto_off_timer_desc": "When expired, turns Keep Screen On off and sleeps immediately if the lid is closed.",
        "timer_off": "Off (∞)",
        "timer_custom": "Custom",
        "timer_restart": "Restart",
        "timer_remaining": "Remaining",
        "sec_advanced": "Advanced Settings",
        "show_menubar": "Show indicator in bar",
        "prevent_all_caps": "Toggle with Caps Lock (prevent all-caps)",
        "prevent_all_caps_desc": "Uses Caps Lock LED & key purely as a keep-awake switch without locking uppercase input (Shift still works).",
        "shortcut_label": "Toggle shortcut",
        "ignore_external_off": "Ignore external Caps Lock off while lid closed",
        "keep_hotspot": "Keep hotspot connected",
        "keep_hotspot_desc": "Sends a tiny local gateway probe once per minute on recognized mobile hotspots.",
        "language": "Language",
        "show_welcome": "Show Welcome Guide…",
        "lid_open": "Lid: Open",
        "lid_closed": "Lid: Closed",
        "lid_unknown": "Lid: Unknown",
        "welcome_title": "Welcome to Keep Screen On (Capsomnia)",
        "welcome_body": "Toggle Keep Screen On from the top bar, Caps Lock, or your shortcut.\nWhile active, idle dim/lock/DPMS-off are inhibited and tasks continue running even with the lid closed.",
        "welcome_start": "Get Started",
        "custom_hours": "Hours",
        "custom_minutes": "Minutes",
        "custom_apply": "Apply",
    },
}


def tr(lang: str, key: str) -> str:
    resolved = resolve_language(lang)
    return STRINGS.get(resolved, STRINGS["en"]).get(key, key)


def ok_response(result: Any) -> dict[str, Any]:
    return {"ok": True, "result": result}


def err_response(message: str) -> dict[str, Any]:
    return {"ok": False, "error": message}
