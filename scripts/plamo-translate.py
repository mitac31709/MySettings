#!/usr/bin/env python3
"""On-demand PLaMo 3 Translate 0.8B server manager and translation CLI."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

MODEL_FILENAME = "plamo-3-translate-0.8b-Q4_K_M.gguf"
MODEL_URL = (
    "https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF/resolve/main/"
    + MODEL_FILENAME
)
MODEL_SIZE = 573126848
MODEL_SHA256 = "70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6"

DEFAULT_PORT = int(os.environ.get("PLAMO_TRANSLATE_PORT", "18921"))
DEFAULT_IDLE_SECONDS = int(os.environ.get("PLAMO_TRANSLATE_IDLE_SECONDS", "300"))
DEFAULT_CTX_SIZE = int(os.environ.get("PLAMO_TRANSLATE_CTX_SIZE", "4096"))
MODEL_ALIAS = "plamo-3-translate"

JA_CHAR_RE = re.compile(r"[\u3040-\u30ff\u4e00-\u9fff]")
ASCII_ALPHA_RE = re.compile(r"[A-Za-z]")
FENCED_CODE_RE = re.compile(r"(```[^\n]*\n[\s\S]*?```)")
TAG_ARTIFACT_RE = re.compile(r"<\|plamo:[^|>]*\|>")


def get_cache_dir() -> Path:
    base = Path(os.environ.get("PLAMO_TRANSLATE_CACHE_DIR", Path.home() / ".cache" / "plamo-translate"))
    base.mkdir(parents=True, exist_ok=True)
    return base


def detect_physical_cores() -> int:
    env_threads = os.environ.get("PLAMO_TRANSLATE_THREADS")
    if env_threads and env_threads.isdigit() and int(env_threads) > 0:
        return int(env_threads)
    try:
        pairs: set[tuple[str, str]] = set()
        cpu_root = Path("/sys/devices/system/cpu")
        for topo in cpu_root.glob("cpu[0-9]*/topology"):
            core_file = topo / "core_id"
            pkg_file = topo / "physical_package_id"
            if core_file.is_file() and pkg_file.is_file():
                pairs.add((pkg_file.read_text().strip(), core_file.read_text().strip()))
        if pairs:
            return max(2, min(8, len(pairs)))
    except OSError:
        pass
    return max(2, min(4, (os.cpu_count() or 4) // 2))


def find_llama_server() -> str:
    env_bin = os.environ.get("PLAMO_LLAMA_SERVER")
    if env_bin and os.access(env_bin, os.X_OK):
        return env_bin
    found = shutil.which("llama-server")
    if found:
        return found
    raise RuntimeError("llama-server binary not found on PATH (set PLAMO_LLAMA_SERVER)")


def touch_last_used(cache_dir: Path) -> None:
    path = cache_dir / "server.last_used"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(f"{time.time():.3f}\n", encoding="utf-8")
    os.replace(tmp, path)


def read_last_used(cache_dir: Path) -> float:
    path = cache_dir / "server.last_used"
    try:
        return float(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0.0


def server_url(port: int, endpoint: str) -> str:
    return f"http://127.0.0.1:{port}{endpoint}"


def is_server_healthy(port: int, timeout: float = 0.6) -> bool:
    try:
        req = urllib.request.Request(server_url(port, "/health"), method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
            return data.get("status") == "ok"
    except Exception:
        return False


def any_slot_processing(port: int) -> bool:
    try:
        req = urllib.request.Request(server_url(port, "/slots"), method="GET")
        with urllib.request.urlopen(req, timeout=0.8) as resp:
            if resp.status != 200:
                return False
            slots = json.loads(resp.read().decode("utf-8", errors="replace"))
            return any(bool(s.get("is_processing")) for s in slots if isinstance(s, dict))
    except Exception:
        return False


def download_model_if_missing(cache_dir: Path, quiet: bool = False) -> Path:
    model_path = cache_dir / MODEL_FILENAME
    if model_path.is_file() and model_path.stat().st_size == MODEL_SIZE:
        return model_path

    lock_path = cache_dir / "download.lock"
    with open(lock_path, "w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        if model_path.is_file() and model_path.stat().st_size == MODEL_SIZE:
            return model_path

        part_path = cache_dir / f"{MODEL_FILENAME}.part"
        if not quiet:
            print(
                f"Downloading {MODEL_FILENAME} (~547 MiB) to {model_path} ...",
                file=sys.stderr,
                flush=True,
            )

        sha = hashlib.sha256()
        downloaded = 0
        last_report = 0.0
        req = urllib.request.Request(
            MODEL_URL,
            headers={"User-Agent": "agy-plamo-translate/1.0"},
        )
        ssl_ctx = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE") or None)
        try:
            with urllib.request.urlopen(req, timeout=60, context=ssl_ctx) as resp, open(part_path, "wb") as out:
                total = int(resp.headers.get("Content-Length") or MODEL_SIZE)
                while True:
                    chunk = resp.read(1024 * 512)
                    if not chunk:
                        break
                    out.write(chunk)
                    sha.update(chunk)
                    downloaded += len(chunk)
                    now = time.monotonic()
                    if not quiet and (now - last_report >= 1.5 or downloaded >= total):
                        pct = (downloaded * 100.0 / total) if total > 0 else 0.0
                        mb = downloaded / (1024 * 1024)
                        total_mb = total / (1024 * 1024)
                        print(
                            f"\r  {mb:.1f} / {total_mb:.1f} MiB ({pct:.1f}%)",
                            end="",
                            file=sys.stderr,
                            flush=True,
                        )
                        last_report = now
            if not quiet:
                print("", file=sys.stderr, flush=True)
            digest = sha.hexdigest()
            if digest != MODEL_SHA256:
                raise RuntimeError(
                    f"SHA-256 mismatch for {MODEL_FILENAME}: expected {MODEL_SHA256}, got {digest}"
                )
            os.replace(part_path, model_path)
            return model_path
        except Exception:
            try:
                part_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise


def write_pid_file(cache_dir: Path, supervisor_pid: int, llama_pid: int, port: int) -> None:
    info = {
        "supervisor_pid": supervisor_pid,
        "llama_pid": llama_pid,
        "port": port,
        "started_at": time.time(),
    }
    path = cache_dir / "server.pid.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(info) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def read_pid_file(cache_dir: Path) -> dict | None:
    path = cache_dir / "server.pid.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def clear_pid_file(cache_dir: Path) -> None:
    try:
        (cache_dir / "server.pid.json").unlink(missing_ok=True)
    except OSError:
        pass


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def run_daemon(args: argparse.Namespace) -> int:
    cache_dir = get_cache_dir()
    model_path = download_model_if_missing(cache_dir, quiet=True)
    llama_bin = find_llama_server()
    threads = args.threads or detect_physical_cores()

    log_path = cache_dir / "llama-server.log"
    touch_last_used(cache_dir)

    cmd = [
        llama_bin,
        "-m",
        str(model_path),
        "-c",
        str(args.ctx_size),
        "-np",
        "1",
        "-t",
        str(threads),
        "--host",
        "127.0.0.1",
        "--port",
        str(args.port),
        "--alias",
        MODEL_ALIAS,
        "--jinja",
        "--no-prefill-assistant",
    ]

    with open(log_path, "w", encoding="utf-8") as llama_log:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=llama_log,
            stderr=subprocess.STDOUT,
            start_new_session=False,
        )

    write_pid_file(cache_dir, os.getpid(), proc.pid, args.port)
    stop_requested = False

    def handle_sig(_signum: int, _frame: object) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    try:
        while not stop_requested:
            ret = proc.poll()
            if ret is not None:
                return ret

            if args.idle_timeout > 0:
                last_used = read_last_used(cache_dir)
                if last_used > 0 and (time.time() - last_used) >= args.idle_timeout:
                    if not any_slot_processing(args.port):
                        break
            time.sleep(2.0)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2.0)
        clear_pid_file(cache_dir)

    return 0


def ensure_server(port: int, idle_timeout: int, ctx_size: int, quiet: bool = False) -> None:
    cache_dir = get_cache_dir()
    if is_server_healthy(port):
        touch_last_used(cache_dir)
        return

    download_model_if_missing(cache_dir, quiet=quiet)

    lock_path = cache_dir / "server.lock"
    with open(lock_path, "w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        if is_server_healthy(port):
            touch_last_used(cache_dir)
            return

        # Clean up any half-dead previous daemon before starting a fresh one.
        old = read_pid_file(cache_dir)
        if old and not pid_alive(int(old.get("llama_pid", -1))):
            clear_pid_file(cache_dir)

        daemon_log = cache_dir / "daemon.log"
        touch_last_used(cache_dir)
        cmd = [
            sys.executable,
            os.path.abspath(__file__),
            "daemon",
            "--port",
            str(port),
            "--idle-timeout",
            str(idle_timeout),
            "--ctx-size",
            str(ctx_size),
        ]
        with open(daemon_log, "w", encoding="utf-8") as log_fh:
            daemon_proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )

        deadline = time.monotonic() + 60.0
        while time.monotonic() < deadline:
            if is_server_healthy(port):
                touch_last_used(cache_dir)
                return
            if daemon_proc.poll() is not None:
                tail = ""
                llama_log = cache_dir / "llama-server.log"
                if llama_log.is_file():
                    tail = "\n".join(llama_log.read_text(errors="replace").splitlines()[-15:])
                raise RuntimeError(
                    f"llama-server exited prematurely (code {daemon_proc.returncode}):\n{tail}"
                )
            time.sleep(0.25)

        raise TimeoutError(f"Timed out waiting for llama-server on 127.0.0.1:{port}")


def stop_server(port: int) -> int:
    cache_dir = get_cache_dir()
    info = read_pid_file(cache_dir)
    if not info:
        if not is_server_healthy(port):
            print("plamo-translate server is not running.")
            return 0
        print(
            f"Warning: server responds on port {port} without server.pid.json",
            file=sys.stderr,
        )
        return 1

    sup_pid = int(info.get("supervisor_pid", -1))
    llama_pid = int(info.get("llama_pid", -1))
    if pid_alive(sup_pid):
        os.kill(sup_pid, signal.SIGTERM)
    elif pid_alive(llama_pid):
        os.kill(llama_pid, signal.SIGTERM)

    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        if not pid_alive(sup_pid) and not pid_alive(llama_pid):
            clear_pid_file(cache_dir)
            print("Stopped plamo-translate server (RAM freed).")
            return 0
        time.sleep(0.15)

    for pid in (llama_pid, sup_pid):
        if pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    clear_pid_file(cache_dir)
    print("Killed plamo-translate server.")
    return 0


def read_rss_mib(pid: int) -> float | None:
    try:
        statm = Path(f"/proc/{pid}/statm").read_text(encoding="utf-8").split()
        pages = int(statm[1])
        return pages * os.sysconf("SC_PAGE_SIZE") / (1024 * 1024)
    except (OSError, IndexError, ValueError):
        return None


def status_server(port: int, idle_timeout: int) -> int:
    cache_dir = get_cache_dir()
    model_path = cache_dir / MODEL_FILENAME
    info = read_pid_file(cache_dir)
    healthy = is_server_healthy(port)
    print(f"model: {model_path} ({'present' if model_path.is_file() else 'not downloaded'})")
    print(f"port: 127.0.0.1:{port}")
    print(f"healthy: {healthy}")
    if info:
        sup_pid = int(info.get("supervisor_pid", -1))
        llama_pid = int(info.get("llama_pid", -1))
        rss = read_rss_mib(llama_pid)
        last_used = read_last_used(cache_dir)
        idle_for = max(0.0, time.time() - last_used) if last_used > 0 else 0.0
        print(f"supervisor_pid: {sup_pid} (alive={pid_alive(sup_pid)})")
        print(f"llama_pid: {llama_pid} (alive={pid_alive(llama_pid)}, rss={f'{rss:.1f} MiB' if rss else 'n/a'})")
        print(f"idle: {idle_for:.0f}s / {idle_timeout}s")
    else:
        print("daemon: stopped (0 MiB RAM)")
    return 0


def needs_translation_to_ja(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    ja_count = len(JA_CHAR_RE.findall(stripped))
    en_count = len(ASCII_ALPHA_RE.findall(stripped))
    if en_count == 0:
        return False
    if ja_count >= 5 and (ja_count / (ja_count + en_count)) >= 0.20:
        return False
    return True


def _split_oversized(segment: str, max_chars: int) -> list[str]:
    if len(segment) <= max_chars:
        return [segment]

    # Split on sentence boundaries first, then whitespace/hard wrap as last resort.
    sentences = re.split(r"(?<=[.!?])\s+", segment)
    out: list[str] = []
    cur = ""
    for sent in sentences:
        if len(sent) > max_chars:
            if cur:
                out.append(cur)
                cur = ""
            lines = sent.splitlines()
            for line in lines:
                if len(line) <= max_chars:
                    if cur and len(cur) + 1 + len(line) > max_chars:
                        out.append(cur)
                        cur = line
                    else:
                        cur = f"{cur}\n{line}" if cur else line
                else:
                    if cur:
                        out.append(cur)
                        cur = ""
                    for i in range(0, len(line), max_chars):
                        out.append(line[i : i + max_chars])
        elif cur and len(cur) + 1 + len(sent) > max_chars:
            out.append(cur)
            cur = sent
        else:
            cur = f"{cur} {sent}" if cur else sent
    if cur:
        out.append(cur)
    return out


def split_markdown_segments(text: str, max_chars: int = 1100) -> list[tuple[bool, str]]:
    """Return [(should_translate, segment_text), ...] preserving fenced code blocks."""
    segments: list[tuple[bool, str]] = []
    parts = FENCED_CODE_RE.split(text)
    for part in parts:
        if not part:
            continue
        if part.startswith("```") and part.endswith("```"):
            segments.append((False, part))
            continue

        paragraphs = re.split(r"(\n\s*\n)", part)
        cur = ""
        for p in paragraphs:
            if not p:
                continue
            if re.fullmatch(r"\n\s*\n", p):
                if cur:
                    cur += p
                elif segments and not segments[-1][0]:
                    segments[-1] = (False, segments[-1][1] + p)
                continue

            if len(p) > max_chars:
                if cur.strip():
                    segments.append((True, cur))
                    cur = ""
                subchunks = _split_oversized(p, max_chars)
                for idx, sub in enumerate(subchunks):
                    segments.append((True, sub))
                    if idx + 1 < len(subchunks):
                        segments.append((False, "\n"))
            elif cur and len(cur) + len(p) > max_chars:
                segments.append((True, cur))
                cur = p
            else:
                cur += p
        if cur.strip():
            segments.append((True, cur))
        elif cur:
            segments.append((False, cur))
    return segments


def translate_chunk(
    chunk: str,
    port: int,
    source_lang: str,
    target_lang: str,
    form: str,
    timeout: float = 90.0,
) -> str:
    leading_ws = chunk[: len(chunk) - len(chunk.lstrip("\n"))]
    trailing_ws = chunk[len(chunk.rstrip("\n")) :]
    body = chunk.strip("\n")
    if not body.strip():
        return chunk

    cache_dir = get_cache_dir()
    touch_last_used(cache_dir)

    payload = {
        "model": MODEL_ALIAS,
        "messages": [{"role": "user", "content": body}],
        "chat_template_kwargs": {
            "source_lang": source_lang,
            "target_lang": target_lang,
            "form": form,
        },
        "temperature": 0,
        "max_tokens": 1536,
        "stop": ["<|plamo:tag|>", "<|plamo:bos|>", "<|plamo:eos|>"],
    }
    req = urllib.request.Request(
        server_url(port, "/v1/chat/completions"),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))

    touch_last_used(cache_dir)
    translated = data["choices"][0]["message"]["content"]
    translated = TAG_ARTIFACT_RE.sub("", translated).strip("\n")
    return f"{leading_ws}{translated}{trailing_ws}"


def iter_translated_segments(
    text: str,
    port: int = DEFAULT_PORT,
    idle_timeout: int = DEFAULT_IDLE_SECONDS,
    ctx_size: int = DEFAULT_CTX_SIZE,
    source_lang: str = "en",
    target_lang: str = "ja",
    form: str = "plain",
    skip_ja: bool = False,
    quiet: bool = False,
):
    if skip_ja and target_lang == "ja" and not needs_translation_to_ja(text):
        yield text
        return

    ensure_server(port=port, idle_timeout=idle_timeout, ctx_size=ctx_size, quiet=quiet)

    for should_translate, seg in split_markdown_segments(text):
        if not should_translate:
            yield seg
            continue
        if skip_ja and target_lang == "ja" and not needs_translation_to_ja(seg):
            yield seg
            continue
        yield translate_chunk(
            seg,
            port=port,
            source_lang=source_lang,
            target_lang=target_lang,
            form=form,
        )


def translate_text(**kwargs) -> str:
    return "".join(iter_translated_segments(**kwargs))


def _common_server_args_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--port", type=int, default=argparse.SUPPRESS)
    p.add_argument("--idle-timeout", type=int, default=argparse.SUPPRESS)
    p.add_argument("--ctx-size", type=int, default=argparse.SUPPRESS)
    return p


def build_parser() -> argparse.ArgumentParser:
    common = _common_server_args_parser()
    parser = argparse.ArgumentParser(
        prog="plamo-translate",
        description="PLaMo 3 Translate 0.8B on-demand llama-server + CLI",
        parents=[common],
    )
    parser.set_defaults(
        port=DEFAULT_PORT,
        idle_timeout=DEFAULT_IDLE_SECONDS,
        ctx_size=DEFAULT_CTX_SIZE,
    )

    sub = parser.add_subparsers(dest="command")

    sub.add_parser("ensure", parents=[common], help="Download model if needed and start llama-server on demand")
    sub.add_parser("stop", parents=[common], help="Stop background llama-server immediately")
    sub.add_parser("status", parents=[common], help="Show model/server status and RAM usage")

    daemon_p = sub.add_parser("daemon", parents=[common], help="Internal foreground supervisor for llama-server")
    daemon_p.add_argument("--threads", type=int, default=None)

    tr_p = sub.add_parser("translate", parents=[common], help="Translate text (args or stdin)")
    tr_p.add_argument("--source", default="en")
    tr_p.add_argument("--target", default="ja")
    tr_p.add_argument("--form", choices=("plain", "polite"), default="plain")
    tr_p.add_argument("--skip-ja", action="store_true")
    tr_p.add_argument("-q", "--quiet", action="store_true")
    tr_p.add_argument("text", nargs="*")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    # Allow `plamo-translate "hello"` shorthand when first arg is not a subcommand.
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    known_cmds = {"ensure", "stop", "status", "daemon", "translate", "-h", "--help"}
    if raw_argv and not any(tok in known_cmds for tok in raw_argv):
        if any(tok in ("-h", "--help") for tok in raw_argv):
            parser.print_help()
            return 0
        raw_argv = ["translate", *raw_argv]
    elif not raw_argv and not sys.stdin.isatty():
        raw_argv = ["translate"]
    elif not raw_argv:
        parser.print_help()
        return 0

    args = parser.parse_args(raw_argv)

    if args.command == "daemon":
        return run_daemon(args)
    if args.command == "ensure":
        ensure_server(port=args.port, idle_timeout=args.idle_timeout, ctx_size=args.ctx_size)
        return 0
    if args.command == "stop":
        return stop_server(args.port)
    if args.command == "status":
        return status_server(args.port, args.idle_timeout)
    if args.command == "translate":
        text = " ".join(args.text) if args.text else sys.stdin.read()
        if not text.strip():
            return 0
        last_chunk = ""
        for chunk in iter_translated_segments(
            text=text,
            port=args.port,
            idle_timeout=args.idle_timeout,
            ctx_size=args.ctx_size,
            source_lang=args.source,
            target_lang=args.target,
            form=args.form,
            skip_ja=args.skip_ja,
            quiet=args.quiet,
        ):
            sys.stdout.write(chunk)
            sys.stdout.flush()
            last_chunk = chunk
        if not last_chunk.endswith("\n"):
            sys.stdout.write("\n")
            sys.stdout.flush()
        return 0

    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
