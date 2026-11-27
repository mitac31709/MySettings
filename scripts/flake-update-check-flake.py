#!/usr/bin/env python3
"""Emit REC lines for outdated flake inputs (GitHub + git) and watched nixpkgs apps."""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

BASE_HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "flake-update-check",
}

# (id, short, icon, explicit repo paths when not pkgs/by-name/xx/id)
WATCH: dict[str, list[tuple[str, str, str, tuple[str, ...]]]] = {
    "nixpkgs": [
        ("ghostty", "gsty", "\uf120", ()),
        ("vivaldi", "viv", "\uf27c", ()),
        ("firefox", "ff", "\uf269", ("pkgs/applications/networking/browsers/firefox",)),
        ("neovim", "nvim", "\ue62b", ("pkgs/applications/editors/neovim",)),
        ("zed-editor", "zed", "\uf121", ()),
        ("claude-code", "clde", "\U000f06a9", ()),
        ("opencode", "opcd", "\uf121", ()),
        ("chatgpt", "gpt", "\uf075", ()),
        ("btop", "btop", "\uf080", ()),
        ("yazi", "yazi", "\uf07b", ()),
        ("tmux", "tmux", "\uf489", ()),
        ("peazip", "pea", "\uf1c6", ()),
        ("_7zip-zstd", "7z", "\uf1c6", ()),
        ("bottles", "botl", "\uf0c3", ()),
        ("discord", "disc", "\uf086", ()),
        ("hyprland", "hypr", "\ue615", ()),
        ("hyprlock", "lock", "\uf023", ()),
        ("hypridle", "idle", "\uf06e", ()),
        ("hyprpaper", "wall", "\uf03e", ()),
        ("hyprsunset", "suns", "\uf186", ()),
        ("cage", "cage", "\uf2d1", ()),
        ("rofi", "rofi", "\uf0c9", ()),
        ("tor-browser", "tor", "\uf06e", ()),
        ("trayscale", "tsui", "\uf0e8", ()),
        ("tailscale", "ts", "\uf0e8", ()),
        ("cloudflare-warp", "warp", "\uf0e7", ()),
        ("onlyoffice-desktopeditors", "oof", "\uf15c", ()),
        ("orca-slicer", "orca", "\uf1b2", ()),
        ("parsec-bin", "prsc", "\uf11b", ()),
        ("steam", "stm", "\uf1b6", ()),
        ("localsend", "lsnd", "\uf1d8", ()),
        ("rquickshare", "qs", "\uf1e0", ()),
        ("lan-mouse", "lmse", "\uf245", ()),
        ("fcitx5", "ime", "\uf1ab", ()),
        ("showmethekey", "smtk", "\uf11c", ()),
        ("cliphist", "clip", "\uf0c5", ()),
        ("wl-clipboard", "wlcp", "\uf0ea", ()),
        ("rbw", "rbw", "\uf023", ()),
        ("restic", "rstc", "\uf1c0", ()),
        ("rclone", "rcln", "\uf0c2", ()),
        ("age", "age", "\uf084", ()),
        ("aria2", "aria", "\uf019", ()),
        ("yt-dlp", "ytdl", "\uf16a", ()),
        ("mpv", "mpv", "\uf144", ()),
        ("ffmpeg", "ffmp", "\uf008", ("pkgs/development/libraries/ffmpeg",)),
        ("mediainfo", "mifo", "\uf008", ()),
        ("bat", "bat", "\uf1c9", ()),
        ("nix-output-monitor", "nom", "\uf1de", ()),
        ("qtscrcpy", "scpy", "\uf10b", ()),
        ("android-tools", "adb", "\uf10b", ("pkgs/tools/misc/android-tools",)),
        ("arduino-cli", "ard", "\uf2db", ()),
        ("esptool", "esp", "\uf2db", ()),
        ("nodejs", "node", "\uf121", ("pkgs/development/web/nodejs",)),
        ("pnpm", "pnpm", "\uf466", ("pkgs/development/tools/pnpm",)),
        ("typst", "typs", "\uf15c", ()),
        ("tinymist", "tmst", "\uf15c", ()),
        ("typstyle", "tyst", "\uf15c", ()),
        ("git", "git", "\uf126", ()),
        ("gh", "gh", "\uf09b", ()),
        ("t3code", "t3", "\uf121", ()),
        ("llama-cpp", "llam", "\U000f06a9", ()),
        ("activitywatch", "aw", "\uf017", ()),
        ("awatcher", "awat", "\uf017", ()),
        ("qalculate-qt", "qalc", "\uf1ec", ()),
        ("chawan", "cha", "\uf0ac", ()),
    ],
    "nixpkgs-cursor": [
        ("code-cursor", "curs", "\ue795", ()),
        ("cursor-cli", "ccli", "\uf120", ()),
    ],
}

