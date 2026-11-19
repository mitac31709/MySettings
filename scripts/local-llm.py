#!/usr/bin/env python3
"""On-demand llama.cpp server manager and CLI for Qwen3.5-4B."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import signal
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

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
        "-h",
        "--help",
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

    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
