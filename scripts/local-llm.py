#!/usr/bin/env python3
"""On-demand llama.cpp server manager and CLI for Qwen3.5-4B."""

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
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

MODEL_FILENAME = "Qwen3.5-4B-Q4_K_M.gguf"
MODEL_URL = (
    "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/" + MODEL_FILENAME
)
MODEL_SIZE = 2740937888
MODEL_SHA256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"

DEFAULT_PORT = int(os.environ.get("LOCAL_LLM_PORT", "18922"))
DEFAULT_IDLE_SECONDS = int(os.environ.get("LOCAL_LLM_IDLE_SECONDS", "600"))
DEFAULT_CTX_SIZE = int(os.environ.get("LOCAL_LLM_CTX_SIZE", "8192"))
DEFAULT_MODEL_ALIAS = os.environ.get("LOCAL_LLM_ALIAS", "qwen3.5:4b")
DEFAULT_REASONING = os.environ.get("LOCAL_LLM_REASONING", "off")


def get_cache_dir() -> Path:
    base = Path(
        os.environ.get("LOCAL_LLM_CACHE_DIR", Path.home() / ".cache" / "local-llm")
    )
    base.mkdir(parents=True, exist_ok=True)
    return base


def get_custom_model_path() -> Path | None:
    env_path = os.environ.get("LOCAL_LLM_MODEL_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser()
    return None


def detect_physical_cores() -> int:
    env_threads = os.environ.get("LOCAL_LLM_THREADS", "").strip()
    if env_threads.isdigit() and int(env_threads) > 0:
        return int(env_threads)
    try:
        pairs: set[tuple[str, str]] = set()
        cpu_root = Path("/sys/devices/system/cpu")
        for topo in cpu_root.glob("cpu[0-9]*/topology"):
            core_file = topo / "core_id"
            pkg_file = topo / "physical_package_id"
            if core_file.is_file() and pkg_file.is_file():
                pairs.add(
                    (
                        pkg_file.read_text(encoding="utf-8").strip(),
                        core_file.read_text(encoding="utf-8").strip(),
                    )
                )
        if pairs:
            return max(2, min(8, len(pairs)))
    except OSError:
        pass
    return max(2, min(4, (os.cpu_count() or 4) // 2))


def find_binary(env_key: str, cmd_name: str) -> str:
    env_bin = os.environ.get(env_key, "").strip()
    if env_bin and os.access(env_bin, os.X_OK):
        return env_bin
    found = shutil.which(cmd_name)
    if found:
        return found
    raise RuntimeError(f"{cmd_name} binary not found on PATH (set {env_key})")


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
            return any(
                bool(s.get("is_processing")) for s in slots if isinstance(s, dict)
            )
    except Exception:
        return False


def is_default_model_ready(cache_dir: Path) -> bool:
    model_path = cache_dir / MODEL_FILENAME
    aria2_ctrl = cache_dir / f"{MODEL_FILENAME}.aria2"
    if aria2_ctrl.exists():
        return False
    return model_path.is_file() and model_path.stat().st_size == MODEL_SIZE


def download_model_if_missing(cache_dir: Path, quiet: bool = False) -> Path:
    custom = get_custom_model_path()
    if custom is not None:
        if not custom.is_file():
            raise FileNotFoundError(f"LOCAL_LLM_MODEL_PATH not found: {custom}")
        return custom

    model_path = cache_dir / MODEL_FILENAME
    if is_default_model_ready(cache_dir):
        return model_path

    lock_path = cache_dir / "download.lock"
    with open(lock_path, "w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        if is_default_model_ready(cache_dir):
            return model_path

        part_path = cache_dir / f"{MODEL_FILENAME}.part"
        if not quiet:
            print(
                f"Downloading {MODEL_FILENAME} (~2.55 GiB) to {model_path} ...",
                file=sys.stderr,
                flush=True,
            )

        sha = hashlib.sha256()
        downloaded = 0
        last_report = 0.0
        req = urllib.request.Request(
            MODEL_URL,
            headers={"User-Agent": "nixos-local-llm/1.0"},
        )
        ssl_ctx = ssl.create_default_context(
            cafile=os.environ.get("SSL_CERT_FILE") or None
        )
        try:
            with (
                urllib.request.urlopen(req, timeout=60, context=ssl_ctx) as resp,
                open(part_path, "wb") as out,
            ):
                total = int(resp.headers.get("Content-Length") or MODEL_SIZE)
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
                    sha.update(chunk)
                    downloaded += len(chunk)
                    now = time.monotonic()
                    if not quiet and (now - last_report >= 1.5 or downloaded >= total):
                        pct = (downloaded * 100.0 / total) if total > 0 else 0.0
                        mib = downloaded / (1024 * 1024)
                        total_mib = total / (1024 * 1024)
                        print(
                            f"\r  {mib:.1f} / {total_mib:.1f} MiB ({pct:.1f}%)",
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


def write_pid_file(
    cache_dir: Path,
    supervisor_pid: int,
    llama_pid: int,
    port: int,
    ctx_size: int,
    reasoning: str,
    model_path: Path,
) -> None:
    info = {
        "supervisor_pid": supervisor_pid,
        "llama_pid": llama_pid,
        "port": port,
        "ctx_size": ctx_size,
        "reasoning": reasoning,
        "model": str(model_path),
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
    llama_bin = find_binary("LOCAL_LLM_LLAMA_SERVER", "llama-server")
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
        "-fa",
        "auto",
        "-ctk",
        "q8_0",
        "-ctv",
        "q8_0",
        "--host",
        "127.0.0.1",
        "--port",
        str(args.port),
        "--alias",
        DEFAULT_MODEL_ALIAS,
        "--jinja",
        "--reasoning",
        args.reasoning,
    ]

    with open(log_path, "w", encoding="utf-8") as llama_log:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=llama_log,
            stderr=subprocess.STDOUT,
            start_new_session=False,
        )

    write_pid_file(
        cache_dir=cache_dir,
        supervisor_pid=os.getpid(),
        llama_pid=proc.pid,
        port=args.port,
        ctx_size=args.ctx_size,
        reasoning=args.reasoning,
        model_path=model_path,
    )
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


def ensure_server(
    port: int,
    idle_timeout: int,
    ctx_size: int,
    reasoning: str | None = None,
    threads: int | None = None,
    quiet: bool = False,
) -> None:
    cache_dir = get_cache_dir()
    if is_server_healthy(port):
        info = read_pid_file(cache_dir)
        # Restart only if caller explicitly requested a different reasoning mode.
        if reasoning is not None and info and info.get("reasoning") != reasoning:
            if not quiet:
                print(
                    f"Restarting llama-server to switch reasoning mode ({info.get('reasoning')} -> {reasoning}) ...",
                    file=sys.stderr,
                    flush=True,
                )
            stop_server(port, quiet=True)
        else:
            touch_last_used(cache_dir)
            return

    desired_reasoning = reasoning if reasoning is not None else DEFAULT_REASONING
    download_model_if_missing(cache_dir, quiet=quiet)

    lock_path = cache_dir / "server.lock"
    with open(lock_path, "w", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
        if is_server_healthy(port):
            touch_last_used(cache_dir)
            return

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
            "--reasoning",
            desired_reasoning,
        ]
        if threads is not None:
            cmd.extend(["--threads", str(threads)])

        if not quiet:
            print(
                f"Starting llama-server ({DEFAULT_MODEL_ALIAS}, ctx={ctx_size}, reasoning={desired_reasoning}) ...",
                file=sys.stderr,
                flush=True,
            )

        with open(daemon_log, "w", encoding="utf-8") as log_fh:
            daemon_proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )

        deadline = time.monotonic() + 90.0
        while time.monotonic() < deadline:
            if is_server_healthy(port):
                touch_last_used(cache_dir)
                return
            if daemon_proc.poll() is not None:
                tail = ""
                llama_log = cache_dir / "llama-server.log"
                if llama_log.is_file():
                    tail = "\n".join(
                        llama_log.read_text(errors="replace").splitlines()[-20:]
                    )
                if not tail.strip() and daemon_log.is_file():
                    tail = "\n".join(
                        daemon_log.read_text(errors="replace").splitlines()[-20:]
                    )
                raise RuntimeError(
                    f"llama-server exited prematurely (code {daemon_proc.returncode}):\n{tail}"
                )
            time.sleep(0.25)

        raise TimeoutError(f"Timed out waiting for llama-server on 127.0.0.1:{port}")


def stop_server(port: int, quiet: bool = False) -> int:
    cache_dir = get_cache_dir()
    info = read_pid_file(cache_dir)
    if not info:
        if not is_server_healthy(port):
            if not quiet:
                print("local-llm server is not running.")
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
            if not quiet:
                print("Stopped local-llm server (RAM freed).")
            return 0
        time.sleep(0.15)

    for pid in (llama_pid, sup_pid):
        if pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    clear_pid_file(cache_dir)
    if not quiet:
        print("Killed local-llm server.")
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
    custom = get_custom_model_path()
    model_path = custom if custom is not None else (cache_dir / MODEL_FILENAME)
    ready = (
        custom.is_file()
        if custom is not None
        else is_default_model_ready(cache_dir)
    )
    info = read_pid_file(cache_dir)
    healthy = is_server_healthy(port)

    state_label = "ready" if ready else "not downloaded"
    if custom is None and (cache_dir / f"{MODEL_FILENAME}.aria2").exists():
        state_label = "downloading (aria2)"

    print(f"model:   {model_path} ({state_label})")
    print(f"alias:   {DEFAULT_MODEL_ALIAS}")
    print(f"webui:   http://127.0.0.1:{port}/")
    print(f"api:     http://127.0.0.1:{port}/v1")
    print(f"healthy: {healthy}")
    if info:
        sup_pid = int(info.get("supervisor_pid", -1))
        llama_pid = int(info.get("llama_pid", -1))
        rss = read_rss_mib(llama_pid)
        last_used = read_last_used(cache_dir)
        idle_for = max(0.0, time.time() - last_used) if last_used > 0 else 0.0
        print(f"ctx:     {info.get('ctx_size')} | reasoning: {info.get('reasoning')}")
        print(f"sup_pid: {sup_pid} (alive={pid_alive(sup_pid)})")
        print(
            f"llama:   {llama_pid} (alive={pid_alive(llama_pid)}, rss={f'{rss:.1f} MiB' if rss else 'n/a'})"
        )
        timeout_str = f"{idle_timeout}s" if idle_timeout > 0 else "disabled"
        print(f"idle:    {idle_for:.0f}s / {timeout_str}")
    else:
        print("daemon:  stopped (0 MiB RAM)")
    return 0


def stream_chat_completion(
    port: int,
    messages: list[dict[str, str]],
    max_tokens: int = 2048,
    temperature: float = 0.7,
    show_reasoning: bool = False,
) -> str:
    cache_dir = get_cache_dir()
    touch_last_used(cache_dir)

    payload = {
        "model": DEFAULT_MODEL_ALIAS,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }
    req = urllib.request.Request(
        server_url(port, "/v1/chat/completions"),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    chunks: list[str] = []
    in_thinking = False
    with urllib.request.urlopen(req, timeout=300) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line or not line.startswith("data:"):
                continue
            data_str = line[5:].strip()
            if data_str == "[DONE]":
                break
            try:
                evt = json.loads(data_str)
            except json.JSONDecodeError:
                continue
            choices = evt.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}

            reason = delta.get("reasoning_content")
            if reason and show_reasoning:
                if not in_thinking:
                    sys.stderr.write("[thinking] ")
                    in_thinking = True
                sys.stderr.write(reason)
                sys.stderr.flush()

            content = delta.get("content")
            if content:
                if in_thinking:
                    sys.stderr.write("\n")
                    sys.stderr.flush()
                    in_thinking = False
                sys.stdout.write(content)
                sys.stdout.flush()
                chunks.append(content)

    if in_thinking:
        sys.stderr.write("\n")
        sys.stderr.flush()
    touch_last_used(cache_dir)
    result = "".join(chunks)
    if result and not result.endswith("\n"):
        sys.stdout.write("\n")
        sys.stdout.flush()
    return result


def cmd_web(args: argparse.Namespace) -> int:
    ensure_server(
        port=args.port,
        idle_timeout=args.idle_timeout,
        ctx_size=args.ctx_size,
        reasoning=args.reasoning,
        threads=args.threads,
        quiet=args.quiet,
    )
    url = f"http://127.0.0.1:{args.port}/"
    print(f"WebUI: {url}")
    print(f"OpenAI API: http://127.0.0.1:{args.port}/v1 (model: {DEFAULT_MODEL_ALIAS})")
    opener = shutil.which("xdg-open")
    if opener and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        subprocess.Popen(
            [opener, url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    return 0


def cmd_ask(args: argparse.Namespace) -> int:
    prompt = " ".join(args.prompt).strip() if args.prompt else sys.stdin.read().strip()
    if not prompt:
        return 0

    ensure_server(
        port=args.port,
        idle_timeout=args.idle_timeout,
        ctx_size=args.ctx_size,
        reasoning=args.reasoning,
        threads=args.threads,
        quiet=args.quiet,
    )

    messages: list[dict[str, str]] = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    messages.append({"role": "user", "content": prompt})

    stream_chat_completion(
        port=args.port,
        messages=messages,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        show_reasoning=(args.reasoning == "on"),
    )
    return 0


def cmd_chat(args: argparse.Namespace) -> int:
    if args.direct:
        cache_dir = get_cache_dir()
        model_path = download_model_if_missing(cache_dir, quiet=args.quiet)
        llama_cli = find_binary("LOCAL_LLM_LLAMA_CLI", "llama-cli")
        threads = args.threads or detect_physical_cores()
        cmd = [
            llama_cli,
            "-m",
            str(model_path),
            "-c",
            str(args.ctx_size),
            "-t",
            str(threads),
            "-fa",
            "auto",
            "-ctk",
            "q8_0",
            "-ctv",
            "q8_0",
            "--reasoning",
            args.reasoning or DEFAULT_REASONING,
        ]
        if args.system:
            cmd.extend(["-sys", args.system])
        return subprocess.call(cmd)

    ensure_server(
        port=args.port,
        idle_timeout=args.idle_timeout,
        ctx_size=args.ctx_size,
        reasoning=args.reasoning,
        threads=args.threads,
        quiet=args.quiet,
    )

    messages: list[dict[str, str]] = []
    if args.system:
        messages.append({"role": "system", "content": args.system})

    print(
        f"Connected to {DEFAULT_MODEL_ALIAS} (127.0.0.1:{args.port}). Commands: /clear, /stop, exit",
        file=sys.stderr,
    )
    while True:
        try:
            user_input = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("", file=sys.stderr)
            break

        if not user_input:
            continue
        if user_input in ("exit", "quit", "/exit", "/quit"):
            break
        if user_input == "/clear":
            messages = (
                [{"role": "system", "content": args.system}] if args.system else []
            )
            print("Conversation cleared.", file=sys.stderr)
            continue
        if user_input == "/stop":
            stop_server(args.port)
            break

        messages.append({"role": "user", "content": user_input})
        try:
            reply = stream_chat_completion(
                port=args.port,
                messages=messages,
                max_tokens=args.max_tokens,
                temperature=args.temperature,
                show_reasoning=(args.reasoning == "on"),
            )
            messages.append({"role": "assistant", "content": reply})
        except urllib.error.URLError as exc:
            print(f"Request error: {exc}", file=sys.stderr)
            messages.pop()
        except KeyboardInterrupt:
            print("\n[interrupted]", file=sys.stderr)
            messages.pop()
    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    log_path = get_cache_dir() / "llama-server.log"
    if not log_path.is_file():
        print(f"No log file yet: {log_path}")
        return 0
    if args.follow:
        return subprocess.call(["tail", "-n", str(args.lines), "-f", str(log_path)])
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines[-args.lines :]:
        print(line)
    return 0


ACP_VERSION = "1.0.0"
ACP_MODELS = (
    {
        "modelId": "qwen3.5:4b",
        "name": "Qwen3.5-4B (Fast)",
        "description": "Local CPU Q4_K_M, thinking off (fast response)",
    },
    {
        "modelId": "qwen3.5:4b-thinking",
        "name": "Qwen3.5-4B (Thinking)",
        "description": "Local CPU Q4_K_M, reasoning enabled",
    },
)
ACP_MODES = (
    {
        "id": "code",
        "name": "Code",
        "description": "Compact workspace tools (list/read/write files, run command)",
    },
    {
        "id": "ask",
        "name": "Ask",
        "description": "Fast direct chat without tool schemas",
    },
)
ACP_TOOLS = (
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files under path in workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative or absolute directory"},
                    "glob": {"type": "string", "description": "Optional filename filter"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read lines from a UTF-8 text file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path"},
                    "start_line": {"type": "integer", "description": "1-based start line"},
                    "max_lines": {"type": "integer", "description": "Max lines (default 200)"},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write full content to a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path"},
                    "content": {"type": "string", "description": "Full file text"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Run a shell command in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Bash command"},
                },
                "required": ["command"],
            },
        },
    },
)

_RE_T3_INSTRUCTIONS = re.compile(
    r"<t3_code_instructions>.*?</t3_code_instructions>\s*",
    re.DOTALL,
)
_RE_PULL_REQUEST_LINKING = re.compile(
    r"<pull_request_linking>.*?</pull_request_linking>\s*",
    re.DOTALL,
)
_RE_RUNTIME_INFO = re.compile(
    r"<runtime_info>.*?</runtime_info>\s*",
    re.DOTALL,
)
_RE_USER_REQUEST = re.compile(
    r"^\s*<user_request>\s*(.*?)\s*</user_request>\s*$",
    re.DOTALL,
)


def _strip_t3_prompt_wrappers(text: str) -> str:
    cleaned = _RE_T3_INSTRUCTIONS.sub("", text)
    cleaned = _RE_PULL_REQUEST_LINKING.sub("", cleaned)
    cleaned = _RE_RUNTIME_INFO.sub("", cleaned)
    m = _RE_USER_REQUEST.match(cleaned)
    if m:
        cleaned = m.group(1)
    return cleaned.strip()


def _extract_acp_prompt_text(blocks: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            txt = _strip_t3_prompt_wrappers(str(block.get("text", "")))
            if txt:
                parts.append(txt)
        elif btype == "resource":
            res = block.get("resource") or {}
            uri = str(res.get("uri", ""))
            body = res.get("text")
            if isinstance(body, str):
                parts.append(f"[Resource: {uri}]\n{body}")
            elif uri:
                parts.append(f"[Resource: {uri}]")
        elif btype == "resource_link":
            uri = str(block.get("uri", ""))
            name = str(block.get("name", ""))
            label = f"{name} ({uri})" if name and uri else (uri or name)
            if label:
                parts.append(f"[Resource: {label}]")
    return "\n\n".join(parts).strip()


def _acp_session_file(cache_dir: Path, session_id: str) -> Path:
    sessions_dir = cache_dir / "acp-sessions"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id)[:120] or "default"
    return sessions_dir / f"{safe}.json"


@dataclass
class AcpSession:
    session_id: str
    cwd: str
    model_id: str = DEFAULT_MODEL_ALIAS
    mode_id: str = "code"
    messages: list[dict[str, Any]] = field(default_factory=list)
    always_allowed_tools: set[str] = field(default_factory=set)
    cancel_event: threading.Event = field(default_factory=threading.Event)
    turn_lock: threading.Lock = field(default_factory=threading.Lock)

    def model_state(self) -> dict[str, Any]:
        return {
            "currentModelId": self.model_id,
            "availableModels": list(ACP_MODELS),
        }

    def mode_state(self) -> dict[str, Any]:
        return {
            "currentModeId": self.mode_id,
            "availableModes": list(ACP_MODES),
        }

    def reasoning_flag(self) -> str:
        return "on" if self.model_id.endswith("-thinking") else "off"

    def save(self, cache_dir: Path) -> None:
        path = _acp_session_file(cache_dir, self.session_id)
        tmp = path.with_suffix(".tmp")
        data = {
            "session_id": self.session_id,
            "cwd": self.cwd,
            "model_id": self.model_id,
            "mode_id": self.mode_id,
            "messages": self.messages,
        }
        tmp.write_text(json.dumps(data, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)

    @classmethod
    def load(cls, cache_dir: Path, session_id: str, cwd: str) -> AcpSession:
        path = _acp_session_file(cache_dir, session_id)
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                model_id = str(data.get("model_id") or DEFAULT_MODEL_ALIAS)
                if model_id not in {m["modelId"] for m in ACP_MODELS}:
                    model_id = DEFAULT_MODEL_ALIAS
                mode_id = str(data.get("mode_id") or "code")
                if mode_id not in {m["id"] for m in ACP_MODES}:
                    mode_id = "code"
                msgs = data.get("messages")
                if not isinstance(msgs, list):
                    msgs = []
                return cls(
                    session_id=session_id,
                    cwd=str(data.get("cwd") or cwd),
                    model_id=model_id,
                    mode_id=mode_id,
                    messages=msgs,
                )
            except (OSError, json.JSONDecodeError):
                pass
        return cls(session_id=session_id, cwd=cwd)


def _trim_messages_for_ctx(
    messages: list[dict[str, Any]],
    ctx_size: int,
    max_tokens: int,
) -> list[dict[str, Any]]:
    # Conservative ~3.2 chars/token reserve for prompt + generation + tool overhead.
    budget_chars = max(2048, int((ctx_size - min(max_tokens, ctx_size // 3) - 640) * 3.2))
    kept: list[dict[str, Any]] = []
    used = 0
    for msg in reversed(messages):
        content_len = len(json.dumps(msg, ensure_ascii=False))
        if kept and used + content_len > budget_chars:
            break
        kept.append(msg)
        used += content_len
    kept.reverse()
    # Never start trimmed slice on an orphaned 'tool' message.
    while kept and kept[0].get("role") == "tool":
        kept.pop(0)
    return kept


def _resolve_acp_path(cwd: str, raw_path: str) -> Path:
    p = Path(raw_path).expanduser()
    if not p.is_absolute():
        p = Path(cwd) / p
    return p.resolve()


def _acp_exec_tool(
    name: str,
    args_obj: dict[str, Any],
    cwd: str,
) -> tuple[bool, str, list[dict[str, Any]]]:
    """Execute one local workspace tool -> (ok, text_output, acp_content_blocks)."""
    try:
        if name == "list_files":
            rel_or_abs = str(args_obj.get("path") or ".")
            glob_pat = str(args_obj.get("glob") or "").strip()
            target = _resolve_acp_path(cwd, rel_or_abs)
            if not target.exists():
                msg = f"Path does not exist: {target}"
                return False, msg, [{"type": "content", "content": {"type": "text", "text": msg}}]
            if target.is_file():
                msg = str(target)
                return True, msg, [{"type": "content", "content": {"type": "text", "text": msg}}]
            ignore_dirs = {".git", "node_modules", ".direnv", "__pycache__", ".venv", "dist", "target"}
            results: list[str] = []
            for root, dirs, files in os.walk(target):
                dirs[:] = sorted(d for d in dirs if d not in ignore_dirs)
                for fn in sorted(files):
                    full = Path(root) / fn
                    try:
                        rel = str(full.relative_to(target))
                    except ValueError:
                        rel = str(full)
                    if glob_pat and glob_pat not in rel and not full.match(glob_pat):
                        continue
                    results.append(rel)
                    if len(results) >= 200:
                        break
                if len(results) >= 200:
                    break
            text = "\n".join(results) if results else "(empty)"
            if len(results) >= 200:
                text += "\n... (truncated at 200 files)"
            return True, text, [{"type": "content", "content": {"type": "text", "text": text}}]

        if name == "read_file":
            target = _resolve_acp_path(cwd, str(args_obj["path"]))
            if not target.is_file():
                msg = f"File not found: {target}"
                return False, msg, [{"type": "content", "content": {"type": "text", "text": msg}}]
            start_line = max(1, int(args_obj.get("start_line") or 1))
            max_lines = max(1, min(400, int(args_obj.get("max_lines") or 200)))
            all_lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
            slice_lines = all_lines[start_line - 1 : start_line - 1 + max_lines]
            numbered = "\n".join(
                f"{start_line + idx}: {line}" for idx, line in enumerate(slice_lines)
            )
            if len(numbered) > 16384:
                numbered = numbered[:16384] + "\n... (truncated)"
            if not numbered:
                numbered = "(empty)"
            return True, numbered, [
                {"type": "content", "content": {"type": "text", "text": numbered}}
            ]

        if name == "write_file":
            target = _resolve_acp_path(cwd, str(args_obj["path"]))
            new_text = str(args_obj.get("content", ""))
            old_text: str | None = None
            if target.is_file():
                try:
                    raw_old = target.read_text(encoding="utf-8", errors="replace")
                    if len(raw_old) <= 65536:
                        old_text = raw_old
                except OSError:
                    old_text = None
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(new_text, encoding="utf-8")
            msg = f"Wrote {len(new_text)} chars to {target}"
            content_blocks: list[dict[str, Any]] = []
            if len(new_text) <= 65536:
                diff_block: dict[str, Any] = {
                    "type": "diff",
                    "path": str(target),
                    "newText": new_text,
                }
                if old_text is not None:
                    diff_block["oldText"] = old_text
                content_blocks.append(diff_block)
            else:
                content_blocks.append(
                    {"type": "content", "content": {"type": "text", "text": msg}}
                )
            return True, msg, content_blocks

        if name == "run_command":
            command = str(args_obj["command"])
            proc = subprocess.run(
                ["bash", "-lc", command],
                cwd=cwd if Path(cwd).is_dir() else None,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=60,
            )
            combined = ""
            if proc.stdout:
                combined += proc.stdout
            if proc.stderr:
                if combined and not combined.endswith("\n"):
                    combined += "\n"
                combined += proc.stderr
            if len(combined) > 12288:
                combined = combined[:12288] + "\n... (output truncated)"
            text = f"exit={proc.returncode}\n{combined}".strip()
            return proc.returncode == 0, text, [
                {"type": "content", "content": {"type": "text", "text": text}}
            ]

        msg = f"Unknown tool: {name}"
        return False, msg, [{"type": "content", "content": {"type": "text", "text": msg}}]
    except Exception as exc:
        msg = f"Tool error ({name}): {exc}"
        return False, msg, [{"type": "content", "content": {"type": "text", "text": msg}}]


class AcpServer:
    def __init__(self, args: argparse.Namespace, rpc_out: Any) -> None:
        self.args = args
        self.cache_dir = get_cache_dir()
        self.rpc_out = rpc_out
        self.write_lock = threading.Lock()
        self.sessions_lock = threading.Lock()
        self.sessions: dict[str, AcpSession] = {}
        self.pending_lock = threading.Lock()
        self.pending_requests: dict[int | str, tuple[threading.Event, dict[str, Any]]] = {}
        self.next_req_id = 1
        self.workers: list[threading.Thread] = []

    def _send_raw(self, payload: dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False) + "\n"
        with self.write_lock:
            self.rpc_out.write(line)
            self.rpc_out.flush()

    def send_result(self, req_id: int | str, result: Any) -> None:
        self._send_raw({"jsonrpc": "2.0", "id": req_id, "result": result})

    def send_error(self, req_id: int | str, code: int, message: str, data: Any = None) -> None:
        err: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self._send_raw({"jsonrpc": "2.0", "id": req_id, "error": err})

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._send_raw({"jsonrpc": "2.0", "method": method, "params": params})

    def session_update(self, session_id: str, update: dict[str, Any]) -> None:
        self.notify("session/update", {"sessionId": session_id, "update": update})

    def request_client(
        self,
        method: str,
        params: dict[str, Any],
        cancel_event: threading.Event | None = None,
        timeout: float = 300.0,
    ) -> dict[str, Any] | None:
        with self.pending_lock:
            req_id = f"local-llm-{self.next_req_id}"
            self.next_req_id += 1
            evt = threading.Event()
            box: dict[str, Any] = {}
            self.pending_requests[req_id] = (evt, box)

        self._send_raw(
            {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
        )
        deadline = time.monotonic() + timeout
        try:
            while not evt.wait(timeout=0.25):
                if cancel_event is not None and cancel_event.is_set():
                    return None
                if time.monotonic() >= deadline:
                    return None
            return box
        finally:
            with self.pending_lock:
                self.pending_requests.pop(req_id, None)

    def _get_session(self, session_id: str) -> AcpSession | None:
        with self.sessions_lock:
            return self.sessions.get(session_id)

    def _set_model_on_session(self, session: AcpSession, model_id: str) -> bool:
        valid = {m["modelId"] for m in ACP_MODELS}
        if model_id not in valid:
            return False
        session.model_id = model_id
        session.save(self.cache_dir)
        return True

    def _set_mode_on_session(self, session: AcpSession, mode_id: str) -> bool:
        alias_map = {
            "code": "code",
            "default": "code",
            "ask": "ask",
            "chat": "ask",
            "plan": "ask",
            "read-only": "ask",
        }
        mapped = alias_map.get(mode_id)
        if mapped is None:
            return False
        session.mode_id = mapped
        session.save(self.cache_dir)
        self.session_update(
            session.session_id,
            {"sessionUpdate": "current_mode_update", "currentModeId": mapped},
        )
        return True

    def _stream_completion(
        self,
        session: AcpSession,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
    ) -> tuple[bool, str, list[dict[str, Any]]]:
        """Stream one llama-server completion. Returns (cancelled, content_text, tool_calls)."""
        touch_last_used(self.cache_dir)
        payload: dict[str, Any] = {
            "model": DEFAULT_MODEL_ALIAS,
            "messages": messages,
            "temperature": 0.6 if tools else 0.7,
            "max_tokens": self.args.acp_max_tokens,
            "stream": True,
        }
        if tools:
            payload["tools"] = tools

        req = urllib.request.Request(
            server_url(self.args.port, "/v1/chat/completions"),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        text_parts: list[str] = []
        tc_acc: dict[int, dict[str, Any]] = {}
        cancelled = False

        with urllib.request.urlopen(req, timeout=600) as resp:
            try:
                sock = getattr(getattr(resp, "fp", None), "raw", None)
                if sock is not None and hasattr(sock, "_sock") and sock._sock is not None:
                    sock._sock.settimeout(60.0)
            except Exception:
                pass

            for raw_line in resp:
                if session.cancel_event.is_set():
                    cancelled = True
                    break
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line or not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    evt = json.loads(data_str)
                except json.JSONDecodeError:
                    continue
                choices = evt.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}

                reason = delta.get("reasoning_content")
                if reason:
                    self.session_update(
                        session.session_id,
                        {
                            "sessionUpdate": "agent_thought_chunk",
                            "content": {"type": "text", "text": reason},
                        },
                    )

                content = delta.get("content")
                if content:
                    text_parts.append(content)
                    self.session_update(
                        session.session_id,
                        {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": content},
                        },
                    )

                for tc in delta.get("tool_calls") or []:
                    idx = int(tc.get("index", 0))
                    entry = tc_acc.setdefault(
                        idx,
                        {
                            "id": tc.get("id") or f"call_{uuid.uuid4().hex[:12]}",
                            "type": "function",
                            "function": {"name": "", "arguments": ""},
                        },
                    )
                    if tc.get("id"):
                        entry["id"] = tc["id"]
                    fn = tc.get("function") or {}
                    if fn.get("name"):
                        entry["function"]["name"] += fn["name"]
                    if fn.get("arguments"):
                        entry["function"]["arguments"] += fn["arguments"]

        touch_last_used(self.cache_dir)
        ordered_tools = [tc_acc[k] for k in sorted(tc_acc)]
        return cancelled, "".join(text_parts), ordered_tools

    def _request_tool_permission(
        self,
        session: AcpSession,
        tool_call_id: str,
        tool_name: str,
        title: str,
        kind: str,
        raw_input: dict[str, Any],
    ) -> bool:
        if tool_name in session.always_allowed_tools:
            return True

        resp = self.request_client(
            "session/request_permission",
            {
                "sessionId": session.session_id,
                "toolCall": {
                    "toolCallId": tool_call_id,
                    "title": title,
                    "kind": kind,
                    "status": "pending",
                    "rawInput": raw_input,
                },
                "options": [
                    {
                        "optionId": "allow_once",
                        "name": "Allow once",
                        "kind": "allow_once",
                    },
                    {
                        "optionId": "allow_always",
                        "name": "Always allow in session",
                        "kind": "allow_always",
                    },
                    {
                        "optionId": "reject_once",
                        "name": "Reject",
                        "kind": "reject_once",
                    },
                ],
            },
            cancel_event=session.cancel_event,
        )
        if not resp or "error" in resp:
            return False
        result = resp.get("result") or {}
        outcome = result.get("outcome") or {}
        if outcome.get("outcome") != "selected":
            return False
        opt_id = outcome.get("optionId")
        if opt_id == "allow_always":
            session.always_allowed_tools.add(tool_name)
            return True
        return opt_id == "allow_once"

    def _run_prompt(self, req_id: int | str, params: dict[str, Any]) -> None:
        session_id = str(params.get("sessionId") or "")
        session = self._get_session(session_id)
        if session is None:
            self.send_error(req_id, -32602, f"Unknown sessionId: {session_id}")
            return

        blocks = params.get("prompt") or []
        if not isinstance(blocks, list):
            self.send_error(req_id, -32602, "prompt must be a list")
            return

        user_text = _extract_acp_prompt_text(blocks)
        if not user_text:
            self.send_result(req_id, {"stopReason": "end_turn"})
            return

        with session.turn_lock:
            session.cancel_event.clear()

            # Instant local slash commands without waking llama-server unnecessarily.
            cmd_word = user_text.strip().split()[0].lower()
            if cmd_word == "/clear":
                session.messages.clear()
                session.save(self.cache_dir)
                self.session_update(
                    session.session_id,
                    {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "Session history cleared."},
                    },
                )
                self.send_result(req_id, {"stopReason": "end_turn"})
                return

            if cmd_word == "/stop":
                stop_server(self.args.port, quiet=True)
                self.session_update(
                    session.session_id,
                    {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {
                            "type": "text",
                            "text": "Stopped local llama-server (model RAM freed).",
                        },
                    },
                )
                self.send_result(req_id, {"stopReason": "end_turn"})
                return

            if cmd_word == "/status":
                info = read_pid_file(self.cache_dir)
                healthy = is_server_healthy(self.args.port)
                if info and healthy:
                    rss = read_rss_mib(int(info.get("llama_pid", -1)))
                    rss_str = f"{rss:.1f} MiB" if rss else "n/a"
                    msg = f"Model: {session.model_id} | Mode: {session.mode_id} | Server: running (RSS {rss_str})"
                else:
                    msg = f"Model: {session.model_id} | Mode: {session.mode_id} | Server: stopped (0 MiB RAM)"
                self.session_update(
                    session.session_id,
                    {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": msg},
                    },
                )
                self.send_result(req_id, {"stopReason": "end_turn"})
                return

            try:
                ensure_server(
                    port=self.args.port,
                    idle_timeout=self.args.idle_timeout,
                    ctx_size=self.args.ctx_size,
                    reasoning=session.reasoning_flag(),
                    threads=self.args.threads,
                    quiet=True,
                )
            except Exception as exc:
                self.send_error(req_id, -32603, f"Failed to start llama-server: {exc}")
                return

            if session.cancel_event.is_set():
                self.send_result(req_id, {"stopReason": "cancelled"})
                return

            if session.mode_id == "code":
                sys_prompt = (
                    f"You are a concise coding assistant running locally in {session.cwd}. "
                    "Use tools when inspecting or modifying files. Keep replies focused."
                )
                tools: list[dict[str, Any]] | None = list(ACP_TOOLS)
            else:
                sys_prompt = "You are a concise, helpful AI assistant. Keep answers accurate and brief."
                tools = None

            turn_messages: list[dict[str, Any]] = [
                *session.messages,
                {"role": "user", "content": user_text},
            ]

            kind_map = {
                "list_files": "search",
                "read_file": "read",
                "write_file": "edit",
                "run_command": "execute",
            }
            cancelled = False
            max_steps = 8 if tools else 1

            try:
                for _step in range(max_steps):
                    trimmed = _trim_messages_for_ctx(
                        turn_messages,
                        ctx_size=self.args.ctx_size,
                        max_tokens=self.args.acp_max_tokens,
                    )
                    req_messages = [{"role": "system", "content": sys_prompt}, *trimmed]
                    cancelled, text_out, tool_calls = self._stream_completion(
                        session, req_messages, tools
                    )
                    if cancelled:
                        break

                    if not tool_calls:
                        turn_messages.append({"role": "assistant", "content": text_out})
                        break

                    assistant_msg: dict[str, Any] = {
                        "role": "assistant",
                        "tool_calls": tool_calls,
                    }
                    if text_out:
                        assistant_msg["content"] = text_out
                    turn_messages.append(assistant_msg)

                    for tc in tool_calls:
                        if session.cancel_event.is_set():
                            cancelled = True
                            break
                        tc_id = str(tc.get("id") or f"call_{uuid.uuid4().hex[:12]}")
                        fn = tc.get("function") or {}
                        t_name = str(fn.get("name") or "")
                        raw_args = str(fn.get("arguments") or "{}")
                        try:
                            args_obj = json.loads(raw_args) if raw_args.strip() else {}
                            if not isinstance(args_obj, dict):
                                args_obj = {}
                        except json.JSONDecodeError:
                            args_obj = {}

                        t_kind = kind_map.get(t_name, "other")
                        if t_name == "list_files":
                            title = f"List {args_obj.get('path') or '.'}"
                        elif t_name == "read_file":
                            title = f"Read {args_obj.get('path', '')}"
                        elif t_name == "write_file":
                            title = f"Write {args_obj.get('path', '')}"
                        elif t_name == "run_command":
                            title = f"Run: {str(args_obj.get('command', ''))[:60]}"
                        else:
                            title = t_name or "tool"

                        needs_perm = t_name in {"write_file", "run_command"}
                        self.session_update(
                            session.session_id,
                            {
                                "sessionUpdate": "tool_call",
                                "toolCallId": tc_id,
                                "title": title,
                                "kind": t_kind,
                                "status": "pending" if needs_perm else "in_progress",
                                "rawInput": args_obj,
                            },
                        )

                        if needs_perm:
                            approved = self._request_tool_permission(
                                session,
                                tool_call_id=tc_id,
                                tool_name=t_name,
                                title=title,
                                kind=t_kind,
                                raw_input=args_obj,
                            )
                            if session.cancel_event.is_set():
                                cancelled = True
                                self.session_update(
                                    session.session_id,
                                    {
                                        "sessionUpdate": "tool_call_update",
                                        "toolCallId": tc_id,
                                        "status": "failed",
                                        "rawOutput": {"error": "Cancelled"},
                                    },
                                )
                                break
                            if not approved:
                                deny_msg = "Permission denied by user."
                                self.session_update(
                                    session.session_id,
                                    {
                                        "sessionUpdate": "tool_call_update",
                                        "toolCallId": tc_id,
                                        "status": "failed",
                                        "content": [
                                            {
                                                "type": "content",
                                                "content": {"type": "text", "text": deny_msg},
                                            }
                                        ],
                                        "rawOutput": {"error": deny_msg},
                                    },
                                )
                                turn_messages.append(
                                    {
                                        "role": "tool",
                                        "tool_call_id": tc_id,
                                        "content": deny_msg,
                                    }
                                )
                                continue
                            self.session_update(
                                session.session_id,
                                {
                                    "sessionUpdate": "tool_call_update",
                                    "toolCallId": tc_id,
                                    "status": "in_progress",
                                },
                            )

                        ok, out_text, blocks_out = _acp_exec_tool(
                            t_name, args_obj, session.cwd
                        )
                        self.session_update(
                            session.session_id,
                            {
                                "sessionUpdate": "tool_call_update",
                                "toolCallId": tc_id,
                                "status": "completed" if ok else "failed",
                                "content": blocks_out,
                                "rawOutput": {"output": out_text},
                            },
                        )
                        turn_messages.append(
                            {
                                "role": "tool",
                                "tool_call_id": tc_id,
                                "content": out_text,
                            }
                        )

                    if cancelled:
                        break
            except Exception as exc:
                self.send_error(req_id, -32603, f"Inference error: {exc}")
                return

            if cancelled:
                self.send_result(req_id, {"stopReason": "cancelled"})
                return

            # Keep last 40 messages on disk so session file stays bounded.
            session.messages = turn_messages[-40:]
            session.save(self.cache_dir)
            self.send_result(req_id, {"stopReason": "end_turn"})

    def _handle_request(self, req_id: int | str, method: str, params: dict[str, Any]) -> None:
        if method == "initialize":
            self.send_result(
                req_id,
                {
                    "protocolVersion": 1,
                    "agentInfo": {
                        "name": "local-llm",
                        "title": "Local LLM (Qwen3.5-4B)",
                        "version": ACP_VERSION,
                    },
                    "agentCapabilities": {
                        "loadSession": True,
                        "promptCapabilities": {
                            "image": False,
                            "audio": False,
                            "embeddedContext": True,
                        },
                    },
                    "authMethods": [],
                },
            )
            return

        if method == "session/new":
            cwd = str(params.get("cwd") or os.getcwd())
            session_id = uuid.uuid4().hex
            session = AcpSession(session_id=session_id, cwd=cwd)
            with self.sessions_lock:
                self.sessions[session_id] = session
            session.save(self.cache_dir)
            self.send_result(
                req_id,
                {
                    "sessionId": session_id,
                    "models": session.model_state(),
                    "modes": session.mode_state(),
                },
            )
            return

        if method == "session/load":
            session_id = str(params.get("sessionId") or "")
            if not session_id:
                self.send_error(req_id, -32602, "sessionId is required")
                return
            cwd = str(params.get("cwd") or os.getcwd())
            session = AcpSession.load(self.cache_dir, session_id, cwd)
            with self.sessions_lock:
                self.sessions[session_id] = session
            session.save(self.cache_dir)
            self.send_result(
                req_id,
                {
                    "models": session.model_state(),
                    "modes": session.mode_state(),
                },
            )
            return

        if method == "session/set_model":
            session_id = str(params.get("sessionId") or "")
            model_id = str(params.get("modelId") or "")
            session = self._get_session(session_id)
            if session is None:
                self.send_error(req_id, -32602, f"Unknown sessionId: {session_id}")
                return
            if not self._set_model_on_session(session, model_id):
                self.send_error(req_id, -32602, f"Unsupported modelId: {model_id}")
                return
            self.send_result(req_id, {})
            return

        if method == "session/set_mode":
            session_id = str(params.get("sessionId") or "")
            mode_id = str(params.get("modeId") or "")
            session = self._get_session(session_id)
            if session is None:
                self.send_error(req_id, -32602, f"Unknown sessionId: {session_id}")
                return
            if not self._set_mode_on_session(session, mode_id):
                self.send_error(req_id, -32602, f"Unsupported modeId: {mode_id}")
                return
            self.send_result(req_id, {})
            return

        if method == "session/set_config_option":
            session_id = str(params.get("sessionId") or "")
            config_id = str(params.get("configId") or "")
            value = str(params.get("value") or "")
            session = self._get_session(session_id)
            if session is None:
                self.send_error(req_id, -32602, f"Unknown sessionId: {session_id}")
                return
            if config_id == "model":
                if not self._set_model_on_session(session, value):
                    self.send_error(req_id, -32602, f"Unsupported model: {value}")
                    return
                self.send_result(req_id, {"configOptions": []})
                return
            if config_id == "mode":
                if not self._set_mode_on_session(session, value):
                    self.send_error(req_id, -32602, f"Unsupported mode: {value}")
                    return
                self.send_result(req_id, {"configOptions": []})
                return
            self.send_error(req_id, -32602, f"Unsupported configId: {config_id}")
            return

        if method == "session/close":
            session_id = str(params.get("sessionId") or "")
            session = None
            with self.sessions_lock:
                session = self.sessions.pop(session_id, None)
            if session is not None:
                session.cancel_event.set()
            self.send_result(req_id, {})
            return

        if method == "session/prompt":
            t = threading.Thread(
                target=self._run_prompt,
                args=(req_id, params),
                daemon=True,
            )
            self.workers.append(t)
            t.start()
            return

        self.send_error(req_id, -32601, f"Method not found: {method}")

    def _handle_notification(self, method: str, params: dict[str, Any]) -> None:
        if method == "session/cancel":
            session_id = str(params.get("sessionId") or "")
            session = self._get_session(session_id)
            if session is not None:
                session.cancel_event.set()

    def serve(self) -> int:
        stdin_buf = sys.stdin.buffer
        while True:
            raw = stdin_buf.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(msg, dict):
                continue

            if "method" in msg:
                method = str(msg["method"])
                params = msg.get("params") or {}
                if not isinstance(params, dict):
                    params = {}
                if "id" in msg and msg["id"] is not None:
                    self._handle_request(msg["id"], method, params)
                else:
                    self._handle_notification(method, params)
            elif "id" in msg and msg["id"] is not None:
                req_id = msg["id"]
                with self.pending_lock:
                    waiter = self.pending_requests.get(req_id)
                if waiter is not None:
                    evt, box = waiter
                    if "error" in msg:
                        box["error"] = msg["error"]
                    else:
                        box["result"] = msg.get("result")
                    evt.set()

        # Stdin closed: cancel any active prompts cleanly.
        with self.sessions_lock:
            for s in self.sessions.values():
                s.cancel_event.set()
        return 0


def cmd_acp(args: argparse.Namespace) -> int:
    # Reserve real stdout exclusively for line-delimited JSON-RPC 2.0 frames.
    rpc_out = sys.stdout
    sys.stdout = sys.stderr
    server = AcpServer(args=args, rpc_out=rpc_out)
    return server.serve()


def _common_server_args_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--port", type=int, default=argparse.SUPPRESS)
    p.add_argument("--idle-timeout", type=int, default=argparse.SUPPRESS)
    p.add_argument("--ctx-size", type=int, default=argparse.SUPPRESS)
    p.add_argument("--threads", type=int, default=argparse.SUPPRESS)
    p.add_argument("-q", "--quiet", action="store_true", default=argparse.SUPPRESS)
    think_grp = p.add_mutually_exclusive_group()
    think_grp.add_argument(
        "--thinking",
        dest="reasoning",
        action="store_const",
        const="on",
        default=argparse.SUPPRESS,
        help="Enable thinking/reasoning mode",
    )
    think_grp.add_argument(
        "--no-thinking",
        dest="reasoning",
        action="store_const",
        const="off",
        default=argparse.SUPPRESS,
        help="Disable thinking/reasoning mode (default, faster on CPU)",
    )
    return p


def build_parser() -> argparse.ArgumentParser:
    common = _common_server_args_parser()
    parser = argparse.ArgumentParser(
        prog="local-llm",
        description="On-demand llama.cpp server + CLI for Qwen3.5-4B (Q4_K_M)",
        parents=[common],
    )
    parser.add_argument("-V", "--version", action="version", version=f"local-llm {ACP_VERSION}")
    parser.set_defaults(
        port=DEFAULT_PORT,
        idle_timeout=DEFAULT_IDLE_SECONDS,
        ctx_size=DEFAULT_CTX_SIZE,
        threads=None,
        reasoning=None,
        quiet=False,
    )

    sub = parser.add_subparsers(dest="command")

    sub.add_parser(
        "ensure",
        parents=[common],
        help="Download model if needed and start llama-server on demand",
    )
    sub.add_parser(
        "web",
        aliases=["ui"],
        parents=[common],
        help="Start llama-server and open built-in WebUI in browser",
    )
    sub.add_parser(
        "stop",
        parents=[common],
        help="Stop background llama-server immediately (free RAM)",
    )
    sub.add_parser(
        "status",
        parents=[common],
        help="Show model, API URL, server status, and RAM usage",
    )

    daemon_p = sub.add_parser(
        "daemon", parents=[common], help="Internal foreground supervisor"
    )
    daemon_p.add_argument(
        "--reasoning",
        choices=("on", "off", "auto"),
        default=DEFAULT_REASONING,
    )

    ask_p = sub.add_parser(
        "ask", parents=[common], help="One-shot prompt (args or stdin)"
    )
    ask_p.add_argument("-s", "--system", default="")
    ask_p.add_argument("--max-tokens", type=int, default=2048)
    ask_p.add_argument("--temperature", type=float, default=0.7)
    ask_p.add_argument("prompt", nargs="*")

    chat_p = sub.add_parser(
        "chat", parents=[common], help="Interactive terminal chat"
    )
    chat_p.add_argument("-s", "--system", default="")
    chat_p.add_argument("--max-tokens", type=int, default=2048)
    chat_p.add_argument("--temperature", type=float, default=0.7)
    chat_p.add_argument(
        "--direct",
        action="store_true",
        help="Run llama-cli directly instead of talking to llama-server",
    )

    logs_p = sub.add_parser("logs", parents=[common], help="Show llama-server logs")
    logs_p.add_argument("-n", "--lines", type=int, default=50)
    logs_p.add_argument("-f", "--follow", action="store_true")

    acp_p = sub.add_parser(
        "acp", parents=[common], help="Run Agent Client Protocol (ACP) stdio server (for T3 Code)"
    )
    acp_p.add_argument("--max-tokens", dest="acp_max_tokens", type=int, default=2048)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    known_cmds = {
        "ensure",
        "web",
        "ui",
        "stop",
        "status",
        "daemon",
        "ask",
        "chat",
        "logs",
        "acp",
        "-h",
        "--help",
        "-V",
        "--version",
    }
    if raw_argv and not any(tok in known_cmds for tok in raw_argv):
        if any(tok in ("-h", "--help") for tok in raw_argv):
            parser.print_help()
            return 0
        raw_argv = ["ask", *raw_argv]
    elif not raw_argv and not sys.stdin.isatty():
        raw_argv = ["ask"]
    elif not raw_argv:
        parser.print_help()
        return 0

    args = parser.parse_args(raw_argv)

    if args.command == "daemon":
        return run_daemon(args)
    if args.command == "ensure":
        ensure_server(
            port=args.port,
            idle_timeout=args.idle_timeout,
            ctx_size=args.ctx_size,
            reasoning=args.reasoning,
            threads=args.threads,
            quiet=args.quiet,
        )
        return 0
    if args.command in ("web", "ui"):
        return cmd_web(args)
    if args.command == "stop":
        return stop_server(args.port, quiet=args.quiet)
    if args.command == "status":
        return status_server(args.port, args.idle_timeout)
    if args.command == "ask":
        return cmd_ask(args)
    if args.command == "chat":
        return cmd_chat(args)
    if args.command == "logs":
        return cmd_logs(args)
    if args.command == "acp":
        return cmd_acp(args)

    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
