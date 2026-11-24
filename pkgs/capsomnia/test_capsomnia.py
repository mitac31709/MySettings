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

    def test_lid_open_lock_tracker_needs_lock_check_only_on_open_edge(self) -> None:
        tr = LidOpenLockTracker()
        self.assertFalse(tr.needs_lock_check(eligible=True, clamshell_closed=False))
        tr.update(eligible=True, clamshell_closed=False, is_locked=None, now=1.0)
        self.assertFalse(tr.needs_lock_check(eligible=True, clamshell_closed=True))
        tr.update(eligible=True, clamshell_closed=True, is_locked=None, now=2.0)
        self.assertFalse(tr.needs_lock_check(eligible=True, clamshell_closed=True))
        self.assertFalse(tr.needs_lock_check(eligible=False, clamshell_closed=False))
        self.assertFalse(tr.needs_lock_check(eligible=True, clamshell_closed=None))
        self.assertTrue(tr.needs_lock_check(eligible=True, clamshell_closed=False))

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

    def test_hyprctl_argv_and_shortcut_normalization(self) -> None:
        from capsomniad import build_hyprctl_argv, normalize_hyprland_shortcut

        self.assertEqual(
            build_hyprctl_argv("sig123", "-j", "monitors", "all"),
            ["hyprctl", "-i", "sig123", "-j", "monitors", "all"],
        )
        self.assertEqual(
            build_hyprctl_argv("sig123", "eval", 'hl.unbind("SUPER + ALT + C")'),
            ["hyprctl", "-i", "sig123", "eval", 'hl.unbind("SUPER + ALT + C")'],
        )
        self.assertEqual(normalize_hyprland_shortcut("Mod4+Mod1+c"), "SUPER + ALT + C")
        self.assertEqual(normalize_hyprland_shortcut("SUPER + ALT + C"), "SUPER + ALT + C")
        self.assertEqual(normalize_hyprland_shortcut("Ctrl+Shift+F9"), "CTRL + SHIFT + F9")
        self.assertEqual(normalize_hyprland_shortcut("  "), "")

    def test_inhibitor_steal_fds_and_release_closes_fd(self) -> None:
        import os
        from unittest.mock import MagicMock
        from capsomniad import CapsomniaDaemon

        r_fd, w_fd = os.pipe()
        try:
            fake_fd_list = MagicMock()
            fake_fd_list.steal_fds.return_value = [w_fd]
            fake_res = MagicMock()
            fake_res.unpack.return_value = (0,)
            fake_bus = MagicMock()
            fake_bus.call_with_unix_fd_list_sync.return_value = (fake_res, fake_fd_list)

            daemon = CapsomniaDaemon.__new__(CapsomniaDaemon)
            daemon.bus = fake_bus
            daemon.inhibit_fd = None
            daemon.last_error_msg = None

            self.assertTrue(daemon.acquire_inhibitor())
            self.assertEqual(daemon.inhibit_fd, w_fd)
            fake_fd_list.steal_fds.assert_called_once_with()

            self.assertTrue(daemon.release_inhibitor())
            self.assertIsNone(daemon.inhibit_fd)
            # Writing end was closed; reading from r_fd must immediately hit EOF.
            self.assertEqual(os.read(r_fd, 1), b"")
        finally:
            os.close(r_fd)

    def test_sleep_request_skips_when_logind_already_preparing(self) -> None:
        from unittest.mock import MagicMock, patch
        from gi.repository import GLib
        from capsomniad import CapsomniaDaemon

        daemon = CapsomniaDaemon.__new__(CapsomniaDaemon)
        fake_bus = MagicMock()
        fake_bus.call_sync.return_value = GLib.Variant("(v)", (GLib.Variant("b", True),))
        daemon.bus = fake_bus
        daemon.helper_call = MagicMock(return_value={"ok": True})

        with patch("capsomniad.read_lid_closed", return_value=True):
            self.assertTrue(daemon.request_system_sleep_if_closed())
        daemon.helper_call.assert_not_called()

        fake_bus.call_sync.return_value = GLib.Variant("(v)", (GLib.Variant("b", False),))
        with patch("capsomniad.read_lid_closed", return_value=True):
            self.assertTrue(daemon.request_system_sleep_if_closed())
        daemon.helper_call.assert_called_once_with({"cmd": "suspend"}, timeout=5.0)

    def test_notify_waybar_skips_subprocess_when_waybar_absent(self) -> None:
        from unittest.mock import patch
        from capsomniad import notify_waybar

        with patch("capsomniad.is_waybar_running", return_value=False), patch(
            "capsomniad.subprocess.run"
        ) as mock_run:
            notify_waybar()
        mock_run.assert_not_called()

    def test_sync_keep_display_marker_tracks_awake_on(self) -> None:
        from capsomniad import CapsomniaDaemon

        with tempfile.TemporaryDirectory() as tmp:
            daemon = CapsomniaDaemon.__new__(CapsomniaDaemon)
            daemon.rt_dir = Path(tmp)
            daemon.keep_display_marker = Path(tmp) / "keep-display-awake"
            daemon.prefs = {"keep_display_awake": False}

            daemon.awake_on = True
            daemon.sync_keep_display_marker()
            self.assertTrue(daemon.keep_display_marker.exists())

            daemon.awake_on = False
            daemon.sync_keep_display_marker()
            self.assertFalse(daemon.keep_display_marker.exists())

    def test_dpms_lua_uses_hyprland_table_syntax(self) -> None:
        from unittest.mock import patch
        from capsomniad import build_dpms_lua, set_output_dpms

        self.assertEqual(
            build_dpms_lua("eDP-1", "off"),
            'hl.dsp.dpms({ action = "off", monitor = "eDP-1" })',
        )
        with patch("capsomniad.run_hyprctl", return_value=(True, "dpms: expected at most 1 argument, got 2")):
            ok, _ = set_output_dpms("eDP-1", "off")
            self.assertFalse(ok)
        with patch("capsomniad.run_hyprctl", return_value=(True, "ok")):
            ok, out = set_output_dpms("eDP-1", "off")
            self.assertTrue(ok)
            self.assertEqual(out, "ok")

    def test_sync_display_for_lid_backs_off_after_dpms_failure(self) -> None:
        from unittest.mock import patch
        from capsomniad import CapsomniaDaemon

        with tempfile.TemporaryDirectory() as tmp:
            daemon = CapsomniaDaemon.__new__(CapsomniaDaemon)
            daemon.rt_dir = Path(tmp)
            daemon.keep_display_marker = Path(tmp) / "keep-display-awake"
            daemon.state_dir = Path(tmp) / "state"
            daemon.brightness_backup_path = daemon.state_dir / "brightness.json"
            daemon.dimmed_device = None
            daemon.awake_on = True
            daemon.did_power_off_builtin_display = False
            daemon.next_dpms_retry_at = 0.0
            daemon.prefs = {"keep_display_awake": False}

            with patch("capsomniad.get_builtin_output_name", return_value="eDP-1"), patch(
                "capsomniad.set_output_dpms", return_value=(False, "err")
            ) as mock_dpms:
                daemon.sync_display_for_lid(True, now=100.0)
                daemon.sync_display_for_lid(True, now=100.25)
                daemon.sync_display_for_lid(True, now=104.9)
                self.assertEqual(mock_dpms.call_count, 1)

                daemon.sync_display_for_lid(True, now=105.0)
                self.assertEqual(mock_dpms.call_count, 2)

                daemon.sync_display_for_lid(False, now=105.5)
                daemon.sync_display_for_lid(True, now=105.6)
                self.assertEqual(mock_dpms.call_count, 3)

    def test_sync_keep_display_marker_is_idempotent(self) -> None:
        import os
        from capsomniad import CapsomniaDaemon

        with tempfile.TemporaryDirectory() as tmp:
            daemon = CapsomniaDaemon.__new__(CapsomniaDaemon)
            daemon.rt_dir = Path(tmp)
            daemon.keep_display_marker = Path(tmp) / "keep-display-awake"
            daemon.awake_on = True

            daemon.sync_keep_display_marker()
            os.utime(daemon.keep_display_marker, (1_000_000_000, 1_000_000_000))
            before_ns = daemon.keep_display_marker.stat().st_mtime_ns
            daemon.sync_keep_display_marker()
            after_ns = daemon.keep_display_marker.stat().st_mtime_ns
            self.assertEqual(before_ns, after_ns)