FLAKE_META = {
    "home-manager": ("\uf015", "hm", "home-manager"),
    "alsa-ucm-conf-cros": ("\uf028", "alsa", "alsa-ucm-conf-cros"),
    "bootvine": ("\uf1bb", "vine", "bootvine"),
    "agenix": ("\uf084", "age", "agenix"),
    "colorshell": ("\uf53f", "csh", "colorshell"),
    "hermes-agent": ("\uf0e0", "hrms", "hermes-agent"),
}


def load_github_token() -> str:
    for env_key in ("GH_TOKEN", "GITHUB_TOKEN"):
        tok = os.environ.get(env_key, "").strip()
        if tok:
            return tok

    candidates = [
        pathlib.Path.home() / ".config/gh/hosts.yml",
        pathlib.Path("/run/agenix/gh-hosts.yml"),
    ]
    for path in candidates:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        in_github = False
        for raw_line in text.splitlines():
            if not raw_line.strip() or raw_line.lstrip().startswith("#"):
                continue
            if not raw_line.startswith((" ", "\t")):
                in_github = raw_line.strip().rstrip(":") == "github.com"
                continue
            if in_github:
                m = re.match(r"\s*oauth_token:\s*(\S+)", raw_line)
                if m:
                    return m.group(1).strip("'\"")
    return ""


TOKEN = load_github_token()


def github_headers() -> dict[str, str]:
    headers = dict(BASE_HEADERS)
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    return headers


