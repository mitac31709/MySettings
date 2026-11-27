#!/usr/bin/env bash
# Compare pinned .deb versions, custom pkgs/, installed npm globals (dsh-tui),
# and flake inputs (GitHub + git) to upstream tips.
# Writes $XDG_RUNTIME_DIR/flake-update-status for Colorshell (does not mutate the flake).
set -u

# Packaged command passes the checkout. A direct ./scripts run uses this tree.
if [[ $# -ge 1 && -f "${1}/flake.nix" ]]; then
  root=$1
  shift
else
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ ! -f "$root/flake.nix" ]]; then
  echo "flake-update-check: checkout not found: $root" >&2
  exit 1
fi
cd "$root"

status_file="${XDG_RUNTIME_DIR:-/tmp}/flake-update-status"
flake_nix="$root/flake.nix"
flake_lock="$root/flake.lock"
# FLAKE_CHECK_PY is the store copy. Fallback keeps ./scripts/... working.
flake_py="${FLAKE_CHECK_PY:-$root/scripts/flake-update-check-flake.py}"

# Records: icon<TAB>bar_label<TAB>tooltip_line
outdated=()
fetch_ok=1

note() {
  outdated+=("$1"$'\t'"$2"$'\t'"$3")
}

fail_fetch() {
  fetch_ok=0
  printf 'flake-update-check: %s\n' "$1" >&2
}

current_ver() {
  sed -n "s/.*${1}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$flake_nix" | head -n1
}

pkg_attr() {
  sed -n "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\";.*/\\1/p" "$root/pkgs/$1/default.nix" | head -n1
}

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
    curl -fsSL --max-time 20 -H "Authorization: Bearer $gh_token" "$@"
  else
    curl -fsSL --max-time 20 "$@"
  fi
}

py=(python3)
if ! command -v python3 >/dev/null 2>&1; then
  py=(nix shell nixpkgs#python3 --command python3)
fi

# --- UniClipboard (.deb) ---
uc_cur="$(current_ver uniclipboardVersion)"
if uc_json="$(gh_curl https://api.github.com/repos/UniClipboard/UniClipboard/releases/latest 2>/dev/null)"; then
  uc_ver="$(printf '%s\n' "$uc_json" | jq -r '.tag_name // empty' | sed 's/^v//')"
  if [[ -n "$uc_ver" && -n "$uc_cur" && "$uc_ver" != "$uc_cur" ]]; then
    note $'\uf0ea' "uc" "UniClipboard ${uc_cur}→${uc_ver}"
  fi
else
  fail_fetch "UniClipboard release fetch failed"
fi

# --- Grok Bot (.deb) ---
grok_cur="$(current_ver grokBotVersion)"
if grok_bot_url="$(
  curl -fsSL --max-time 20 https://cursor.com/download/bot 2>/dev/null |
    sed -n 's/.*\(https:\/\/downloads\.cursor\.com\/grokbot\/stable\/[^"]*linux\/x64\/grok-bot_[^"]*_amd64\.deb\).*/\1/p' |
    head -n1
)"; then
  grok_bot_ver="$(printf '%s\n' "$grok_bot_url" | sed -n 's/.*grok-bot_\([^_]*\)_amd64\.deb/\1/p')"
  if [[ -n "$grok_bot_ver" && -n "$grok_cur" && "$grok_bot_ver" != "$grok_cur" ]]; then
    note $'\U000f06a9' "grok" "Grok Bot ${grok_cur}→${grok_bot_ver}"
  fi
else
  fail_fetch "Grok Bot download page fetch failed"
fi

# --- Orca IDE (.deb) ---
orca_cur="$(current_ver orcaIdeVersion)"
if orca_json="$(gh_curl https://api.github.com/repos/stablyai/orca/releases/latest 2>/dev/null)"; then
  orca_ver="$(printf '%s\n' "$orca_json" | jq -r '.tag_name // empty' | sed 's/^v//')"
  if [[ -n "$orca_ver" && -n "$orca_cur" && "$orca_ver" != "$orca_cur" ]]; then
    note $'\uf121' "orca" "Orca IDE ${orca_cur}→${orca_ver}"
  fi
