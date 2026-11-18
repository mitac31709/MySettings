"""Unit tests for Capsomnia core logic."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from capsomnia_core import (
    AutoOffTimerState,
    LidOpenLockTracker,
    format_compact_duration,
    format_countdown,
    is_mobile_hotspot_route,
    load_prefs,
    normalize_prefs,
    parse_bool_str,
    parse_default_route_json,
    parse_duration_seconds,
    parse_lid_state_text,
    resolve_language,
    save_prefs,
    should_reassert_on_external_off,
)


class CapsomniaCoreTests(unittest.TestCase):
    def test_parse_duration_seconds(self) -> None:
        self.assertEqual(parse_duration_seconds("90s"), 90)
        self.assertEqual(parse_duration_seconds("30m"), 1800)
        self.assertEqual(parse_duration_seconds("2h"), 7200)
        self.assertEqual(parse_duration_seconds("1h30m"), 5400)
        self.assertEqual(parse_duration_seconds("24h"), 86400)
        for bad in ("", "0s", "25h", "abc", "-5m", "10x"):
            with self.assertRaises(ValueError):
                parse_duration_seconds(bad)

    def test_formatters(self) -> None:
        self.assertEqual(format_countdown(3661), "01:01:01")
        self.assertEqual(format_countdown(-5), "00:00:00")
        self.assertEqual(format_compact_duration(0), "∞")
        self.assertEqual(format_compact_duration(15), "15m")
        self.assertEqual(format_compact_duration(120), "2h")
        self.assertEqual(format_compact_duration(90), "1h 30m")

    def test_auto_off_timer_one_shot_preserves_default(self) -> None:
        t = AutoOffTimerState()
        t.set_saved_default(60)
        t.start_for_awake_on(100.0)
        self.assertEqual(t.remaining_seconds(100.0), 3600.0)
        self.assertFalse(t.is_expired(3699.9))
        self.assertTrue(t.is_expired(3700.0))

        # One-shot override leaves saved_default_minutes untouched.
        t.set_one_shot(90, 200.0)
        self.assertEqual(t.saved_default_minutes, 60)
        self.assertTrue(t.is_one_shot)
        self.assertEqual(t.remaining_seconds(230.0), 60.0)

        # Changing saved default while one-shot is active does not clobber one-shot.
        t.apply_saved_default_while_on(120, 230.0)
        self.assertEqual(t.saved_default_minutes, 120)
        self.assertEqual(t.remaining_seconds(230.0), 60.0)

        self.assertTrue(t.restart(300.0))
        self.assertEqual(t.remaining_seconds(300.0), 90.0)
        t.cancel()
        self.assertIsNone(t.remaining_seconds(300.0))

        # Next OFF->ON uses updated saved default.
        t.start_for_awake_on(400.0)
        self.assertEqual(t.remaining_seconds(400.0), 7200.0)

    def test_external_off_policy(self) -> None:
        self.assertTrue(
            should_reassert_on_external_off(
                preference_enabled=True,
                sleep_prevention_active=True,
                recent_user_action=False,
                auto_off_in_progress=False,
                clamshell_closed=True,
            )
        )
        # Auto-off wins over guard.
        self.assertFalse(
            should_reassert_on_external_off(
                preference_enabled=True,
                sleep_prevention_active=True,
                recent_user_action=False,
                auto_off_in_progress=True,
                clamshell_closed=True,
            )
        )
        # Unknown lid state fails open.
        self.assertFalse(
            should_reassert_on_external_off(
                preference_enabled=True,
                sleep_prevention_active=True,
                recent_user_action=False,
                auto_off_in_progress=False,
                clamshell_closed=None,
            )
        )

    def test_lid_open_lock_tracker(self) -> None:
        tr = LidOpenLockTracker()
        # Open while eligible -> no edge yet.
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=False, is_locked=False, now=1.0))
        # Close -> still no lock.
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=True, is_locked=False, now=2.0))
        # Unreadable gap resets edge tracking.
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=None, is_locked=False, now=3.0))
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=False, is_locked=False, now=4.0))
        # Real closed -> open triggers lock once.
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=True, is_locked=False, now=5.0))
        self.assertEqual(
            tr.update(eligible=True, clamshell_closed=False, is_locked=False, now=6.0),
            "lock",
        )
        assert tr.last_event is not None
        self.assertEqual(tr.last_event.outcome, "locked")
        # Already locked does not re-lock.
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=True, is_locked=True, now=7.0))
        self.assertIsNone(tr.update(eligible=True, clamshell_closed=False, is_locked=True, now=8.0))
        self.assertEqual(tr.last_event.outcome, "already_locked")

    def test_hotspot_and_lid_parsers(self) -> None:
        self.assertTrue(is_mobile_hotspot_route("172.20.10.1", "172.20.10.2"))
        self.assertTrue(is_mobile_hotspot_route("192.168.43.1", "192.168.43.99"))
        self.assertFalse(is_mobile_hotspot_route("192.168.1.1", "192.168.1.22"))
        self.assertFalse(is_mobile_hotspot_route("172.20.10.1", "192.168.1.22"))

        dev, gw, src = parse_default_route_json(
            '[{"dev":"wlp1s0","gateway":"172.20.10.1","prefsrc":"172.20.10.2","metric":600}]'
        )
        self.assertEqual((dev, gw, src), ("wlp1s0", "172.20.10.1", "172.20.10.2"))
        self.assertTrue(parse_lid_state_text("state:      closed\n"))
        self.assertFalse(parse_lid_state_text("state:      open\n"))
        self.assertIsNone(parse_lid_state_text("unknown"))

    def test_prefs_and_helpers(self) -> None:
        self.assertTrue(parse_bool_str("true"))
        self.assertFalse(parse_bool_str("off"))
        self.assertEqual(resolve_language("auto", "ja_JP.UTF-8"), "ja")
        self.assertEqual(resolve_language("auto", "en_US.UTF-8"), "en")
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "settings.json"
            saved = save_prefs({"auto-off-minutes": 9999, "keep-display-awake": True}, p)
            self.assertEqual(saved["auto_off_minutes"], 1440)
            self.assertTrue(saved["keep_display_awake"])
            loaded = load_prefs(p)
            self.assertEqual(loaded, saved)
        norm = normalize_prefs({"language": "invalid"})
        self.assertEqual(norm["language"], "auto")


if __name__ == "__main__":
    unittest.main()
