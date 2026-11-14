#!/usr/bin/env python3
"""Live Japanese translator pane for Antigravity (`agy`) thinking and cli.log."""

from __future__ import annotations

import argparse
import codecs
import hashlib
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

UUID_RE_STR = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
ROOT_CONV_PATTERNS = [
    re.compile(rf"(?:Created|Resuming) conversation ({UUID_RE_STR})"),
    re.compile(rf"Starting conversation update stream for ({UUID_RE_STR})"),
    re.compile(rf"Sending user message to conversation ({UUID_RE_STR})"),
]
SUBAGENT_SPAWN_RE = re.compile(
    rf"(?:conversationId|conversation_id|Conversation ID)[\"':=\s]+({UUID_RE_STR})",
    re.IGNORECASE,
)
LOG_TIME_RE = re.compile(r"^[IWEF]\d{4} (\d{2}:\d{2}:\d{2})\.\d+\s+\d+\s+[^\]]+\]\s*(.*)$")
MONITOR_RE = re.compile(
    r'^Monitor\s+(\S+)\s+FINISHED:\s+triggered=(true|false),\s+reason="((?:\\.|[^"\\])*)",\s+duration=(\S+)'
)

QUICK_REASON_GLOSSARY = {
    "unknown_command": "未登録コマンド (unknown_command)",
    "allowed_tool": "許可済みツール (allowed_tool)",
    "denied_tool": "拒否されたツール (denied_tool)",
    "user_rejected": "ユーザー拒否 (user_rejected)",
}

# ANSI styles (suppressed automatically when stdout is not a TTY unless --color=always).
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
YELLOW = "\033[33m"
RED = "\033[31m"


@dataclass
class ConversationMeta:
    conv_id: str
    parent_id: str = ""
    agent_name: str = ""
    title: str = ""


@dataclass
class FileCursor:
    path: Path | None = None
    inode: tuple[int, int] | None = None
    offset: int = 0
    partial: bytes = b""


@dataclass
class TranscriptState:
    cursor: FileCursor = field(default_factory=FileCursor)
    seen_hashes: set[tuple[int, str]] = field(default_factory=set)
    seen_subagent_calls: deque[str] = field(default_factory=deque)


