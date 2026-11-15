#!/usr/bin/env python3
"""Unified Rofi password/confirmation prompt helper for Askpass, Pinentry, and Polkit."""

from __future__ import annotations

import argparse
import getpass
import html
import json
import os
import re
import signal
import stat
import subprocess
import sys
from dataclasses import dataclass, field

ACCENT_COLOR = "#33c5c5"
URGENT_COLOR = "#e06c75"
DIM_COLOR = "#6b7785"
POLKIT_CANCEL_LINE = '{"action": "cancel"}\n'
ASSUAN_CANCELED = "ERR 83886179 Operation cancelled <pinentry>"
ASSUAN_UNKNOWN_CMD = "ERR 275 Unknown IPC command"

HEX_ESCAPE_RE = re.compile(r"%([0-9A-Fa-f]{2})")
MNEMONIC_RE = re.compile(r"_(.)")


def default_theme_path() -> str:
    """Return path to the bundled password.rasi theme."""
    env_theme = os.environ.get("ROFI_PROMPT_THEME")
    if env_theme:
        return env_theme
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "password.rasi")


def assuan_unescape(value: str) -> str:
    """Decode Assuan percent-escaped UTF-8 strings (%0A, %25, multi-byte %XX)."""
    buf = bytearray()
    i = 0
    length = len(value)
    while i < length:
        if value[i] == "%" and i + 2 < length:
            hex_part = value[i + 1 : i + 3]
            if all(ch in "0123456789abcdefABCDEF" for ch in hex_part):
                buf.append(int(hex_part, 16))
                i += 3
                continue
        buf.extend(value[i].encode("utf-8", errors="surrogateescape"))
        i += 1
    return buf.decode("utf-8", errors="replace")


def assuan_escape(value: str) -> str:
    """Encode Assuan response data without trimming whitespace."""
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def strip_mnemonic(label: str) -> str:
    """Strip GTK/Assuan underscore mnemonic markers (e.g. _OK -> OK, __ -> _)."""
    return MNEMONIC_RE.sub(r"\1", label)


def clean_prompt_label(label: str, default: str = "Password") -> str:
    """Normalize a prompt label for Rofi's inputbar without trailing colons."""
    cleaned = strip_mnemonic(label).strip().rstrip(":：").strip()
    return cleaned or default


