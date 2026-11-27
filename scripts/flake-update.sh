#!/usr/bin/env bash
# Update .deb inputs in flake.nix, custom pkgs/* derivations (except jquake
# pinned at 1.8.4), all flake.lock inputs (including nixpkgs-cursor), and
# locally installed dsh-tui npm globals, then offer an interactive rebuild.
#
# Usage: flake-update [checkout]
set -euo pipefail

if [[ $# -ge 1 && -f "${1}/flake.nix" ]]; then
  root=$1
  shift
else
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ ! -f "$root/flake.nix" ]]; then
  echo "flake-update: checkout not found: $root" >&2
  exit 1
fi
cd "$root"

# The Python heredocs use (?:\$\{[^}]*\}|[^}])*? to stay inside one Nix attrset.
# A plain [^}]*? stops early at the '}' in ${...} interpolation (e.g. the
# meltype rev or the opencode URL), so no hash/url line is ever matched.

read_gh_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN"
    return
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$GITHUB_TOKEN"
    return
  fi
  local f
  for f in "${HOME}/.config/gh/hosts.yml" "/run/agenix/gh-hosts.yml"; do
    if [[ -r "$f" ]]; then
      awk '
        /^[^ \t#]/ { in_gh = ($1 == "github.com:") }
        in_gh && /^[ \t]+oauth_token:/ {
          gsub(/["'\'']/, "", $2)
          print $2
          exit
        }
      ' "$f"
      return
    fi
  done
}

gh_token="$(read_gh_token || true)"
gh_curl() {
  if [[ -n "$gh_token" ]]; then
    curl -fsSL -H "Authorization: Bearer $gh_token" "$@"
  else
    curl -fsSL "$@"
  fi
}

# NixOS often has no python3 on PATH; prefer it when present, else nixpkgs.
py=(python3)
if ! command -v python3 >/dev/null 2>&1; then
  py=(nix shell nixpkgs#python3 --command python3)
fi

pkg_attr() {
  sed -n "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\";.*/\\1/p" "$root/pkgs/$1/default.nix" | head -n1
}

prefetch_hash() {
  nix store prefetch-file --json "$@" | jq -r '.hash'
}

echo "==> Checking .deb URLs (UniClipboard / Grok Bot / Orca IDE)"
uc_json="$(gh_curl https://api.github.com/repos/UniClipboard/UniClipboard/releases/latest)"
tag="$(printf '%s\n' "$uc_json" | jq -r '.tag_name // empty')"
if [[ -z "$tag" ]]; then
  echo "flake-update: could not parse UniClipboard latest tag" >&2
  exit 1
fi
uc_ver="${tag#v}"
uc_url="https://github.com/UniClipboard/UniClipboard/releases/download/v${uc_ver}/UniClipboard_${uc_ver}_amd64.deb"

grok_bot_url="$(
  curl -fsSL https://cursor.com/download/bot |
    sed -n 's/.*\(https:\/\/downloads\.cursor\.com\/grokbot\/stable\/[^"]*linux\/x64\/grok-bot_[^"]*_amd64\.deb\).*/\1/p' |
    head -n1
)"
if [[ -z "$grok_bot_url" ]]; then
  echo "flake-update: could not parse Grok Bot amd64 .deb URL" >&2
  exit 1
fi
grok_bot_ver="$(printf '%s\n' "$grok_bot_url" | sed -n 's/.*grok-bot_\([^_]*\)_amd64\.deb/\1/p')"
if [[ -z "$grok_bot_ver" ]]; then
  echo "flake-update: could not parse Grok Bot version from URL" >&2
  exit 1
fi

orca_json="$(gh_curl https://api.github.com/repos/stablyai/orca/releases/latest)"
orca_tag="$(printf '%s\n' "$orca_json" | jq -r '.tag_name // empty')"
if [[ -z "$orca_tag" ]]; then
  echo "flake-update: could not parse Orca IDE latest tag" >&2
  exit 1
fi
orca_ver="${orca_tag#v}"
orca_url="https://github.com/stablyai/orca/releases/download/v${orca_ver}/orca-ide_${orca_ver}_amd64.deb"

"${py[@]}" - "$root/flake.nix" "$uc_ver" "$uc_url" "$grok_bot_ver" "$grok_bot_url" "$orca_ver" "$orca_url" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
uc_ver, uc_url, grok_bot_ver, grok_bot_url, orca_ver, orca_url = sys.argv[2:8]
text = path.read_text()

replacements = [
    (r'(uniclipboardVersion\s*=\s*")[^"]*(";)', uc_ver, "uniclipboardVersion"),
    (
        r'(uniclipboard-deb\s*=\s*\{(?:\$\{[^}]*\}|[^}])*?url\s*=\s*")[^"]*(")',
        uc_url,
        "uniclipboard-deb url",
    ),
    (r'(grokBotVersion\s*=\s*")[^"]*(";)', grok_bot_ver, "grokBotVersion"),
    (
        r'(grok-bot-deb\s*=\s*\{(?:\$\{[^}]*\}|[^}])*?url\s*=\s*")[^"]*(")',
        grok_bot_url,
        "grok-bot-deb url",
    ),
    (r'(orcaIdeVersion\s*=\s*")[^"]*(";)', orca_ver, "orcaIdeVersion"),
    (
        r'(orca-ide-deb\s*=\s*\{(?:\$\{[^}]*\}|[^}])*?url\s*=\s*")[^"]*(")',
        orca_url,
        "orca-ide-deb url",
    ),
]

for pattern, value, label in replacements:
    text, n = re.subn(pattern, rf"\g<1>{value}\2", text, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"flake-update: expected one {label} (got {n})")

old = path.read_text()
if text != old:
    path.write_text(text)
    print(f"UniClipboard → {uc_ver}")
    print(f"Grok Bot → {grok_bot_ver}")
    print(f"Orca IDE → {orca_ver}")
else:
    print(f"UniClipboard already {uc_ver}")
    print(f"Grok Bot already {grok_bot_ver}")
    print(f"Orca IDE already {orca_ver}")
PY

echo "==> Checking custom pkgs/ (Meltype / Antigravity / wol-pc; JQuake pinned at 1.8.4)"

# --- Meltype ---
mel_cur="$(pkg_attr meltype version)"
mel_tag="$(gh_curl https://api.github.com/repos/yksr-melt/Meltype/releases/latest | jq -r '.tag_name // empty')"
mel_ver="${mel_tag#v}"
if [[ -z "$mel_ver" ]]; then
  echo "flake-update: could not parse Meltype latest release" >&2
  exit 1
fi
if [[ "$mel_ver" != "$mel_cur" ]]; then
  echo "Meltype: prefetching ${mel_cur} -> ${mel_ver}..."
  mel_src_hash="$(prefetch_hash --unpack "https://github.com/yksr-melt/Meltype/archive/refs/tags/v${mel_ver}.tar.gz")"
  mel_zip_hash="$(prefetch_hash "https://github.com/yksr-melt/Meltype/releases/download/v${mel_ver}/Meltype-${mel_ver}-linux.zip")"
  if [[ -z "$mel_src_hash" || -z "$mel_zip_hash" ]]; then
    echo "flake-update: failed to prefetch Meltype ${mel_ver}" >&2
    exit 1
  fi
  "${py[@]}" - "$root/pkgs/meltype/default.nix" "$mel_ver" "$mel_src_hash" "$mel_zip_hash" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
ver, src_hash, zip_hash = sys.argv[2:5]
t = p.read_text()
for pat, val, lbl in [
    (r'(  version\s*=\s*")[^"]*(";)', ver, "meltype version"),
    (r'(src\s*=\s*fetchFromGitHub\s*\{(?:\$\{[^}]*\}|[^}])*?hash\s*=\s*")[^"]*(";)', src_hash, "meltype src hash"),
    (r'(binaryZip\s*=\s*fetchurl\s*\{(?:\$\{[^}]*\}|[^}])*?hash\s*=\s*")[^"]*(";)', zip_hash, "meltype binaryZip hash"),
]:
    t, n = re.subn(pat, rf"\g<1>{val}\2", t, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"flake-update: expected one {lbl} (got {n})")
p.write_text(t)
print(f"Meltype → {ver}")
PY
else
  echo "Meltype already ${mel_ver}"
fi

# --- Antigravity ---
agy_cur="$(pkg_attr antigravity version)"
agy_meta="$(curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json)"
agy_ver="$(printf '%s\n' "$agy_meta" | jq -r '.version // empty')"
agy_url="$(printf '%s\n' "$agy_meta" | jq -r '.url // empty')"
if [[ -z "$agy_ver" || -z "$agy_url" ]]; then
  echo "flake-update: could not parse Antigravity manifest" >&2
  exit 1
fi
if [[ "$agy_ver" != "$agy_cur" ]]; then
  echo "Antigravity: prefetching ${agy_cur} -> ${agy_ver}..."
  agy_hash="$(prefetch_hash "$agy_url")"
  if [[ -z "$agy_hash" ]]; then
    echo "flake-update: failed to prefetch Antigravity ${agy_ver}" >&2
    exit 1
  fi
  "${py[@]}" - "$root/pkgs/antigravity/default.nix" "$agy_ver" "$agy_url" "$agy_hash" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
ver, url, h = sys.argv[2:5]
t = p.read_text()
for pat, val, lbl in [
    (r'(  version\s*=\s*")[^"]*(";)', ver, "antigravity version"),
    (r'(src\s*=\s*fetchurl\s*\{(?:\$\{[^}]*\}|[^}])*?url\s*=\s*")[^"]*(";)', url, "antigravity url"),
    (r'(src\s*=\s*fetchurl\s*\{(?:\$\{[^}]*\}|[^}])*?hash\s*=\s*")[^"]*(";)', h, "antigravity hash"),
]:
    t, n = re.subn(pat, rf"\g<1>{val}\2", t, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"flake-update: expected one {lbl} (got {n})")
p.write_text(t)
print(f"Antigravity → {ver}")
PY
else
  echo "Antigravity already ${agy_ver}"
fi

# --- wol-pc ---
wol_cur="$(pkg_attr wol-pc rev)"
wol_tip="$(git ls-remote https://github.com/mitac-31709/wol-pc.git HEAD | awk 'NR==1 {print $1}')"
if [[ -z "$wol_tip" ]]; then
  echo "flake-update: could not resolve wol-pc HEAD" >&2
  exit 1
fi
if [[ "$wol_tip" != "$wol_cur" ]]; then
  echo "wol-pc: prefetching ${wol_cur:0:7} -> ${wol_tip:0:7}..."
  wol_date="$(
    gh_curl "https://api.github.com/repos/mitac-31709/wol-pc/commits/${wol_tip}" 2>/dev/null |
      jq -r '.commit.committer.date[0:10] // empty' || true
  )"
  [[ -n "$wol_date" ]] || wol_date="$(date -u +%F)"
  wol_ver="0-unstable-${wol_date}"
  wol_hash="$(prefetch_hash --unpack "https://github.com/mitac-31709/wol-pc/archive/${wol_tip}.tar.gz")"
  if [[ -z "$wol_hash" ]]; then
    echo "flake-update: failed to prefetch wol-pc ${wol_tip}" >&2
    exit 1
  fi
  "${py[@]}" - "$root/pkgs/wol-pc/default.nix" "$wol_ver" "$wol_tip" "$wol_hash" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
ver, rev, h = sys.argv[2:5]
t = p.read_text()
for pat, val, lbl in [
    (r'(  version\s*=\s*")[^"]*(";)', ver, "wol-pc version"),
    (r'(src\s*=\s*fetchFromGitHub\s*\{(?:\$\{[^}]*\}|[^}])*?rev\s*=\s*")[^"]*(";)', rev, "wol-pc rev"),
    (r'(src\s*=\s*fetchFromGitHub\s*\{(?:\$\{[^}]*\}|[^}])*?hash\s*=\s*")[^"]*(";)', h, "wol-pc hash"),
]:
    t, n = re.subn(pat, rf"\g<1>{val}\2", t, count=1, flags=re.S)
    if n != 1:
        sys.exit(f"flake-update: expected one {lbl} (got {n})")
p.write_text(t)
print(f"wol-pc → {rev[:7]} ({ver})")
PY
else
  echo "wol-pc already ${wol_tip:0:7}"
fi

echo "==> Running nix flake update (all inputs including nixpkgs-cursor and bootvine)"
nix flake update

# --- Global npm CLI packages if locally installed (dsh / dsh-tui) ---
npm_global_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/npm-global"
if [[ ! -d "$npm_global_dir" && -d "${HOME}/.npm-global" ]]; then
  npm_global_dir="${HOME}/.npm-global"
fi
npm_global_modules="${npm_global_dir}/lib/node_modules"
dsh_pkgs=()
for pkg in "@deepseek-ai/dsh" "@deepseek-harness-tui/dsh-tui"; do
  if [[ -r "${npm_global_modules}/${pkg}/package.json" ]]; then
    dsh_pkgs+=("${pkg}@latest")
  fi
done
if ((${#dsh_pkgs[@]} > 0)); then
  npm_bin=""
  if [[ -x "${HOME}/.local/share/dsh/node22/bin/npm" ]]; then
    export PATH="${HOME}/.local/share/dsh/node22/bin:${PATH}"
    npm_bin="${HOME}/.local/share/dsh/node22/bin/npm"
  elif command -v npm >/dev/null 2>&1; then
    npm_bin="$(command -v npm)"
  fi
  if [[ -n "$npm_bin" ]]; then
    extra_npm_args=()
    if [[ -f "${npm_global_dir}/bin/dsh-tui" && ! -L "${npm_global_dir}/bin/dsh-tui" ]]; then
      # Preserve custom node22 wrapper scripts in npm-global/bin.
      extra_npm_args+=(--no-bin-links)
    fi
    echo "==> Updating global npm packages: ${dsh_pkgs[*]}"
    "$npm_bin" install -g --prefix "${npm_global_dir}" "${extra_npm_args[@]+"${extra_npm_args[@]}"}" "${dsh_pkgs[@]}"
  else
    echo "dsh-tui: npm not found; skipping npm global update"
  fi
else
  echo "==> dsh-tui: ${npm_global_dir} に未導入のためスキップ"
fi

echo "==> Refreshing update status"
check_cmd="${MITAC_FLAKE_UPDATE_CHECK:-$root/scripts/flake-update-check.sh}"
if [[ -x "$check_cmd" ]]; then
  "$check_cmd" "$root" || true
fi

echo ""
echo "==> Git status / diff summary"
git status -sb
git diff --stat -- flake.nix flake.lock pkgs/ || true

if [[ -t 0 ]]; then
  host="${MITAC_FLAKE_HOST:-$(hostname)}"
  case "$host" in
    vaio|chromebook) ;;
    *) host="chromebook" ;;
  esac
  hiragino_dir="${MITAC_HIRAGINO_DIR:-/home/mitac/.local/share/fonts/hiragino-otf}"
  impure_args=()
  if [[ -d "$hiragino_dir" ]]; then
    impure_args=(--impure)
  fi

  echo ""
  printf 'この変更で rebuild (sudo nixos-rebuild switch --flake %s#%s%s) を実行しますか？ [y/N]: ' \
    "$root" "$host" "${impure_args:+ ${impure_args[*]}}"
  IFS= read -r answer || answer=""
  case "$answer" in
    [yY]|[yY][eE][sS])
      sudo -v
      set +e
      sudo nixos-rebuild switch --flake "$root#$host" "${impure_args[@]+"${impure_args[@]}"}" |& nom
      rc="${PIPESTATUS[0]}"
      set -e
      if [[ -t 1 ]]; then
        printf '\033[0m\033]110\033\\\033]111\033\\\033]112\033\\'
      fi
      if [[ "$rc" -ne 0 ]]; then
        exit "$rc"
      fi
      ;;
    *)
      echo "rebuild はスキップしました。後で反映するには: rebuild"
      ;;
  esac
else
  echo "flake.lock / flake.nix / pkgs updated. Review, commit, then rebuild."
fi
