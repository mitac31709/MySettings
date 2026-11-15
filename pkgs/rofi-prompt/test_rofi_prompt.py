#!/usr/bin/env python3
"""Unit tests for rofi_prompt (Askpass, Assuan Pinentry, and cmd-polkit)."""

from __future__ import annotations

import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rofi_prompt  # noqa: E402


class HelperTests(unittest.TestCase):
    def test_assuan_roundtrip_utf8_and_whitespace(self) -> None:
        raw = "%E3%83%91%E3%82%B9 a+b%0A25%25 trailing "
        self.assertEqual(rofi_prompt.assuan_unescape(raw), "パス a+b\n25% trailing ")
        secret = "  lead+mid%tail \t\nline2  "
        self.assertEqual(rofi_prompt.assuan_unescape(rofi_prompt.assuan_escape(secret)), secret)

    def test_clean_prompt_label(self) -> None:
        self.assertEqual(rofi_prompt.clean_prompt_label("Passphrase:"), "Passphrase")
        self.assertEqual(rofi_prompt.clean_prompt_label("_PIN： "), "PIN")
        self.assertEqual(rofi_prompt.clean_prompt_label(": ", "Fallback"), "Fallback")

    def test_dispatch_mode(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(
                rofi_prompt.dispatch_mode("/nix/store/x/bin/rofi-askpass", ["askpass"]),
                ("askpass", ["askpass"]),
            )
            self.assertEqual(
                rofi_prompt.dispatch_mode("rofi_prompt.py", ["pinentry"]),
                ("pinentry", []),
            )
            self.assertEqual(
                rofi_prompt.dispatch_mode("rofi-polkit", []),
                ("polkit", []),
            )
            with self.assertRaises(SystemExit):
                rofi_prompt.dispatch_mode("rofi_prompt.py", [])
        with mock.patch.dict(os.environ, {"ROFI_PROMPT_MODE": "pinentry"}, clear=True):
            self.assertEqual(
                rofi_prompt.dispatch_mode("/nix/store/x/libexec/rofi_prompt.py", ["x"]),
                ("pinentry", ["x"]),
            )


class DisplayEnvTests(unittest.TestCase):
    def test_ignores_fake_display_and_probes_systemd(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            sock_path = Path(tmp) / "wayland-1"
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                srv.bind(str(sock_path))
                fake_sysd = {
                    "WAYLAND_DISPLAY": "wayland-1",
                    "XDG_RUNTIME_DIR": tmp,
                    "DISPLAY": "fake",
                }
                with mock.patch.object(
                    rofi_prompt, "probe_systemd_user_env", return_value=fake_sysd
                ):
                    env, gui = rofi_prompt.resolve_display_env(
                        {"DISPLAY": "fake", "XDG_RUNTIME_DIR": tmp},
                        has_controlling_tty=False,
                    )
            finally:
                srv.close()

            self.assertTrue(gui)
            self.assertEqual(env.get("WAYLAND_DISPLAY"), "wayland-1")
            self.assertNotIn("DISPLAY", env)

    def test_ssh_tty_does_not_probe_systemd_display(self) -> None:
        with mock.patch.object(rofi_prompt, "probe_systemd_user_env") as probe:
            env, gui = rofi_prompt.resolve_display_env(
                {"SSH_TTY": "/dev/pts/2"},
                has_controlling_tty=True,
            )
        probe.assert_not_called()
        self.assertFalse(gui)
        self.assertNotIn("WAYLAND_DISPLAY", env)

    def test_build_rofi_cmd_omits_wayland_flags_on_x11_only(self) -> None:
        cmd = rofi_prompt.build_rofi_cmd(
            {"DISPLAY": ":0"}, prompt="PIN", mesg="", error="bad"
        )
        self.assertNotIn("-wayland-layer", cmd)
        self.assertNotIn("-global-kb", cmd)
        self.assertIn("-theme-str", cmd)
        self.assertTrue(any("#e06c75" in arg for arg in cmd))

    def test_build_rofi_cmd_uses_top_layer_on_wayland(self) -> None:
        cmd = rofi_prompt.build_rofi_cmd(
            {"WAYLAND_DISPLAY": "wayland-1"}, prompt="PIN", mesg="hi", error=""
        )
        self.assertIn("-wayland-layer", cmd)
        self.assertEqual(cmd[cmd.index("-wayland-layer") + 1], "top")
        self.assertIn("-global-kb", cmd)


class PinentryTests(unittest.TestCase):
    def test_getpin_preserves_spaces_and_clears_error(self) -> None:
        session = rofi_prompt.PinentrySession()
        self.assertEqual(session.handle_line("SETTITLE Bitwarden"), (["OK"], True))
        self.assertEqual(session.handle_line("SETDESC Unlock%0Avault"), (["OK"], True))
        self.assertEqual(session.handle_line("SETPROMPT Master%20Password:"), (["OK"], True))
        self.assertEqual(session.handle_line("SETERROR Wrong%20pass"), (["OK"], True))

        with mock.patch.object(
            PinentrySessionModule := rofi_prompt.PinentrySession,
            "_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt,
            "run_rofi_password",
            side_effect=["  sp ace  ", "next"],
        ) as run_pw:
            replies, keep = session.handle_line("GETPIN")
            self.assertTrue(keep)
            self.assertEqual(replies, ["D   sp ace  ", "OK"])
            self.assertEqual(run_pw.call_args.kwargs["error"], "Wrong pass")
            self.assertEqual(run_pw.call_args.kwargs["message"], "Unlock\nvault")
            self.assertEqual(run_pw.call_args.kwargs["prompt"], "Master Password")

            replies2, _ = session.handle_line("GETPIN")
            self.assertEqual(replies2, ["D next", "OK"])
            self.assertEqual(run_pw.call_args.kwargs["error"], "")
        del PinentrySessionModule

    def test_getpin_cancel_and_repeat_retry(self) -> None:
        session = rofi_prompt.PinentrySession()
        session.handle_line("SETREPEAT Confirm:")
        session.handle_line("SETREPEATERROR Mismatch!")

        with mock.patch.object(
            rofi_prompt.PinentrySession,
            "_display_env",
            return_value=({"DISPLAY": ":0"}, True),
        ), mock.patch.object(
            rofi_prompt,
            "run_rofi_password",
            side_effect=["abc", "xyz", "same", "same"],
        ) as run_pw:
            replies, _ = session.handle_line("GETPIN")
            self.assertEqual(replies, ["S PIN_REPEATED", "D same", "OK"])
            self.assertEqual(run_pw.call_count, 4)
            # Third call (retry of first input) carries repeat_error.
            self.assertEqual(run_pw.call_args_list[2].kwargs["error"], "Mismatch!")

        with mock.patch.object(
            rofi_prompt.PinentrySession,
            "_display_env",
            return_value=({"DISPLAY": ":0"}, True),
        ), mock.patch.object(rofi_prompt, "run_rofi_password", return_value=None):
            replies, _ = session.handle_line("GETPIN")
            self.assertEqual(replies, [rofi_prompt.ASSUAN_CANCELED])

    def test_confirm_message_getinfo_and_reset(self) -> None:
        session = rofi_prompt.PinentrySession()
        session.handle_line("OPTION ttyname=/dev/pts/1")
        session.handle_line("SETOK _Yes")
        session.handle_line("SETCANCEL _No")
        session.handle_line("SETDESC Confirm action?")

        with mock.patch.object(
            rofi_prompt.PinentrySession,
            "_display_env",
            return_value=({"DISPLAY": ":0"}, True),
        ), mock.patch.object(rofi_prompt, "run_rofi_confirm", side_effect=[True, False]):
            self.assertEqual(session.handle_line("CONFIRM"), (["OK"], True))
            self.assertEqual(
                session.handle_line("CONFIRM --one-button"),
                ([rofi_prompt.ASSUAN_CANCELED], True),
            )

        self.assertEqual(session.handle_line("GETINFO flavor"), (["D rofi", "OK"], True))
        self.assertEqual(session.handle_line("GETINFO bogus"), ([rofi_prompt.ASSUAN_UNKNOWN_CMD], True))
        self.assertEqual(session.handle_line("RESET"), (["OK"], True))
        self.assertEqual(session.desc, "")
        self.assertEqual(session.options["ttyname"], "/dev/pts/1")

    def test_curses_fallback_replays_history_on_headless_tty(self) -> None:
        session = rofi_prompt.PinentrySession()
        session.handle_line("OPTION ttyname=/dev/pts/4")
        session.handle_line("SETDESC CLI unlock")

        fake_stdout = io.StringIO("OK Pleased to meet you\nOK\nOK\nD ttypin\nOK\nOK bye\n")
        fake_stdin = io.StringIO()
        fake_proc = mock.MagicMock()
        fake_proc.stdin = fake_stdin
        fake_proc.stdout = fake_stdout
        fake_proc.poll.return_value = None

        with mock.patch.object(
            rofi_prompt.PinentrySession,
            "_display_env",
            return_value=({}, False),
        ), mock.patch.object(subprocess, "Popen", return_value=fake_proc):
            replies, keep = session.handle_line("GETPIN")
            self.assertTrue(keep)
            self.assertEqual(replies, ["D ttypin", "OK"])
            replies_bye, keep_bye = session.handle_line("BYE")
            self.assertFalse(keep_bye)
            self.assertEqual(replies_bye, ["OK bye"])

        sent_lines = fake_stdin.getvalue().splitlines()
        self.assertEqual(
            sent_lines,
            ["OPTION ttyname=/dev/pts/4", "SETDESC CLI unlock", "GETPIN", "BYE"],
        )


class AskpassTests(unittest.TestCase):
    def test_password_mode_and_cancel(self) -> None:
        stdout = io.StringIO()
        with mock.patch.object(
            rofi_prompt,
            "resolve_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt, "run_rofi_password", return_value=" s3cr3t "
        ) as run_pw, mock.patch.object(sys, "stdout", stdout), mock.patch.dict(
            os.environ, {}, clear=True
        ):
            rc = rofi_prompt.cmd_askpass(["--title", "SSH パスワード", "user@host"])
        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue(), " s3cr3t \n")
        self.assertEqual(run_pw.call_args.kwargs["title"], "SSH パスワード")

        stdout_cancel = io.StringIO()
        with mock.patch.object(
            rofi_prompt,
            "resolve_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt, "run_rofi_password", return_value=None
        ), mock.patch.object(sys, "stdout", stdout_cancel):
            rc = rofi_prompt.cmd_askpass(["Enter passphrase:"])
        self.assertEqual(rc, 1)
        self.assertEqual(stdout_cancel.getvalue(), "")

    def test_ssh_askpass_confirm_mode(self) -> None:
        with mock.patch.object(
            rofi_prompt,
            "resolve_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt, "run_rofi_confirm", side_effect=[True, False]
        ), mock.patch.dict(os.environ, {"SSH_ASKPASS_PROMPT": "confirm"}):
            self.assertEqual(rofi_prompt.cmd_askpass(["Accept host key?"]), 0)
            self.assertEqual(rofi_prompt.cmd_askpass(["Accept host key?"]), 1)


class PolkitTests(unittest.TestCase):
    def test_retry_then_succeed_with_special_chars(self) -> None:
        req1 = json.dumps(
            {
                "action": "request password",
                "prompt": "Password:",
                "message": "Authentication is needed to run `/bin/sh`",
                "polkit action": {
                    "id": "org.freedesktop.policykit.exec",
                    "description": "Run privileged command",
                },
            }
        )
        fail_resp = json.dumps({"action": "authorization response", "authorized": False})
        req2 = json.dumps(
            {
                "action": "request password",
                "prompt": "Password:",
                "message": "Retry",
                "polkit action": None,
            }
        )
        ok_resp = json.dumps({"action": "authorization response", "authorized": True})

        stdin = io.StringIO(f"{req1}\n{fail_resp}\n{req2}\n{ok_resp}\n")
        stdout = io.StringIO()

        with mock.patch.object(
            rofi_prompt,
            "resolve_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt, "run_rofi_password", side_effect=["wrong", 'p"w\\d']
        ) as run_pw, mock.patch.object(sys, "stdin", stdin), mock.patch.object(
            sys, "stdout", stdout
        ):
            rc = rofi_prompt.cmd_polkit([])

        self.assertEqual(rc, 0)
        lines = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(
            lines,
            [
                {"action": "authenticate", "password": "wrong"},
                {"action": "authenticate", "password": 'p"w\\d'},
            ],
        )
        self.assertEqual(run_pw.call_args_list[0].kwargs["error"], "")
        self.assertIn("Authentication failed", run_pw.call_args_list[1].kwargs["error"])
        self.assertEqual(run_pw.call_args_list[1].kwargs["title"], "Authentication Required")

    def test_cancel_emits_cancel_json(self) -> None:
        req = json.dumps({"action": "request password", "prompt": "Password:", "message": "Auth"})
        stdin = io.StringIO(f"{req}\n")
        stdout = io.StringIO()
        with mock.patch.object(
            rofi_prompt,
            "resolve_display_env",
            return_value=({"WAYLAND_DISPLAY": "wayland-1"}, True),
        ), mock.patch.object(
            rofi_prompt, "run_rofi_password", return_value=None
        ), mock.patch.object(sys, "stdin", stdin), mock.patch.object(
            sys, "stdout", stdout
        ):
            rc = rofi_prompt.cmd_polkit([])

        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(stdout.getvalue()), {"action": "cancel"})


if __name__ == "__main__":
    unittest.main()