else
  fail_fetch "Orca IDE release fetch failed"
fi

# --- Custom pkgs/ (jquake stays pinned at 1.8.4) ---
mel_cur="$(pkg_attr meltype version)"
if mel_json="$(gh_curl https://api.github.com/repos/yksr-melt/Meltype/releases/latest 2>/dev/null)"; then
  mel_ver="$(printf '%s\n' "$mel_json" | jq -r '.tag_name // empty' | sed 's/^v//')"
  if [[ -n "$mel_ver" && -n "$mel_cur" && "$mel_ver" != "$mel_cur" ]]; then
    note $'\uf1ab' "melt" "Meltype ${mel_cur}→${mel_ver}"
  fi
else
  fail_fetch "Meltype release fetch failed"
fi

agy_cur="$(pkg_attr antigravity version)"
if agy_json="$(curl -fsSL --max-time 20 https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json 2>/dev/null)"; then
  agy_ver="$(printf '%s\n' "$agy_json" | jq -r '.version // empty')"
  if [[ -n "$agy_ver" && -n "$agy_cur" && "$agy_ver" != "$agy_cur" ]]; then
    note $'\uf135' "agy" "Antigravity ${agy_cur}→${agy_ver}"
  fi
else
  fail_fetch "Antigravity manifest fetch failed"
fi

wol_cur="$(pkg_attr wol-pc rev)"
if wol_tip="$(git ls-remote https://github.com/mitac-31709/wol-pc.git HEAD 2>/dev/null | awk 'NR==1 {print $1}')"; then
  if [[ -n "$wol_tip" && -n "$wol_cur" && "$wol_tip" != "$wol_cur" ]]; then
    note $'\uf011' "wol" "wol-pc ${wol_cur:0:7}→${wol_tip:0:7}"
  fi
else
  fail_fetch "wol-pc git ls-remote failed"
fi

# --- Global npm CLI packages if locally installed (dsh / dsh-tui) ---
npm_global_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/npm-global"
if [[ ! -d "$npm_global_dir" && -d "${HOME}/.npm-global" ]]; then
  npm_global_dir="${HOME}/.npm-global"
fi
npm_global_modules="${npm_global_dir}/lib/node_modules"
check_npm_global() {
  local pkg_name="$1" icon="$2" short="$3" label="$4"
  local pkg_json="${npm_global_modules}/${pkg_name}/package.json"
  [[ -r "$pkg_json" ]] || return 0
  local cur latest
  cur="$(jq -r '.version // empty' "$pkg_json" 2>/dev/null || true)"
  [[ -n "$cur" ]] || return 0
  if latest="$(curl -fsSL --max-time 20 "https://registry.npmjs.org/${pkg_name}/latest" 2>/dev/null | jq -r '.version // empty')"; then
    if [[ -n "$latest" && "$latest" != "$cur" ]]; then
      note "$icon" "$short" "${label} ${cur}→${latest}"
    fi
  else
    fail_fetch "${pkg_name} npm registry fetch failed"
  fi
}

check_npm_global "@deepseek-harness-tui/dsh-tui" $'\uf120' "dsh" "dsh-tui"
check_npm_global "@deepseek-ai/dsh" $'\uf120' "dshc" "@deepseek-ai/dsh"

# --- Flake inputs (+ nixpkgs / nixpkgs-cursor watched apps) ---
mapfile -t flake_notes < <("${py[@]}" "$flake_py" "$flake_lock" 2>/dev/null || true)

for line in "${flake_notes[@]+"${flake_notes[@]}"}"; do
  [[ -z "$line" ]] && continue
  if [[ "$line" == __FAIL__* ]]; then
    fail_fetch "Flake tip/compare failed for ${line#__FAIL__}"
  elif [[ "$line" == REC$'\t'* ]]; then
    IFS=$'\t' read -r _rec icon short tip <<<"$line"
    note "$icon" "$short" "$tip"
  fi