def probe_systemd_user_env() -> dict[str, str]:
    """Read environment variables exported into the systemd --user manager."""
    try:
        res = subprocess.run(
            ["systemctl", "--user", "show-environment"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if res.returncode != 0:
        return {}
    out: dict[str, str] = {}
    for line in res.stdout.splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            out[key] = val
    return out


def wayland_socket_reachable(env: dict[str, str]) -> bool:
    """Return True when WAYLAND_DISPLAY refers to an existing Wayland socket."""
    wayland_display = env.get("WAYLAND_DISPLAY", "")
    if not wayland_display:
        return False
    if os.path.isabs(wayland_display):
        sock_path = wayland_display
    else:
        runtime_dir = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        sock_path = os.path.join(runtime_dir, wayland_display)
    try:
        mode = os.stat(sock_path).st_mode
        return stat.S_ISSOCK(mode)
    except OSError:
        return False


def x11_display_reachable(env: dict[str, str]) -> bool:
    """Return True when DISPLAY names an active X11 display (ignoring ssh-agent 'fake')."""
    display = env.get("DISPLAY", "")
    if not display or display == "fake":
        return False
    if display.startswith(":"):
        num = display[1:].split(".", 1)[0]
        if num.isdigit():
            return os.path.exists(f"/tmp/.X11-unix/X{num}")
    return ":" in display


def has_graphical_display(env: dict[str, str]) -> bool:
    """Return True if a Wayland or X11 display appears reachable."""
    if wayland_socket_reachable(env):
        return True
    return x11_display_reachable(env)


def can_open_dev_tty() -> bool:
    """Return True if the process currently has a controlling /dev/tty."""
    try:
        with open("/dev/tty", "rb"):
            return True
    except OSError:
        return False


def resolve_display_env(
    base_env: dict[str, str] | None = None,
    *,
    extra_display: str | None = None,
    has_controlling_tty: bool | None = None,
) -> tuple[dict[str, str], bool]:
    """Resolve GUI environment variables, probing systemd --user only for non-TTY callers."""
    env = dict(os.environ if base_env is None else base_env)
    if env.get("DISPLAY") == "fake":
        env.pop("DISPLAY", None)
    if extra_display and extra_display != "fake" and not env.get("DISPLAY"):
        env["DISPLAY"] = extra_display

    if not env.get("XDG_RUNTIME_DIR"):
        default_runtime = f"/run/user/{os.getuid()}"
        if os.path.isdir(default_runtime):
            env["XDG_RUNTIME_DIR"] = default_runtime

    if has_graphical_display(env):
        return env, True

    if has_controlling_tty is None:
        has_controlling_tty = sys.stdin.isatty() or bool(
            env.get("SSH_TTY") or env.get("SSH_CONNECTION")
        )

    if has_controlling_tty:
        return env, False

    user_env = probe_systemd_user_env()
    for key in (
        "WAYLAND_DISPLAY",
        "DISPLAY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
        "XAUTHORITY",
    ):
        val = user_env.get(key)
        if key == "DISPLAY" and val == "fake":
            continue
        if not env.get(key) and val:
            env[key] = val

    return env, has_graphical_display(env)


def build_markup_message(
    *,
    title: str = "",
    message: str = "",
    error: str = "",
    detail: str = "",
) -> str:
    """Format Pango markup message lines safely for Rofi -mesg."""
    parts: list[str] = []
    if title.strip():
        parts.append(
            f'<span weight="bold" foreground="{ACCENT_COLOR}">'
            f"{html.escape(title.strip(), quote=False)}</span>"
        )
    if message.strip():
        parts.append(html.escape(message.strip(), quote=False))
    if detail.strip():
        parts.append(
            f'<span size="small" foreground="{DIM_COLOR}">'
            f"{html.escape(detail.strip(), quote=False)}</span>"
        )
    if error.strip():
        parts.append(
            f'<span weight="bold" foreground="{URGENT_COLOR}">'
            f"{html.escape(error.strip(), quote=False)}</span>"
        )
    return "\n".join(parts)


def build_rofi_cmd(
    env: dict[str, str],
    *,
    prompt: str,
    mesg: str,
    error: str = "",
    theme_path: str | None = None,
) -> list[str]:
    """Assemble base Rofi CLI arguments shared by password and confirm prompts."""
    rofi_bin = os.environ.get("ROFI_BIN", "rofi")
    resolved_theme = theme_path or default_theme_path()
    cmd = [
        rofi_bin,
        "-dmenu",
        "-no-show-icons",
        "-i",
        "-theme",
        resolved_theme,
        "-p",
        prompt,
    ]
    if env.get("WAYLAND_DISPLAY"):
        # top: Meltype/Fcitx5 candidates stay above the prompt (overlay hid them).
        cmd.extend(["-wayland-layer", "top", "-global-kb"])
    if mesg:
        cmd.extend(["-markup", "-mesg", mesg])
    else:
        cmd.extend(["-theme-str", "message { enabled: false; }"])
    if error.strip():
        cmd.extend(
            [
                "-theme-str",
                f"window {{ border-color: {URGENT_COLOR}; }} "
                f"inputbar {{ border-color: {URGENT_COLOR}; }}",
            ]
        )
    return cmd


def run_rofi_password(
    *,
    title: str = "",
    message: str = "",
    prompt: str = "Password",
    error: str = "",
    detail: str = "",
    env: dict[str, str] | None = None,
    theme_path: str | None = None,
) -> str | None:
    """Show a masked Rofi password prompt and return raw entered text or None on cancel."""
    run_env = os.environ if env is None else env
    mesg = build_markup_message(
        title=title, message=message, error=error, detail=detail
    )
    cmd = build_rofi_cmd(
        run_env,
        prompt=prompt or "Password",
        mesg=mesg,
        error=error,
        theme_path=theme_path,
    )
    cmd.append("-password")
    res = subprocess.run(
        cmd,
        input="",
        text=True,
        capture_output=True,
        env=run_env,
        check=False,
    )
    if res.returncode != 0:
        return None
    # Strip only the trailing newline appended by dmenu, preserving leading/trailing spaces.
    return res.stdout[:-1] if res.stdout.endswith("\n") else res.stdout


def run_rofi_confirm(
    *,
    title: str = "",
    message: str = "",
    ok_label: str = "OK",
    cancel_label: str = "Cancel",
    error: str = "",
    one_button: bool = False,
    env: dict[str, str] | None = None,
    theme_path: str | None = None,
) -> bool:
    """Show a Rofi confirmation / message dialog and return True if OK is selected."""
    run_env = os.environ if env is None else env
    mesg = build_markup_message(title=title, message=message, error=error)
    cmd = build_rofi_cmd(
        run_env,
        prompt="",
        mesg=mesg,
        error=error,
        theme_path=theme_path,
    )
    lines = 1 if one_button else 2
    cmd.extend(
        [
            "-no-custom",
            "-no-fixed-num-lines",
            "-format",
            "i",
            "-theme-str",
            f"inputbar {{ enabled: false; }} listview {{ enabled: true; lines: {lines}; }}",
        ]
    )
    ok_text = strip_mnemonic(ok_label) or "OK"
    cancel_text = strip_mnemonic(cancel_label) or "Cancel"
    choices = f"{ok_text}\n" if one_button else f"{ok_text}\n{cancel_text}\n"
    res = subprocess.run(
        cmd,
        input=choices,
        text=True,
        capture_output=True,
        env=run_env,
        check=False,
    )
    return res.returncode == 0 and res.stdout.strip() == "0"


def tty_getpass(prompt_text: str) -> str | None:
    """Read a password on the controlling terminal when no display is available."""
    try:
        with open("/dev/tty", "r+", encoding="utf-8", errors="replace") as tty:
            return getpass.getpass(f"{prompt_text}: ", stream=tty)
    except (OSError, EOFError, KeyboardInterrupt):
        if sys.stdin.isatty():
            try:
                return getpass.getpass(f"{prompt_text}: ")
            except (EOFError, KeyboardInterrupt):
                return None
        return None


def tty_confirm(prompt_text: str, *, one_button: bool = False) -> bool:
    """Read a confirmation answer from the controlling terminal."""
    suffix = " [Press Enter] " if one_button else " [y/N] "
    try:
        with open("/dev/tty", "r+", encoding="utf-8", errors="replace") as tty:
            tty.write(f"{prompt_text}{suffix}")
            tty.flush()
            answer = tty.readline()
    except OSError:
        return False
    if one_button:
        return True
    return answer.strip().lower() in {"y", "yes"}


def parse_askpass_args(argv: list[str]) -> argparse.Namespace:
    """Parse CLI arguments for rofi-askpass."""
    parser = argparse.ArgumentParser(
        prog="rofi-askpass",
        description="Unified Rofi password and confirmation prompt for askpass callers.",
    )
    parser.add_argument("--title", default="", help="Optional dialog title")
    parser.add_argument("--prompt", default="Password", help="Input prompt label")
    parser.add_argument(
        "--confirm",
        action="store_true",
        help="Show a Yes/No confirmation dialog instead of a password prompt",
    )
    parser.add_argument("message", nargs="*", help="Prompt message")
    return parser.parse_args(argv)


def cmd_askpass(argv: list[str]) -> int:
    """Run Askpass mode for SSH_ASKPASS, SUDO_ASKPASS, and wake-pc."""
    args = parse_askpass_args(argv)
    ssh_mode = os.environ.get("SSH_ASKPASS_PROMPT", "").lower()
    message = " ".join(args.message).strip()
    is_confirm = args.confirm or ssh_mode == "confirm"
    is_info = ssh_mode == "none"

    env, gui = resolve_display_env()

    if is_info:
        if gui:
            ok = run_rofi_confirm(
                title=args.title or "Notice",
                message=message or "Continue?",
                ok_label="OK",
                one_button=True,
                env=env,
            )
            return 0 if ok else 1
        return 0 if tty_confirm(message or "Notice", one_button=True) else 1

    if is_confirm:
        if gui:
            ok = run_rofi_confirm(
                title=args.title or "Confirm",
                message=message or "Are you sure?",
                ok_label="Yes",
                cancel_label="No",
                env=env,
            )
            return 0 if ok else 1
        return 0 if tty_confirm(message or "Confirm") else 1

    if gui:
        secret = run_rofi_password(
            title=args.title,
            message=message or "Enter password",
            prompt=clean_prompt_label(args.prompt, "Password"),
            env=env,
        )
    else:
        secret = tty_getpass(message or args.title or args.prompt or "Password")

    if secret is None:
        return 1
    sys.stdout.write(f"{secret}\n")
    sys.stdout.flush()
    return 0


@dataclass
class PinentrySession:
    """In-memory state for a single Assuan pinentry session."""

    desc: str = ""
    prompt: str = "PIN"
    title: str = ""
    error: str = ""
    ok_label: str = "OK"
    cancel_label: str = "Cancel"
    notok_label: str = ""
    repeat_prompt: str | None = None
    repeat_error: str = "Passphrases do not match"
    options: dict[str, str] = field(default_factory=dict)
    history: list[str] = field(default_factory=list)
    curses_proc: subprocess.Popen[str] | None = None

    def reset(self) -> None:
        """Reset dialog state while preserving connection-wide OPTION settings."""
        self.desc = ""
        self.prompt = "PIN"
        self.title = ""
        self.error = ""
        self.ok_label = "OK"
        self.cancel_label = "Cancel"
        self.notok_label = ""
        self.repeat_prompt = None
        self.repeat_error = "Passphrases do not match"

    def close_curses(self) -> None:
        """Terminate an active fallback pinentry-curses subprocess if running."""
        if self.curses_proc is None:
            return
        try:
            if self.curses_proc.stdin and not self.curses_proc.stdin.closed:
                self.curses_proc.stdin.write("BYE\n")
                self.curses_proc.stdin.flush()
            self.curses_proc.wait(timeout=2)
        except (OSError, subprocess.SubprocessError):
            self.curses_proc.kill()
        finally:
            self.curses_proc = None

    def _read_assuan_reply(self, stdout_pipe: object) -> list[str]:
        """Read Assuan response lines up to OK or ERR."""
        lines: list[str] = []
        while True:
            raw = stdout_pipe.readline()  # type: ignore[attr-defined]
            if not raw:
                break
            stripped = raw.rstrip("\r\n")
            lines.append(stripped)
            if stripped.startswith("OK") or stripped.startswith("ERR "):
                break
        return lines

    def _ensure_curses_proxy(self) -> bool:
        """Start pinentry-curses and replay accumulated OPTION/SET lines."""
        if self.curses_proc is not None and self.curses_proc.poll() is None:
            return True
        curses_bin = os.environ.get("PINENTRY_CURSES_BIN", "pinentry-curses")
        has_tty = bool(self.options.get("ttyname")) or can_open_dev_tty()
        if not has_tty:
            return False
        try:
            proc = subprocess.Popen(
                [curses_bin],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        except OSError:
            return False
        if proc.stdout is None or proc.stdin is None:
            proc.kill()
            return False
        greeting = proc.stdout.readline()
        if not greeting.startswith("OK"):
            proc.kill()
            return False
        for line in self.history:
            proc.stdin.write(f"{line}\n")
            proc.stdin.flush()
            self._read_assuan_reply(proc.stdout)
        self.curses_proc = proc
        return True

    def forward_to_curses(self, raw_line: str) -> list[str]:
        """Forward an Assuan command to pinentry-curses, returning response lines."""
        if not self._ensure_curses_proxy():
            return [ASSUAN_CANCELED]
        assert self.curses_proc is not None
        assert self.curses_proc.stdin is not None
        assert self.curses_proc.stdout is not None
        self.curses_proc.stdin.write(f"{raw_line}\n")
        self.curses_proc.stdin.flush()
        return self._read_assuan_reply(self.curses_proc.stdout)

    def _display_env(self) -> tuple[dict[str, str], bool]:
        """Resolve display environment for Pinentry."""
        return resolve_display_env(extra_display=self.options.get("display"))

    def _handle_getpin(self, raw_line: str) -> list[str]:
        """Prompt user for a PIN/passphrase and return Assuan response lines."""
        env, gui = self._display_env()
        if not gui:
            return self.forward_to_curses(raw_line)

        pending_error = self.error
        self.error = ""
        title = self.title or "Pinentry"
        message = self.desc
        prompt = clean_prompt_label(self.prompt, "PIN")

        while True:
            pin = run_rofi_password(
                title=title,
                message=message,
                prompt=prompt,
                error=pending_error,
                env=env,
            )
            pending_error = ""
            if pin is None:
                return [ASSUAN_CANCELED]

            if self.repeat_prompt is None:
                if pin == "":
                    return ["OK"]
                return [f"D {assuan_escape(pin)}", "OK"]

            repeat_pin = run_rofi_password(
                title=title,
                message=message,
                prompt=clean_prompt_label(self.repeat_prompt, "Repeat"),
                env=env,
            )
            if repeat_pin is None:
                return [ASSUAN_CANCELED]
            if pin == repeat_pin:
                if pin == "":
                    return ["S PIN_REPEATED", "OK"]
                return ["S PIN_REPEATED", f"D {assuan_escape(pin)}", "OK"]
            pending_error = self.repeat_error

    def _handle_confirm(self, raw_line: str, *, one_button: bool) -> list[str]:
        """Prompt user for Assuan CONFIRM / MESSAGE dialog."""
        env, gui = self._display_env()
        if not gui:
            return self.forward_to_curses(raw_line)

        pending_error = self.error
        self.error = ""
        ok = run_rofi_confirm(
            title=self.title or ("Notice" if one_button else "Confirm"),
            message=self.desc,
            ok_label=self.ok_label,
            cancel_label=self.cancel_label,
            error=pending_error,
            one_button=one_button,
            env=env,
        )
        if ok:
            return ["OK"]
        return [ASSUAN_CANCELED]

    def _handle_getinfo(self, arg: str) -> list[str]:
        """Handle Assuan GETINFO queries."""
        sub = arg.strip().lower()
        if sub == "pid":
            return [f"D {os.getpid()}", "OK"]
        if sub == "version":
            return ["D 1.0.0", "OK"]
        if sub == "flavor":
            return ["D rofi", "OK"]
        if sub == "ttyinfo":
            tty = self.options.get("ttyname", "-")
            ttytype = self.options.get("ttytype", "-")
            display = self.options.get("display", "-")
            return [f"D {tty} {ttytype} {display}", "OK"]
        return [ASSUAN_UNKNOWN_CMD]

    def _parse_option(self, arg: str) -> None:
        """Store Assuan OPTION key=value or boolean key."""
        text = arg.strip()
        if "=" in text:
            key, val = text.split("=", 1)
        elif " " in text:
            key, val = text.split(" ", 1)
        else:
            key, val = text, "1"
        self.options[key.strip().lower()] = assuan_unescape(val.strip())

    def handle_line(self, raw_line: str) -> tuple[list[str], bool]:
        """Process one Assuan command line and return (response_lines, keep_running)."""
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            return [], True

        if self.curses_proc is not None and self.curses_proc.poll() is None:
            replies = self.forward_to_curses(raw_line)
            if stripped.upper() == "BYE":
                return replies, False
            return replies, True

        cmd, _, rest = stripped.partition(" ")
        cmd_upper = cmd.upper()

        if cmd_upper == "NOP":
            return ["OK"], True
        if cmd_upper == "BYE":
            return ["OK closing connection"], False
        if cmd_upper == "RESET":
            self.reset()
            self.history.append("RESET")
            return ["OK"], True
        if cmd_upper == "GETINFO":
            return self._handle_getinfo(rest), True
        if cmd_upper == "OPTION":
            self._parse_option(rest)
            self.history.append(raw_line)
            return ["OK"], True

        simple_setters = {
            "SETDESC": "desc",
            "SETPROMPT": "prompt",
            "SETTITLE": "title",
            "SETERROR": "error",
            "SETOK": "ok_label",
            "SETCANCEL": "cancel_label",
            "SETNOTOK": "notok_label",
            "SETREPEATERROR": "repeat_error",
        }
        if cmd_upper in simple_setters:
            setattr(self, simple_setters[cmd_upper], assuan_unescape(rest))
            self.history.append(raw_line)
            return ["OK"], True

        if cmd_upper == "SETREPEAT":
            self.repeat_prompt = assuan_unescape(rest) if rest.strip() else "Repeat"
            self.history.append(raw_line)
            return ["OK"], True

        if cmd_upper in {"SETKEYINFO", "SETQUALITYBAR", "SETQUALITYBAR_TT", "SETTIMEOUT"}:
            self.history.append(raw_line)
            return ["OK"], True

        if cmd_upper == "GETPIN":
            return self._handle_getpin(raw_line), True
        if cmd_upper == "CONFIRM":
            one_btn = "--one-button" in rest.split()
            return self._handle_confirm(raw_line, one_button=one_btn), True
        if cmd_upper == "MESSAGE":
            return self._handle_confirm(raw_line, one_button=True), True

        return [ASSUAN_UNKNOWN_CMD], True


def write_lines(lines: list[str]) -> None:
    """Write protocol lines to stdout and flush immediately."""
    for line in lines:
        sys.stdout.write(f"{line}\n")
    sys.stdout.flush()


def cmd_pinentry(_argv: list[str]) -> int:
    """Run Assuan pinentry server loop for rbw and GnuPG."""
    session = PinentrySession()
    write_lines(["OK Pleased to meet you"])
    try:
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            replies, keep_running = session.handle_line(line)
            if replies:
                write_lines(replies)
            if not keep_running:
                break
    except BrokenPipeError:
        pass
    finally:
        session.close_curses()
    return 0


def format_polkit_prompt_fields(msg: dict[str, object]) -> tuple[str, str, str, str]:
    """Extract (title, message, detail, prompt) from a cmd-polkit request message."""
    polkit_action = msg.get("polkit action")
    action_info = polkit_action if isinstance(polkit_action, dict) else {}

    title = str(action_info.get("description") or "Authentication Required")
    raw_message = str(msg.get("message") or action_info.get("message") or "")
    action_id = str(action_info.get("id") or "")
    detail = f"Action: {action_id}" if action_id else ""
    prompt = clean_prompt_label(str(msg.get("prompt") or "Password"), "Password")
    return title, raw_message, detail, prompt


def cmd_polkit(_argv: list[str]) -> int:
    """Run cmd-polkit-agent stdin/stdout JSON helper using Rofi."""
    cancelled_sent = False

    def send_cancel() -> None:
        nonlocal cancelled_sent
        if cancelled_sent:
            return
        cancelled_sent = True
        try:
            sys.stdout.write(POLKIT_CANCEL_LINE)
            sys.stdout.flush()
        except BrokenPipeError:
            pass

    def handle_signal(_signum: int, _frame: object) -> None:
        send_cancel()
        raise SystemExit(0)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    last_error = ""
    try:
        for raw_line in sys.stdin:
            stripped = raw_line.strip()
            if not stripped:
                continue
            try:
                msg = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if not isinstance(msg, dict):
                continue

            action = msg.get("action")
            if action == "request password":
                env, gui = resolve_display_env()
                if not gui:
                    send_cancel()
                    return 1
                title, message, detail, prompt = format_polkit_prompt_fields(msg)
                password = run_rofi_password(
                    title=title,
                    message=message,
                    prompt=prompt,
                    error=last_error,
                    detail=detail,
                    env=env,
                )
                last_error = ""
                if password is None:
                    send_cancel()
                    return 0
                sys.stdout.write(
                    json.dumps({"action": "authenticate", "password": password}) + "\n"
                )
                sys.stdout.flush()
            elif action == "authorization response":
                if msg.get("authorized"):
                    return 0
                last_error = "Authentication failed. Try again."
    except BrokenPipeError:
        return 0
    return 0


def dispatch_mode(argv0: str, argv: list[str]) -> tuple[str, list[str]]:
    """Determine subcommand from ROFI_PROMPT_MODE, executable name, or first arg."""
    env_mode = os.environ.get("ROFI_PROMPT_MODE", "")
    if env_mode in {"askpass", "pinentry", "polkit"}:
        return env_mode, argv
    base = os.path.basename(argv0)
    mapping = {
        "rofi-askpass": "askpass",
        "rofi-pinentry": "pinentry",
        "rofi-polkit": "polkit",
    }
    if base in mapping:
        return mapping[base], argv
    if argv and argv[0] in {"askpass", "pinentry", "polkit"}:
        return argv[0], argv[1:]
    raise SystemExit(
        "Usage: rofi-prompt {askpass|pinentry|polkit} [args...] "
        "(or invoke via rofi-askpass / rofi-pinentry / rofi-polkit)"
    )


def main(argv: list[str] | None = None) -> int:
    """Entry point dispatching askpass, pinentry, and polkit handlers."""
    args = sys.argv[1:] if argv is None else argv
    mode, rest = dispatch_mode(sys.argv[0], args)
    if mode == "askpass":
        return cmd_askpass(rest)
    if mode == "pinentry":
        return cmd_pinentry(rest)
    return cmd_polkit(rest)


if __name__ == "__main__":
    raise SystemExit(main())