class Translator:
    def __init__(
        self,
        plamo_bin: str,
        form: str = "plain",
        port: int | None = None,
        no_translate: bool = False,
        use_color: bool = True,
    ) -> None:
        self.plamo_bin = plamo_bin
        self.form = form
        self.port = port
        self.no_translate = no_translate
        self.use_color = use_color
        self.initialized = False
        self.cache: dict[str, str] = {}
        self.cache_order: deque[str] = deque(maxlen=512)

    def _base_cmd(self) -> list[str]:
        cmd = [self.plamo_bin]
        if self.port is not None:
            cmd.extend(["--port", str(self.port)])
        return cmd

    def ensure_ready(self) -> bool:
        if self.initialized or self.no_translate:
            return True
        try:
            # Fast status check; only print notice if daemon is currently cold.
            status = subprocess.run(
                [*self._base_cmd(), "status"],
                capture_output=True,
                text=True,
                timeout=3,
            )
            cold = "healthy: True" not in status.stdout
        except Exception:
            cold = True

        if cold:
            msg = "⏳ PLaMo 0.8B を起動中（初回はモデル確認/DLに数秒〜数十秒かかります）…"
            print(f"{DIM}{msg}{RESET}" if self.use_color else msg, flush=True)

        proc = subprocess.run(
            [*self._base_cmd(), "ensure"],
            text=True,
            timeout=1800,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"plamo-translate ensure failed (exit {proc.returncode})")
        self.initialized = True
        return True

    def stream_translate(self, text: str) -> None:
        key = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
        if key in self.cache:
            print(self.cache[key], flush=True)
            return

        if self.no_translate:
            print(text.strip(), flush=True)
            return

        try:
            self.ensure_ready()
            proc = subprocess.Popen(
                [
                    *self._base_cmd(),
                    "translate",
                    "--form",
                    self.form,
                    "--skip-ja",
                    "--quiet",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            assert proc.stdin is not None and proc.stdout is not None
            proc.stdin.write(text)
            proc.stdin.close()

            chunks: list[str] = []
            while True:
                line = proc.stdout.readline()
                if line == "" and proc.poll() is not None:
                    break
                if line:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    chunks.append(line)

            stderr = proc.stderr.read() if proc.stderr else ""
            rc = proc.wait(timeout=120)
            if rc != 0:
                raise RuntimeError(stderr.strip() or f"exit code {rc}")

            joined = "".join(chunks).rstrip("\n")
            if chunks and not chunks[-1].endswith("\n"):
                print("", flush=True)
            if joined:
                self.cache[key] = joined
                if len(self.cache) > 512 and self.cache_order:
                    old = self.cache_order.popleft()
                    self.cache.pop(old, None)
                self.cache_order.append(key)
        except Exception as exc:
            err_msg = f"[翻訳エラー: {exc}]"
            print(f"{RED}{err_msg}{RESET}" if self.use_color else err_msg, flush=True)
            print(text.strip(), flush=True)


def c(style: str, text: str, enabled: bool) -> str:
    return f"{style}{text}{RESET}" if enabled else text


def unescape_go_quoted(raw: str) -> str:
    try:
        return codecs.decode(raw, "unicode_escape")
    except Exception:
        return raw.replace(r"\"", '"').replace(r"\\", "\\")


def read_new_lines(cursor: FileCursor, target_path: Path, from_end_on_first: bool = False) -> list[str]:
    """Incrementally read complete UTF-8 lines, tracking symlink/inode switches."""
    try:
        resolved = target_path.resolve() if target_path.exists() else None
    except OSError:
        resolved = None

    if resolved is None or not resolved.is_file():
        return []

    try:
        st = resolved.stat()
    except OSError:
        return []

    inode = (st.st_dev, st.st_ino)
    if cursor.inode != inode or st.st_size < cursor.offset:
        first_open = cursor.path is None
        cursor.path = resolved
        cursor.inode = inode
        cursor.partial = b""
        cursor.offset = st.st_size if from_end_on_first and first_open else 0

    if st.st_size == cursor.offset:
        return []

    lines: list[str] = []
    with open(resolved, "rb") as fh:
        fh.seek(cursor.offset)
        data = cursor.partial + fh.read()
        cursor.offset = fh.tell()

    if not data:
        return []

    parts = data.split(b"\n")
    cursor.partial = parts.pop()
    for raw_line in parts:
        lines.append(raw_line.decode("utf-8", errors="replace").rstrip("\r"))
    return lines


def query_conversation_tree(db_path: Path) -> dict[str, ConversationMeta]:
    if not db_path.is_file():
        return {}
    metas: dict[str, ConversationMeta] = {}
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=0.2) as conn:
            cur = conn.cursor()
            for row in cur.execute(
                "SELECT conversation_id, parent_conversation_id, agent_name, title FROM conversation_summaries"
            ):
                cid, parent_id, agent_name, title = row
                metas[cid] = ConversationMeta(
                    conv_id=cid,
                    parent_id=parent_id or "",
                    agent_name=agent_name or "",
                    title=title or "",
                )
            for row in cur.execute("SELECT conversation_id, parent_id FROM conversation_parents"):
                cid, parent_id = row
                if cid in metas and not metas[cid].parent_id and parent_id:
                    metas[cid].parent_id = parent_id
                elif cid not in metas and parent_id:
                    metas[cid] = ConversationMeta(conv_id=cid, parent_id=parent_id)
    except sqlite3.Error:
        return {}
    return metas


def resolve_descendants(roots: set[str], metas: dict[str, ConversationMeta]) -> set[str]:
    if not roots:
        return set()
    children_map: dict[str, list[str]] = {}
    for cid, meta in metas.items():
        if meta.parent_id:
            children_map.setdefault(meta.parent_id, []).append(cid)

    result = set(roots)
    queue = deque(roots)
    while queue:
        cur = queue.popleft()
        for child in children_map.get(cur, ()):
            if child not in result:
                result.add(child)
                queue.append(child)
    return result


class AgyWatcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.use_color = sys.stdout.isatty() and not args.no_color
        self.translator = Translator(
            plamo_bin=args.plamo_bin,
            form=args.form,
            port=args.port,
            no_translate=args.no_translate,
            use_color=self.use_color,
        )
        self.brain_dir = Path(args.brain_dir).expanduser()
        self.db_path = Path(args.db).expanduser()
        self.log_path = Path(args.log_file).expanduser()
        self.log_cursor = FileCursor()
        self.transcript_states: dict[str, TranscriptState] = {}
        self.root_conv_ids: set[str] = set()
        self.discovered_subagents: dict[str, str] = {}  # conv_id -> label
        self.metas: dict[str, ConversationMeta] = {}
        self.last_db_check = 0.0
        self.started_at = time.time()
        self.initial_backlog_done: set[str] = set()
        self.saw_any_event = False
        self.initial_log_scanned = False

    def print_banner(self) -> None:
        header = "━━ PLaMo 0.8B 思考リアルタイム翻訳 ━━"
        sub = "mode: all sessions" if self.args.all_sessions else f"log: {self.log_path.name}"
        hint = " / F9・Ctrl+b t: 表示切替" if (self.args.done_file or os.environ.get("TMUX")) else ""
        print(c(BOLD + CYAN, header, self.use_color), flush=True)
        print(c(DIM, f"({sub} / history={self.args.history}{hint})", self.use_color), flush=True)
        print("", flush=True)

    def _emit_monitor(self, ts: str, name: str, triggered: str, reason: str, duration: str) -> None:
        is_trig = triggered == "true"
        if not is_trig and not self.args.all_monitors:
            if " " not in reason and len(reason) <= 32:
                return

        badge_style = BOLD + (RED if is_trig else YELLOW)
        mark = "!" if is_trig else "🛡"
        header = f"[{ts}] {mark} Monitor:{name} (triggered={triggered}, {duration})"
        print(c(badge_style, header, self.use_color), flush=True)

        if reason in QUICK_REASON_GLOSSARY:
            print(QUICK_REASON_GLOSSARY[reason], flush=True)
        elif " " not in reason and len(reason) <= 40:
            print(reason, flush=True)
        else:
            self.translator.stream_translate(reason)
        print("", flush=True)
        self.saw_any_event = True

    def _emit_thinking(self, conv_id: str, step_idx: int, created_at: str, model: str, thinking: str) -> None:
        ts = self._format_ts(created_at)
        meta = self.metas.get(conv_id)
        is_subagent = conv_id in self.discovered_subagents or (
            meta is not None and bool(meta.parent_id)
        )
        if conv_id in self.root_conv_ids or not is_subagent:
            role = "🧠 Main"
            style = BOLD + CYAN
        else:
            sub_name = (meta.agent_name if meta else "") or self.discovered_subagents.get(conv_id) or "subagent"
            role = f"🐝 Subagent:{sub_name} ({conv_id[:8]})"
            style = BOLD + MAGENTA

        model_tag = f" · {model}" if model else ""
        header = f"[{ts}] {role} · step {step_idx}{model_tag}"
        print(c(style, header, self.use_color), flush=True)
        self.translator.stream_translate(thinking)
        print("", flush=True)
        self.saw_any_event = True

    @staticmethod
    def _format_ts(created_at: str) -> str:
        # e.g. "2026-11-14T11:36:44Z" -> local "20:36:44"
        if not created_at:
            return time.strftime("%H:%M:%S")
        try:
            dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
            return dt.astimezone().strftime("%H:%M:%S")
        except Exception:
            return time.strftime("%H:%M:%S")

    def poll_cli_log(self) -> None:
        # On standalone startup pointing at default symlink cli.log, skip giant old backlog
        # EXCEPT scan existing lines for active conversation IDs and tail last --history monitors.
        first_scan = not self.initial_log_scanned
        lines = read_new_lines(self.log_cursor, self.log_path, from_end_on_first=False)
        if first_scan and self.log_cursor.inode is not None:
            self.initial_log_scanned = True

        pending_monitors: deque[tuple[str, str, str, str, str]] = deque(maxlen=max(0, self.args.history))
        for line in lines:
            for pat in ROOT_CONV_PATTERNS:
                m_conv = pat.search(line)
                if m_conv:
                    cid = m_conv.group(1)
                    if cid not in self.root_conv_ids:
                        self.root_conv_ids.add(cid)
                        if not (first_scan and self.args.standalone):
                            print(c(DIM, f"[{time.strftime('%H:%M:%S')}] 🔗 会話接続: {cid[:8]}", self.use_color), flush=True)

            m_log = LOG_TIME_RE.match(line)
            if not m_log:
                continue
            ts, body = m_log.group(1), m_log.group(2)
            m_mon = MONITOR_RE.match(body)
            if m_mon:
                mon_name, triggered, raw_reason, duration = m_mon.groups()
                reason = unescape_go_quoted(raw_reason)
                item = (ts, mon_name, triggered, reason, duration)
                if first_scan:
                    pending_monitors.append(item)
                else:
                    self._emit_monitor(*item)

        if first_scan:
            for item in pending_monitors:
                self._emit_monitor(*item)

    def refresh_targets(self) -> list[str]:
        now = time.monotonic()
        if now - self.last_db_check >= 0.9:
            self.metas = query_conversation_tree(self.db_path)
            self.last_db_check = now

        if self.args.all_sessions:
            # Watch any brain conversation updated recently (after watcher start - 10s, plus top history).
            targets: list[tuple[float, str]] = []
            if self.brain_dir.is_dir():
                for tf in self.brain_dir.glob("*/.system_generated/logs/transcript_full.jsonl"):
                    cid = tf.parts[-4]
                    try:
                        mtime = tf.stat().st_mtime
                    except OSError:
                        continue
                    if mtime >= self.started_at - 15.0 or cid in self.root_conv_ids:
                        targets.append((mtime, cid))
            targets.sort()
            ordered = [cid for _, cid in targets]
            for cid in self.root_conv_ids:
                if cid not in ordered:
                    ordered.append(cid)
            return ordered

        if not self.root_conv_ids:
            return []

        tracked = resolve_descendants(self.root_conv_ids, self.metas)
        tracked.update(self.discovered_subagents.keys())
        return sorted(tracked)

    def _transcript_file_for(self, conv_id: str) -> Path | None:
        base = self.brain_dir / conv_id / ".system_generated" / "logs"
        full = base / "transcript_full.jsonl"
        if full.is_file():
            return full
        compact = base / "transcript.jsonl"
        if compact.is_file():
            return compact
        return None

    def _scan_subagent_refs(self, obj: dict, state: TranscriptState) -> None:
        t = obj.get("type")
        if t == "PLANNER_RESPONSE":
            for tc in obj.get("tool_calls") or []:
                if isinstance(tc, dict) and tc.get("name") == "invoke_subagent":
                    args = tc.get("args") or {}
                    role = args.get("Role") or args.get("TypeName") or "subagent"
                    state.seen_subagent_calls.append(str(role))
        elif t in ("GENERIC", "SYSTEM_MESSAGE"):
            content = obj.get("content") or ""
            if isinstance(content, str) and (
                "conversationId" in content or "conversation_id" in content or "Conversation ID" in content
            ):
                for m in SUBAGENT_SPAWN_RE.finditer(content):
                    cid = m.group(1)
                    if cid not in self.root_conv_ids and cid not in self.discovered_subagents:
                        label = state.seen_subagent_calls.popleft() if state.seen_subagent_calls else "subagent"
                        self.discovered_subagents[cid] = label

    @staticmethod
    def _created_epoch(created_at: str) -> float | None:
        if not created_at:
            return None
        try:
            return datetime.fromisoformat(created_at.replace("Z", "+00:00")).timestamp()
        except Exception:
            return None

    def poll_conversation(self, conv_id: str) -> None:
        tf = self._transcript_file_for(conv_id)
        if tf is None:
            return

        state = self.transcript_states.setdefault(conv_id, TranscriptState())
        first_attach = conv_id not in self.initial_backlog_done
        lines = read_new_lines(state.cursor, tf, from_end_on_first=False)
        if first_attach and state.cursor.inode is not None:
            self.initial_backlog_done.add(conv_id)

        backlog: deque[tuple[int, str, str, str]] = deque(maxlen=max(0, self.args.history))
        live_items: list[tuple[int, str, str, str]] = []
        for raw in lines:
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            self._scan_subagent_refs(obj, state)
            if obj.get("type") != "PLANNER_RESPONSE":
                continue
            thinking = obj.get("thinking")
            if not isinstance(thinking, str) or not thinking.strip():
                continue
            step_idx = int(obj.get("step_index", -1))
            t_hash = hashlib.sha256(thinking.encode("utf-8", errors="replace")).hexdigest()
            key = (step_idx, t_hash)
            if key in state.seen_hashes:
                continue
            state.seen_hashes.add(key)
            created_at = str(obj.get("created_at") or "")
            model = str(obj.get("model") or "")
            epoch = self._created_epoch(created_at)
            # Only cap history for steps written before watcher started; never drop live/subagent steps.
            if first_attach and (epoch is None or epoch < self.started_at - 3.0):
                backlog.append((step_idx, created_at, model, thinking))
            else:
                live_items.append((step_idx, created_at, model, thinking))

        for step_idx, created_at, model, thinking in (*backlog, *live_items):
            self._emit_thinking(conv_id, step_idx, created_at, model, thinking)

    def should_exit(self) -> bool:
        if self.args.done_file and Path(self.args.done_file).exists():
            return True
        if self.args.parent_pid:
            try:
                os.kill(self.args.parent_pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                pass
        return False

    def run(self) -> int:
        self.print_banner()
        stop = False

        def handle_sig(_signum: int, _frame: object) -> None:
            nonlocal stop
            stop = True

        signal.signal(signal.SIGTERM, handle_sig)
        signal.signal(signal.SIGINT, handle_sig)

        waiting_printed = False
        while not stop:
            self.poll_cli_log()
            polled_this_tick: set[str] = set()
            for _ in range(5):
                targets = [cid for cid in self.refresh_targets() if cid not in polled_this_tick]
                if not targets:
                    break
                for cid in targets:
                    polled_this_tick.add(cid)
                    self.poll_conversation(cid)

            if self.args.once:
                break
            if self.should_exit():
                break

            if not self.saw_any_event and not waiting_printed and not self.args.once:
                wait_msg = "待機中… エージェントの thinking / monitor 出力で自動翻訳が始まります（非使用時 RAM 0）"
                print(c(DIM, wait_msg, self.use_color), flush=True)
                waiting_printed = True

            time.sleep(0.25)

        return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="agy-translate-watch",
        description="Watch Antigravity transcripts + cli.log and translate thinking/monitors with PLaMo 0.8B",
    )
    p.add_argument(
        "--log-file",
        default=str(Path.home() / ".gemini" / "antigravity-cli" / "cli.log"),
        help="Path to agy log file (session log or default ~/.gemini/antigravity-cli/cli.log)",
    )
    p.add_argument(
        "--standalone",
        action="store_true",
        help="Treat initial existing log entries as history (auto-enabled when watching default cli.log)",
    )
    p.add_argument(
        "--all-sessions",
        action="store_true",
        help="Watch all active conversations in brain dir rather than only sessions from --log-file",
    )
    p.add_argument(
        "--all-monitors",
        action="store_true",
        help="Also display non-triggered single-word monitor events such as allowed_tool",
    )
    p.add_argument("--brain-dir", default=str(Path.home() / ".gemini" / "antigravity-cli" / "brain"))
    p.add_argument("--db", default=str(Path.home() / ".gemini" / "antigravity-cli" / "conversation_summaries.db"))
    p.add_argument("--plamo-bin", default=os.environ.get("PLAMO_TRANSLATE_BIN", "plamo-translate"))
    p.add_argument("--port", type=int, default=None)
    p.add_argument("--form", choices=("plain", "polite"), default="plain")
    p.add_argument("--history", type=int, default=2)
    p.add_argument("--parent-pid", type=int, default=None)
    p.add_argument("--done-file", default=None)
    p.add_argument("--no-translate", action="store_true")
    p.add_argument("--no-color", action="store_true")
    p.add_argument("--once", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    default_log = str(Path.home() / ".gemini" / "antigravity-cli" / "cli.log")
    if Path(args.log_file).expanduser() == Path(default_log):
        args.standalone = True
    watcher = AgyWatcher(args)
    return watcher.run()


if __name__ == "__main__":
    raise SystemExit(main())