done

n="${#outdated[@]}"

if ((n == 0)); then
  if ((fetch_ok == 0)); then
    printf 'flake-update-check: no confirmed updates (some fetches failed)\n'
  else
    printf 'flake-update-check: up to date\n'
  fi
else
  printf 'flake-update-check: %d update(s)\n' "$n"
  for rec in "${outdated[@]}"; do
    IFS=$'\t' read -r icon short tip <<<"$rec"
    printf '  - %s %s  %s\n' "$icon" "$short" "$tip"
  done
fi

export FUC_N="$n"
export FUC_FETCH_OK="$fetch_ok"
export FUC_RECORDS="$(
  if ((n > 0)); then
    printf '%s\n' "${outdated[@]}"
  fi
)"

json_out="$(
  "${py[@]}" <<'PY'
import json, os

n = int(os.environ.get("FUC_N", "0"))
fetch_ok = os.environ.get("FUC_FETCH_OK", "1") == "1"
raw = os.environ.get("FUC_RECORDS", "")
recs = []
for line in raw.splitlines():
    parts = line.split("\t", 2)
    if len(parts) == 3:
        recs.append(tuple(parts))

# Always keep the refresh glyph visible (waybar / Colorshell bar button).
header = "\uf021"
max_icons = 10
if n == 0 or not recs:
    if fetch_ok:
        tip = "更新なし\n左クリックで flake-update / 右クリックで再確認"
    else:
        tip = "確認失敗（一部取得不可）\n左クリックで flake-update / 右クリックで再確認"
    obj = {
        "text": header,
        "class": "idle",
        "tooltip": tip,
        "count": 0,
        "fetch_ok": fetch_ok,
        "items": [],
    }
else:
    bar_glyphs = []
    seen = set()
    tips = []
    for icon, short, tip in recs:
        glyph = icon if icon else short
        if glyph not in seen:
            bar_glyphs.append(glyph)
            seen.add(glyph)
        tips.append(f"{icon} {tip}".strip() if icon else tip)

    if len(bar_glyphs) > max_icons:
        shown = bar_glyphs[:max_icons]
        shown.append(f"+{len(bar_glyphs) - max_icons}")
    else:
        shown = bar_glyphs

    obj = {
        "text": "\n".join([header, *shown]),
        "class": "available",
        "tooltip": "\n".join(tips) + "\n\n左クリックで flake-update / 右クリックで再確認",
        "count": len(recs),
        "fetch_ok": fetch_ok,
        "items": tips,
    }
print(json.dumps(obj, ensure_ascii=False))
PY
)"

prev_items=""
if [[ -s "$status_file" ]]; then
  prev_items="$(jq -rc '.items // [] | join("\n")' "$status_file" 2>/dev/null || true)"
fi

tmp="${status_file}.tmp.$$"
printf '%s\n' "$json_out" >"$tmp" && mv -f "$tmp" "$status_file"

# Notify Colorshell / desktop session when a background check discovers new updates.
if ((n > 0)) && [[ ! -t 1 ]] && command -v notify-send >/dev/null 2>&1; then
  cur_items="$(printf '%s\n' "$json_out" | jq -rc '.items // [] | join("\n")' 2>/dev/null || true)"
  if [[ -n "$cur_items" && "$cur_items" != "$prev_items" ]]; then
    summary="$(printf '%s\n' "$cur_items" | head -n 8)"
    if ((n > 8)); then
      summary+=$'\n'"…他 $((n - 8)) 件"
    fi
    notify-send \
      --app-name="Flake Update" \
      --icon="software-update-available-symbolic" \
      -h "string:x-canonical-private-synchronous:flake-update-check" \
      "更新が ${n} 件あります" \
      "$summary" >/dev/null 2>&1 || true
  fi
fi
exit 0