def http_json(url: str, body: dict | None = None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = github_headers()
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as resp:
        return json.load(resp)


def by_name_dir(attr: str) -> str:
    return f"pkgs/by-name/{attr[:2].lower()}/{attr}"


def watch_paths(attr: str, explicit_paths: tuple[str, ...]) -> tuple[str, ...]:
    return explicit_paths if explicit_paths else (by_name_dir(attr),)


def git_ls_remote_tip(repo_url: str, ref: str) -> str:
    """Resolve upstream commit SHA via git ls-remote without spending API quota."""
    ref = (ref or "HEAD").strip()
    if ref == "HEAD":
        candidates = ["HEAD"]
    elif ref.startswith("refs/"):
        candidates = [f"{ref}^{{}}", ref]
    else:
        candidates = [
            f"refs/heads/{ref}",
            f"refs/tags/{ref}^{{}}",
            f"refs/tags/{ref}",
            ref,
        ]

    try:
        proc = subprocess.run(
            ["git", "ls-remote", repo_url, *candidates],
            capture_output=True,
            text=True,
            timeout=25,
            check=False,
        )
    except Exception:
        return ""
    if proc.returncode != 0 or not proc.stdout.strip():
        return ""

    by_ref: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2:
            by_ref[parts[1].strip()] = parts[0].strip()

    for cand in candidates:
        if cand in by_ref:
            return by_ref[cand]
    return next(iter(by_ref.values()), "")


def api_tip_sha(owner: str, repo: str, ref: str) -> str:
    ref_clean = ref.removeprefix("refs/heads/").removeprefix("refs/tags/")
    candidates = [
        f"https://api.github.com/repos/{owner}/{repo}/git/ref/heads/{ref_clean}",
        f"https://api.github.com/repos/{owner}/{repo}/git/ref/tags/{ref_clean}",
        f"https://api.github.com/repos/{owner}/{repo}/commits/{ref_clean}",
    ]
    if ref == "HEAD":
        candidates = [f"https://api.github.com/repos/{owner}/{repo}/commits/HEAD"]
    for url in candidates:
        try:
            data = http_json(url)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            raise
        if "object" in data and isinstance(data["object"], dict):
            sha = data["object"].get("sha") or ""
            if data["object"].get("type") == "tag":
                tdata = http_json(
                    f"https://api.github.com/repos/{owner}/{repo}/git/tags/{sha}"
                )
                return (tdata.get("object") or {}).get("sha") or sha
            return sha
        if "sha" in data:
            return data["sha"] or ""
    return ""


def changed_apps_via_compare(owner: str, repo: str, base: str, head: str, watch):
    url = f"https://api.github.com/repos/{owner}/{repo}/compare/{base}...{head}"
    data = http_json(url)
    files = data.get("files") or []
    changed_paths = "\n".join(f.get("filename", "") for f in files).lower()
    hits = []
    for pkg_id, short, icon, explicit in watch:
        paths = watch_paths(pkg_id, explicit)
        if any(p.lower() in changed_paths for p in paths):
            hits.append((pkg_id, short, icon))
    truncated = len(files) >= 300
    if data.get("status") in ("ahead", "diverged") and not files:
        truncated = True
    ahead = data.get("ahead_by") or 0
    return hits, truncated, ahead


def changed_apps_via_graphql(
    owner: str, repo: str, base: str, head: str, watch
) -> list[tuple[str, str, str]]:
    """Batch-compare exact git tree/blob OIDs across watched paths in 1-2 GraphQL calls."""
    if not TOKEN:
        raise RuntimeError("no GitHub token for GraphQL")

    hits: list[tuple[str, str, str]] = []
    chunk_size = 35
    for idx in range(0, len(watch), chunk_size):
        chunk = watch[idx : idx + chunk_size]
        fields: list[str] = []
        mapping: list[tuple[str, str, str, list[tuple[str, str]]]] = []
        alias_num = 0
        for pkg_id, short, icon, explicit in chunk:
            path_aliases: list[tuple[str, str]] = []
            for p in watch_paths(pkg_id, explicit):
                b_alias = f"b{alias_num}"
                h_alias = f"h{alias_num}"
                alias_num += 1
                b_expr = json.dumps(f"{base}:{p}")
                h_expr = json.dumps(f"{head}:{p}")
                fields.append(f"{b_alias}: object(expression: {b_expr}) {{ oid }}")
                fields.append(f"{h_alias}: object(expression: {h_expr}) {{ oid }}")
                path_aliases.append((b_alias, h_alias))
            mapping.append((pkg_id, short, icon, path_aliases))

        query = (
            f"query {{ repository(owner: {json.dumps(owner)}, name: {json.dumps(repo)}) {{"
            + " ".join(fields)
            + " } }"
        )
        res = http_json("https://api.github.com/graphql", {"query": query})
        if res.get("errors") and not res.get("data"):
            raise RuntimeError(str(res["errors"]))
        repo_data = (res.get("data") or {}).get("repository") or {}
        for pkg_id, short, icon, path_aliases in mapping:
            for b_alias, h_alias in path_aliases:
                b_oid = (repo_data.get(b_alias) or {}).get("oid")
                h_oid = (repo_data.get(h_alias) or {}).get("oid")
                if b_oid is None and h_oid is None:
                    continue
                if b_oid != h_oid:
                    hits.append((pkg_id, short, icon))
                    break
    return hits


def fetch_tree_map(owner: str, repo: str, ref: str, path: str) -> dict[str, str]:
    url = f"https://api.github.com/repos/{owner}/{repo}/git/trees/{ref}:{path}"
    try:
        data = http_json(url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise
    return {entry.get("path", ""): entry.get("sha", "") for entry in data.get("tree") or []}


def content_sha(owner: str, repo: str, path: str, ref: str) -> str | None:
    url = f"https://api.github.com/repos/{owner}/{repo}/contents/{path}?ref={ref}"
    try:
        data = http_json(url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    if isinstance(data, list):
        return ",".join(sorted(x.get("sha", "") for x in data))
    return data.get("sha")


def changed_apps_via_trees_unauth(owner: str, repo: str, base: str, head: str, watch):
    """Unauthenticated fallback: prefilter unchanged pkgs/by-name buckets first."""
    base_buckets = fetch_tree_map(owner, repo, base, "pkgs/by-name")
    head_buckets = fetch_tree_map(owner, repo, head, "pkgs/by-name")

    prefix_cache: dict[str, tuple[dict[str, str], dict[str, str]]] = {}
    hits = []
    for pkg_id, short, icon, explicit in watch:
        changed = False
        if not explicit:
            prefix = pkg_id[:2].lower()
            if base_buckets.get(prefix) == head_buckets.get(prefix):
                continue
            if prefix not in prefix_cache:
                prefix_cache[prefix] = (
                    fetch_tree_map(owner, repo, base, f"pkgs/by-name/{prefix}"),
                    fetch_tree_map(owner, repo, head, f"pkgs/by-name/{prefix}"),
                )
            b_dir, h_dir = prefix_cache[prefix]
            changed = b_dir.get(pkg_id) != h_dir.get(pkg_id)
        else:
            for p in explicit:
                if content_sha(owner, repo, p, base) != content_sha(owner, repo, p, head):
                    changed = True
                    break
        if changed:
            hits.append((pkg_id, short, icon))
    return hits


def resolve_input_source(node: dict) -> tuple[str, str, str, str] | None:
    """Return (kind, owner_or_url, repo_or_empty, ref) for github or git inputs."""
    original = node.get("original") or {}
    locked = node.get("locked") or {}
    kind = locked.get("type") or original.get("type")
    if kind == "github":
        owner = locked.get("owner") or original.get("owner") or ""
        repo = locked.get("repo") or original.get("repo") or ""
        ref = original.get("ref") or locked.get("ref") or "HEAD"
        if owner and repo:
            return "github", owner, repo, ref
    elif kind == "git":
        url = locked.get("url") or original.get("url") or ""
        ref = original.get("ref") or locked.get("ref") or "HEAD"
        if url:
            return "git", url, "", ref
    return None


def main() -> int:
    lock = json.load(open(sys.argv[1], encoding="utf-8"))
    nodes = lock["nodes"]
    root_inputs = nodes["root"]["inputs"]

    for name, node_key in sorted(root_inputs.items()):
        node = nodes[node_key]
        locked = node.get("locked") or {}
        rev = locked.get("rev") or ""
        src = resolve_input_source(node)
        if not rev or src is None:
            continue

        kind, target, repo, ref = src
        repo_url = f"https://github.com/{target}/{repo}.git" if kind == "github" else target

        tip = git_ls_remote_tip(repo_url, ref)
        if not tip and kind == "github":
            try:
                tip = api_tip_sha(target, repo, ref)
            except Exception:
                print(f"__FAIL__{name}", flush=True)
                continue
        if not tip:
            print(f"__FAIL__{name}", flush=True)
            continue
        if tip == rev:
            continue

        if kind == "github" and name in WATCH:
            watch = WATCH[name]
            hits: list[tuple[str, str, str]] = []
            truncated = False
            ahead = 0
            try:
                hits, truncated, ahead = changed_apps_via_compare(
                    target, repo, rev, tip, watch
                )
            except Exception:
                truncated = True

            if truncated or (ahead > 50 and len(hits) < 2):
                probed: list[tuple[str, str, str]] = []
                if TOKEN:
                    try:
                        probed = changed_apps_via_graphql(target, repo, rev, tip, watch)
                    except Exception:
                        probed = []
                if not probed and not TOKEN:
                    try:
                        probed = changed_apps_via_trees_unauth(
                            target, repo, rev, tip, watch
                        )
                    except urllib.error.HTTPError as e:
                        if e.code == 403 and not hits:
                            print(f"__FAIL__{name}", flush=True)
                            continue
                    except Exception:
                        pass

                seen = {h[0] for h in hits}
                for item in probed:
                    if item[0] not in seen:
                        hits.append(item)
                        seen.add(item[0])

            ahead_note = f"+{ahead} commit" if ahead else "更新あり"
            if hits:
                for pkg_id, short, icon in hits:
                    print(
                        f"REC\t{icon}\t{short}\t{pkg_id} ({name}, {ahead_note})",
                        flush=True,
                    )
            else:
                icon, short = ("\uf313", "nix")
                if name == "nixpkgs-cursor":
                    icon, short = ("\ue795", "cur")
                print(
                    f"REC\t{icon}\t{short}\t{name} tip 更新"
                    f"（監視アプリに差分なし / {ahead_note}）",
                    flush=True,
                )
            continue

        if name in FLAKE_META:
            icon, short, label = FLAKE_META[name]
            print(f"REC\t{icon}\t{short}\t{label} tip 更新", flush=True)
            continue

        print(f"REC\t\uf126\t{name[:4]}\t{name} tip 更新", flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