class CapsomniaHelperTests(unittest.TestCase):
    class _FakeDev:
        def __init__(self) -> None:
            self.writes: list[tuple[int, int, int]] = []

        def write(self, etype: int, code: int, value: int) -> None:
            self.writes.append((etype, code, value))

    @staticmethod
    def _make_led_dir(root: Path, name: str, device_name: str, brightness: int, trigger: str) -> Path:
        led = root / name
        (led / "device").mkdir(parents=True)
        (led / "device" / "name").write_text(f"{device_name}\n", encoding="utf-8")
        (led / "brightness").write_text(f"{brightness}\n", encoding="utf-8")
        (led / "trigger").write_text(f"none [{trigger}] kbd-scrolllock\n", encoding="utf-8")
        return led

    def test_write_keyd_led_emits_syn_report(self) -> None:
        from evdev import ecodes
        from capsomnia_helperd import write_keyd_led

        dev = self._FakeDev()
        write_keyd_led(dev, True, force_pulse=False)
        self.assertEqual(
            dev.writes,
            [
                (ecodes.EV_LED, ecodes.LED_CAPSL, 1),
                (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
            ],
        )

        dev.writes.clear()
        write_keyd_led(dev, True, force_pulse=True)
        self.assertEqual(
            dev.writes,
            [
                (ecodes.EV_LED, ecodes.LED_CAPSL, 0),
                (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                (ecodes.EV_LED, ecodes.LED_CAPSL, 1),
                (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
            ],
        )

    def test_apply_led_state_drives_keyd_and_pulses_on_phys_desync(self) -> None:
        from evdev import ecodes
        from capsomnia_helperd import KEYD_NAME, apply_led_state

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phys = self._make_led_dir(root, "input0::capslock", "AT Translated Set 2 keyboard", 0, "kbd-capslock")
            virt = self._make_led_dir(root, "input23::capslock", KEYD_NAME, 0, "kbd-capslock")
            dev = self._FakeDev()

            # Normal transition 0 -> 1: write EV_LED(1) + SYN_REPORT without pulse; do not touch virt sysfs brightness.
            res = apply_led_state(True, True, keyd_dev=dev, leds=[phys, virt])
            self.assertEqual(res["errors"], [])
            self.assertFalse(res["used_pulse"])
            self.assertEqual((phys / "trigger").read_text(encoding="utf-8"), "none")
            self.assertEqual((virt / "trigger").read_text(encoding="utf-8"), "none")
            self.assertEqual((virt / "brightness").read_text(encoding="utf-8").strip(), "0")
            self.assertEqual(
                dev.writes,
                [
                    (ecodes.EV_LED, ecodes.LED_CAPSL, 1),
                    (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                ],
            )

            # Virtual LED already 1 while physical LED is still 0: force a 0 -> 1 pulse.
            dev.writes.clear()
            (virt / "brightness").write_text("1\n", encoding="utf-8")
            (phys / "brightness").write_text("0\n", encoding="utf-8")
            (phys / "trigger").write_text("[none]\n", encoding="utf-8")
            (virt / "trigger").write_text("[none]\n", encoding="utf-8")
            res = apply_led_state(True, True, keyd_dev=dev, leds=[phys, virt])
            self.assertTrue(res["used_pulse"])
            self.assertEqual(
                dev.writes,
                [
                    (ecodes.EV_LED, ecodes.LED_CAPSL, 0),
                    (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                    (ecodes.EV_LED, ecodes.LED_CAPSL, 1),
                    (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                ],
            )

            # Both LEDs match desired state: no redundant keyd writes.
            dev.writes.clear()
            (phys / "brightness").write_text("1\n", encoding="utf-8")
            res = apply_led_state(True, True, keyd_dev=dev, leds=[phys, virt])
            self.assertFalse(res["used_pulse"])
            self.assertEqual(dev.writes, [])

            # Shutdown / non-dedicated restore: restore trigger and clear LED via keyd.
            res = apply_led_state(False, False, keyd_dev=dev, leds=[phys, virt])
            self.assertEqual((phys / "trigger").read_text(encoding="utf-8"), "kbd-capslock")
            self.assertEqual((virt / "trigger").read_text(encoding="utf-8"), "kbd-capslock")
            self.assertEqual(
                dev.writes,
                [
                    (ecodes.EV_LED, ecodes.LED_CAPSL, 0),
                    (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
                ],
            )

    def test_handle_keyd_event_triggers_and_reasserts_led(self) -> None:
        from types import SimpleNamespace
        from unittest.mock import MagicMock, patch
        from evdev import ecodes
        from capsomnia_helperd import HelperServer

        srv = HelperServer("/tmp/unused.sock", "wheel")
        dev = self._FakeDev()
        srv.keyd_dev = dev  # type: ignore[assignment]
        srv.dedicated = True
        srv.led_on = True
        srv.broadcast_event = MagicMock()  # type: ignore[method-assign]

        # KEY_MACRO and KEY_CAPSLOCK down both broadcast capslock_key_down in dedicated mode.
        srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_KEY, code=ecodes.KEY_MACRO, value=1), 10.0)
        srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_KEY, code=ecodes.KEY_CAPSLOCK, value=1), 10.1)
        self.assertEqual(srv.broadcast_event.call_count, 2)

        # Conflicting EV_LED(0) from compositor immediately reasserts EV_LED(1) + SYN_REPORT.
        srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_LED, code=ecodes.LED_CAPSL, value=0), 10.2)
        self.assertEqual(
            dev.writes,
            [
                (ecodes.EV_LED, ecodes.LED_CAPSL, 1),
                (ecodes.EV_SYN, ecodes.SYN_REPORT, 0),
            ],
        )

        # Matching EV_LED(1) does not reassert (no feedback loop).
        dev.writes.clear()
        srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_LED, code=ecodes.LED_CAPSL, value=1), 10.3)
        self.assertEqual(dev.writes, [])

        # Echo guard suppresses reassertion immediately after a forced pulse.
        srv.ignore_led_echo_until = 11.0
        srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_LED, code=ecodes.LED_CAPSL, value=0), 10.5)
        self.assertEqual(dev.writes, [])

        # Non-dedicated mode forwards KEY_MACRO once within guard window.
        srv.dedicated = False
        with patch("capsomnia_helperd.inject_capslock_toggle") as mock_toggle:
            srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_KEY, code=ecodes.KEY_MACRO, value=1), 20.0)
            srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_KEY, code=ecodes.KEY_MACRO, value=1), 20.1)
            srv.handle_keyd_event(SimpleNamespace(type=ecodes.EV_KEY, code=ecodes.KEY_MACRO, value=1), 20.5)
        self.assertEqual(mock_toggle.call_count, 2)


if __name__ == "__main__":
    unittest.main()
