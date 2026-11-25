#!/usr/bin/env bash
# Collect, aggregate, and redact local operation history into compact JSON
# for the `ops-advisor` AI agent skill. Pure shell + native CLI tools only.
set -euo pipefail

DAYS=7
REPO_PATH="${MITAC_REPO_PATH:-$HOME/MySettings}"
INCLUDE_CLIPBOARD=0
SELF_TEST=0

usage() {
  cat <<'EOF'
Usage: ops-advisor-collect [--days N] [--repo PATH] [--include-clipboard] [--self-test]

Options:
  --days N             Lookback window in days (default: 7)
  --repo PATH          Path to MySettings flake (default: ~/MySettings)
  --include-clipboard  Opt-in: include top repeated cliphist patterns (redacted)
  --self-test          Run deterministic self-checks against synthetic fixtures
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --days)
      [ "$#" -ge 2 ] || { printf 'error: --days requires an argument\n' >&2; exit 2; }
      DAYS="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { printf 'error: --repo requires an argument\n' >&2; exit 2; }
      REPO_PATH="$2"
      shift 2
      ;;
    --include-clipboard)
      INCLUDE_CLIPBOARD=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: --days must be a positive integer (got: %s)\n' "$DAYS" >&2
  exit 2
fi

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Keep transient DB copies under ~/.cache (excluded from restic backups).
mkdir -p "$XDG_CACHE_HOME"
TMPDIR_WORK="$(mktemp -d "${XDG_CACHE_HOME}/ops-advisor-tmp.XXXXXX")"
cleanup() {
  [ -n "${TMPDIR_WORK:-}" ] && rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT

NOW_EPOCH="${OPS_ADVISOR_NOW_EPOCH:-$(date -u +%s)}"
CUTOFF_EPOCH=$(( NOW_EPOCH - DAYS * 86400 ))
START_ISO="$(date -u -d "@${CUTOFF_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
END_ISO="$(date -u -d "@${NOW_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
CUTOFF_DAY="$(date -d "@${CUTOFF_EPOCH}" +%Y-%m-%d)"
CUTOFF_DAY_UTC="$(date -u -d "@${CUTOFF_EPOCH}" +%Y-%m-%d)"
CUTOFF_CHROME_US=$(( (CUTOFF_EPOCH + 11644473600) * 1000000 ))
CUTOFF_FF_US=$(( CUTOFF_EPOCH * 1000000 ))
HOST_NAME="$(uname -n 2>/dev/null || printf 'unknown')"

HAVE_SQLITE3=0
if command -v sqlite3 >/dev/null 2>&1; then
  HAVE_SQLITE3=1
fi

# Redact sensitive values across all string leaves in a JSON document.
# Done inside jq so JSON escaping is never corrupted.
redact_json() {
  jq --arg home "$HOME" '
    def redact_str:
      # Strip URL query/fragment first so userinfo redaction cannot break URL matching.
      gsub("(?<u>https?://[^[:space:]?#\"'\'']+)[?#][^[:space:]\"'\'']*" ; "\(.u)" ; "i")
      | gsub("(?<p>https?://)[^[:space:]@/\"'\'']+@" ; "\(.p)[REDACTED]@" ; "i")
      | gsub("gh[pousr]_[A-Za-z0-9_]{20,}" ; "[REDACTED_TOKEN]")
      | gsub("github_pat_[A-Za-z0-9_]{20,}" ; "[REDACTED_TOKEN]")
      | gsub("sk-[A-Za-z0-9_-]{16,}" ; "[REDACTED_TOKEN]")
      | gsub("AIza[0-9A-Za-z_-]{20,}" ; "[REDACTED_TOKEN]")
      | gsub("xox[baprs]-[0-9A-Za-z-]+" ; "[REDACTED_TOKEN]")
      | gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}" ; "[REDACTED_JWT]")
      | gsub("(?<scheme>Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+/=-]{8,}" ; "\(.scheme) [REDACTED]" ; "i")
      | gsub("(?<k>[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|AUTH|COOKIE|PRIVATE_KEY)[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)(?:[^[:space:]\"'\'';]+|\"[^\"]*\"|'\''[^'\'']*'\'')" ; "\(.k)[REDACTED]" ; "i")
      | gsub("(?<f>--?(?:password|passwd|pass|token|secret|api-key|apikey|auth|bearer|cookie|key)(?:[[:space:]]+|=))(?:[^[:space:]\"'\'';]+|\"[^\"]*\"|'\''[^'\'']*'\'')" ; "\(.f)[REDACTED]" ; "i")
      | gsub("\\b[0-9a-fA-F]{32,}\\b" ; "[REDACTED_HEX]")
      | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}" ; "[REDACTED_EMAIL]")
      | (if ($home | length) > 1 then gsub($home; "~") else . end);
    walk(if type == "string" then redact_str else . end)
  '
}

# Copy a live SQLite DB (plus optional WAL/SHM) into scratch so active writers are untouched.
copy_sqlite_db() {
  local src="$1"
  local dst="$2"
  cp -f "$src" "$dst"
  if [ -f "${src}-wal" ]; then
    cp -f "${src}-wal" "${dst}-wal" || true
  fi
  if [ -f "${src}-shm" ]; then
    cp -f "${src}-shm" "${dst}-shm" || true
  fi
}

# Run SQL from stdin against a scratch DB copy and always emit valid JSON.
sqlite_json() {
  local db="$1"
  local out=""
  if out="$(sqlite3 -json "$db" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '[]\n'
  fi
}

collect_activitywatch() {
  local aw_url="${AW_URL:-http://127.0.0.1:5600}"
  local buckets_json=""
  if ! buckets_json="$(curl -sf --max-time 5 "${aw_url}/api/0/buckets/" 2>/dev/null)"; then
    jq -n --arg url "$aw_url" '{status: "unreachable", url: $url}'
    return
  fi

  local win_bucket=""
  local afk_bucket=""
  win_bucket="$(jq -r --arg host "$HOST_NAME" '
    [to_entries[] | select(.value.type == "currentwindow")]
    | (map(select(.value.hostname == $host or (.key | endswith("_" + $host))))[0] // .[0])
    | .key // empty
  ' <<<"$buckets_json")"
  afk_bucket="$(jq -r --arg host "$HOST_NAME" '
    [to_entries[] | select(.value.type == "afkstatus")]
    | (map(select(.value.hostname == $host or (.key | endswith("_" + $host))))[0] // .[0])
    | .key // empty
  ' <<<"$buckets_json")"

  if [ -z "$win_bucket" ]; then
    jq -n '{status: "no_window_bucket"}'
    return
  fi

  local win_file="$TMPDIR_WORK/aw_window.json"
  local afk_file="$TMPDIR_WORK/aw_afk.json"
  if ! curl -sf --max-time 10 --get \
      --data-urlencode "start=${START_ISO}" \
      --data-urlencode "end=${END_ISO}" \
      --data-urlencode "limit=20000" \
      "${aw_url}/api/0/buckets/${win_bucket}/events" >"$win_file" 2>/dev/null; then
    jq -n --arg bucket "$win_bucket" '{status: "query_failed", bucket: $bucket}'
    return
  fi

  if [ -n "$afk_bucket" ]; then
    if ! curl -sf --max-time 10 --get \
        --data-urlencode "start=${START_ISO}" \
        --data-urlencode "end=${END_ISO}" \
        --data-urlencode "limit=20000" \
        "${aw_url}/api/0/buckets/${afk_bucket}/events" >"$afk_file" 2>/dev/null; then
      printf '[]\n' >"$afk_file"
    fi
  else
    printf '[]\n' >"$afk_file"
  fi

  jq -n \
    --arg win_bucket "$win_bucket" \
    --arg afk_bucket "$afk_bucket" \
    --slurpfile win_raw "$win_file" \
    --slurpfile afk_raw "$afk_file" '
    ($win_raw[0] // []) as $events
    | ($afk_raw[0] // []) as $afk_events
    | ($events | sort_by(.timestamp)) as $sorted
    | {
        status: "ok",
        window_bucket: $win_bucket,
        event_count: ($events | length),
        total_tracked_hours: ((([$events[].duration] | add // 0) / 3600 * 100 | round) / 100),
        afk_summary: (
          $afk_events
          | group_by(.data.status // "unknown")
          | map({
              key: (.[0].data.status // "unknown"),
              value: ((([.[].duration] | add // 0) / 3600 * 100 | round) / 100)
            })
          | from_entries
        ),
        top_apps: (
          $events
          | group_by(.data.app // "unknown")
          | map({
              app: (.[0].data.app // "unknown"),
              minutes: ((([.[].duration] | add // 0) / 60 * 10 | round) / 10),
              events: length,
              avg_sec: ((([.[].duration] | add // 0) / (length | if . == 0 then 1 else . end)) | round)
            })
          | sort_by(-.minutes)
          | .[:15]
        ),
        top_titles: (
          $events
          | map({
              app: (.data.app // "unknown"),
              title: ((.data.title // "") | gsub("[[:space:]]+"; " ") | .[0:100]),
              duration: (.duration // 0)
            })
          | group_by([.app, .title])
          | map({
              app: .[0].app,
              title: .[0].title,
              minutes: ((([.[].duration] | add // 0) / 60 * 10 | round) / 10),
              events: length
            })
          | sort_by(-.minutes)
          | .[:20]
        ),
        app_switch_pairs: (
          $sorted
          | map(select((.duration // 0) >= 0.5) | (.data.app // "unknown"))
          | reduce .[] as $a (
              {prev: null, pairs: []};
              if .prev == null or .prev == $a then .prev = $a
              else .pairs += [([.prev, $a] | sort | join(" <-> "))] | .prev = $a
              end
            )
          | .pairs
          | group_by(.)
          | map({pair: .[0], switches: length})
          | sort_by(-.switches)
          | .[:15]
        )
      }
  '
}

collect_whatpulse() {
  local db=""
  local -a candidates=()
  [ -n "${WHATPULSE_DB:-}" ] && candidates+=("$WHATPULSE_DB")
  candidates+=(
    "${XDG_CONFIG_HOME}/whatpulse/whatpulse.db"
    "${XDG_DATA_HOME}/whatpulse/whatpulse.db"
    "${HOME}/.whatpulse/whatpulse.db"
  )

  local p=""
  for p in "${candidates[@]}"; do
    if [ -f "$p" ]; then
      db="$p"
      break
    fi
  done

  if [ -z "$db" ]; then
    # Fallback: probe local Client API if enabled on default port.
    local api_url="${WHATPULSE_API_URL:-http://127.0.0.1:3490}"
    local api_json=""
    if api_json="$(curl -sf --max-time 1 "${api_url}/v1/all-stats" 2>/dev/null)"; then
      jq -n --arg url "$api_url" --argjson stats "$api_json" \
        '{status: "client_api_only", url: $url, stats: $stats}'
      return
    fi
    jq -n --argjson checked "$(printf '%s\n' "${candidates[@]}" | jq -R . | jq -s .)" \
      '{status: "not_found", checked_paths: $checked, hint: "Launch whatpulse once to initialize whatpulse.db"}'
    return
  fi

  if [ "$HAVE_SQLITE3" -ne 1 ]; then
    jq -n --arg db "$db" '{status: "missing_sqlite3", db_path: $db}'
    return
  fi

  local work_db="$TMPDIR_WORK/whatpulse.db"
  copy_sqlite_db "$db" "$work_db"

  local tables=""
  tables="$(sqlite3 "$work_db" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null || true)"
  has_table() {
    printf '%s\n' "$tables" | grep -Fxq "$1"
  }

  local totals_json='{}'
  local per_app_json='[]'
  local combos_json='[]'
  local nav_keys_json='[]'
  local websites_json='[]'

  if has_table "input_per_application"; then
    totals_json="$(sqlite_json "$work_db" <<SQL | jq '.[0] // {}'
SELECT
  COALESCE(SUM(keys), 0) AS keys,
  COALESCE(SUM(clicks), 0) AS clicks,
  COALESCE(SUM(scrolls), 0) AS scrolls,
  ROUND(COALESCE(SUM(distance_inches), 0) * 0.0254, 1) AS distance_m
FROM input_per_application
WHERE day != '0000-00-00' AND day >= '${CUTOFF_DAY}';
SQL
)"
    if has_table "applications"; then
      per_app_json="$(sqlite_json "$work_db" <<SQL | jq '
        map(. + {
          clicks_per_1k_keys: (if (.keys // 0) > 0 then (((.clicks // 0) * 1000 / .keys) | round) else null end)
        })
      '
SELECT
  COALESCE(NULLIF(a.name, ''), i.path) AS app,
  SUM(i.keys) AS keys,
  SUM(i.clicks) AS clicks,
  SUM(i.scrolls) AS scrolls,
  ROUND(SUM(i.distance_inches) * 0.0254, 1) AS distance_m
FROM input_per_application i
LEFT JOIN applications a ON a.path = i.path
WHERE i.day != '0000-00-00' AND i.day >= '${CUTOFF_DAY}'
GROUP BY i.path
ORDER BY (SUM(i.clicks) * 5 + SUM(i.keys)) DESC
LIMIT 15;
SQL
)"
    fi
  fi

  # Decode WhatPulse Qt key codes (ASCII 32..126 + common special keys) inside jq.
  # shellcheck disable=SC2016
  local qt_decode_jq='
    def qt_key($n):
      if ($n >= 32 and $n <= 126) then ([$n] | implode)
      elif $n == 16777216 then "Escape"
      elif $n == 16777217 then "Tab"
      elif $n == 16777218 then "Backtab"
      elif $n == 16777219 then "Backspace"
      elif $n == 16777220 then "Return"
      elif $n == 16777221 then "Enter"
      elif $n == 16777222 then "Insert"
      elif $n == 16777223 then "Delete"
      elif $n == 16777232 then "Home"
      elif $n == 16777233 then "End"
      elif $n == 16777234 then "Left"
      elif $n == 16777235 then "Up"
      elif $n == 16777236 then "Right"
      elif $n == 16777237 then "Down"
      elif $n == 16777238 then "PageUp"
      elif $n == 16777239 then "PageDown"
      elif $n == 16777248 then "Shift"
      elif $n == 16777249 then "Ctrl"
      elif $n == 16777250 then "Super"
      elif $n == 16777251 then "Alt"
      elif $n == 16777252 then "CapsLock"
      elif ($n >= 16777264 and $n <= 16777275) then ("F" + (($n - 16777263) | tostring))
      else ("Key#" + ($n | tostring))
      end;
    def decode_combo:
      split(",")
      | map(
          if . == "control" or . == "ctrl" then "Ctrl"
          elif . == "shift" then "Shift"
          elif . == "alt" or . == "option" then "Alt"
          elif . == "meta" or . == "command" or . == "super" then "Super"
          elif test("^[0-9]+$") then qt_key(tonumber)
          else .
          end
        )
      | join("+");
  '

  if has_table "keycombo_frequency_application" && has_table "applications"; then
    combos_json="$(sqlite_json "$work_db" <<SQL | jq "${qt_decode_jq} map(.combo = (.combo | tostring | decode_combo))"
SELECT
  COALESCE(NULLIF(a.name, ''), k.path) AS app,
  k.combo AS combo,
  SUM(k.count) AS count
FROM keycombo_frequency_application k
LEFT JOIN applications a ON a.path = k.path
WHERE k.day != '0000-00-00' AND k.day >= '${CUTOFF_DAY}'
GROUP BY k.path, k.combo
ORDER BY count DESC
LIMIT 25;
SQL
)"
  elif has_table "keycombo_frequency"; then
    combos_json="$(sqlite_json "$work_db" <<SQL | jq "${qt_decode_jq} map(.combo = (.combo | tostring | decode_combo))"
SELECT
  combo,
  SUM(count) AS count
FROM keycombo_frequency
WHERE day != '0000-00-00' AND day >= '${CUTOFF_DAY}'
GROUP BY combo
ORDER BY count DESC
LIMIT 25;
SQL
)"
  fi

  if has_table "keypress_frequency_application" && has_table "applications"; then
    nav_keys_json="$(sqlite_json "$work_db" <<SQL | jq "${qt_decode_jq} map({app, key: qt_key(.key | tonumber), count})"
SELECT
  COALESCE(NULLIF(a.name, ''), k.path) AS app,
  k.key AS key,
  SUM(k.count) AS count
FROM keypress_frequency_application k
LEFT JOIN applications a ON a.path = k.path
WHERE k.day != '0000-00-00'
  AND k.day >= '${CUTOFF_DAY}'
  AND k.key IN (16777216,16777217,16777219,16777223,16777232,16777233,16777234,16777235,16777236,16777237,16777238,16777239)
GROUP BY k.path, k.key
ORDER BY count DESC
LIMIT 20;
SQL
)"
  fi

  if has_table "website_time_series" && has_table "website_domains"; then
    websites_json="$(sqlite_json "$work_db" <<SQL
SELECT
  d.domain AS domain,
  ROUND(SUM(w.active_seconds) / 60.0, 1) AS minutes,
  SUM(w.key_count) AS keys,
  SUM(w.click_count) AS clicks
FROM website_time_series w
JOIN website_domains d ON d.id = w.domain_id
WHERE w.day_utc != '0000-00-00' AND w.day_utc >= '${CUTOFF_DAY_UTC}'
GROUP BY w.domain_id
ORDER BY SUM(w.active_seconds) DESC
LIMIT 15;
SQL
)"
  fi

  jq -n \
    --arg db "$db" \
    --argjson totals "$totals_json" \
    --argjson input_per_app "$per_app_json" \
    --argjson top_keycombos "$combos_json" \
    --argjson nav_edit_keys_per_app "$nav_keys_json" \
    --argjson top_websites "$websites_json" '
    {
      status: "ok",
      db_path: $db,
      totals: $totals,
      input_per_app: $input_per_app,
      top_keycombos: $top_keycombos,
      nav_edit_keys_per_app: $nav_edit_keys_per_app,
      top_websites: $top_websites
    }
  '
}

collect_bash_history() {
  local hist="${BASH_HISTFILE:-${XDG_STATE_HOME}/bash/history}"
  if [ ! -f "$hist" ]; then
    jq -n --arg path "$hist" '{status: "not_found", path: $path}'
    return
  fi

  local cmds_file="$TMPDIR_WORK/bash_cmds.txt"
  local has_ts=0
  if grep -qE '^#[0-9]{9,11}$' "$hist"; then
    has_ts=1
    awk -v cutoff="$CUTOFF_EPOCH" '
      /^#[0-9]{9,11}$/ { ts = substr($0, 2) + 0; next }
      ts >= cutoff {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/[[:space:]]+/, " ")
        if (length($0) > 0) print
      }
    ' "$hist" >"$cmds_file"
  else
    tail -n 2000 "$hist" | awk '
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/[[:space:]]+/, " ")
        if (length($0) > 0) print
      }
    ' >"$cmds_file"
  fi

  local total_cmds=0
  total_cmds="$(wc -l <"$cmds_file" | tr -d ' ')"

  local top_cmds='[]'
  local top_prefixes='[]'
  local long_cmds='[]'
  local bigrams='[]'

  if [ "$total_cmds" -gt 0 ]; then
    top_cmds="$(sort "$cmds_file" | uniq -c | sort -nr | head -n 20 \
      | awk '{ c=$1; $1=""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0 }' \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), command: (.[1:] | join("\t") | .[0:120])})')"

    top_prefixes="$(awk '
      {
        if (NF >= 2 && $2 !~ /^-/) print $1 " " $2
        else print $1
      }
    ' "$cmds_file" | sort | uniq -c | sort -nr | head -n 20 \
      | awk '{ c=$1; $1=""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0 }' \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), prefix: (.[1:] | join("\t"))})')"

    long_cmds="$(awk 'length($0) >= 30' "$cmds_file" | sort | uniq -c | sort -nr \
      | awk '$1 >= 2 { c=$1; $1=""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0 }' | head -n 15 \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), command: (.[1:] | join("\t") | .[0:140])})')"

    bigrams="$(awk '
      NR > 1 && prev != $0 { print prev "  ->  " $0 }
      { prev = $0 }
    ' "$cmds_file" | sort | uniq -c | sort -nr \
      | awk '$1 >= 2 { c=$1; $1=""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0 }' | head -n 15 \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), sequence: (.[1:] | join("\t") | .[0:160])})')"
  fi

  jq -n \
    --arg path "$hist" \
    --argjson has_timestamps "$([ "$has_ts" -eq 1 ] && printf true || printf false)" \
    --argjson total_commands "$total_cmds" \
    --argjson top_commands "$top_cmds" \
    --argjson top_prefixes "$top_prefixes" \
    --argjson long_repeated_commands "$long_cmds" \
    --argjson repeated_sequences "$bigrams" '
    {
      status: "ok",
      path: $path,
      has_timestamps: $has_timestamps,
      window_note: (if $has_timestamps then "filtered_by_days" else "no_HISTTIMEFORMAT_used_recent_2000" end),
      total_commands: $total_commands,
      top_commands: $top_commands,
      top_prefixes: $top_prefixes,
      long_repeated_commands: $long_repeated_commands,
      repeated_sequences: $repeated_sequences
    }
  '
}

collect_vivaldi() {
  local hist="${VIVALDI_HISTORY:-${XDG_CONFIG_HOME}/vivaldi/Default/History}"
  if [ ! -f "$hist" ]; then
    jq -n --arg path "$hist" '{status: "not_found", path: $path}'
    return
  fi
  if [ "$HAVE_SQLITE3" -ne 1 ]; then
    jq -n --arg path "$hist" '{status: "missing_sqlite3", path: $path}'
    return
  fi

  local work_db="$TMPDIR_WORK/vivaldi.sqlite"
  copy_sqlite_db "$hist" "$work_db"

  local rows_file="$TMPDIR_WORK/vivaldi_rows.json"
  sqlite_json "$work_db" >"$rows_file" <<SQL
SELECT
  u.url AS url,
  CASE WHEN (v.transition & 255) = 1 THEN 1 ELSE 0 END AS is_typed
FROM visits v
JOIN urls u ON u.id = v.url
WHERE v.visit_time >= ${CUTOFF_CHROME_US}
  AND u.url LIKE 'http%'
LIMIT 20000;
SQL

  jq -n --arg path "$hist" --slurpfile rows "$rows_file" '
    ($rows[0] // []) as $r
    | ($r | map(
        (.url | capture("^https?://(?<host>[^/?#:]+)(?::[0-9]+)?(?<path>/[^?#]*)?") // null) as $m
        | select($m != null)
        | {
            host: ($m.host | ascii_downcase),
            short_path: (
              $m.host + (
                ($m.path // "")
                | split("/")
                | map(select(length > 0))
                | .[:2]
                | if length > 0 then "/" + join("/") else "" end
              )
            ),
            is_typed: (.is_typed // 0)
          }
      )) as $parsed
    | {
        status: "ok",
        path: $path,
        visits_in_window: ($parsed | length),
        top_domains: (
          $parsed
          | group_by(.host)
          | map({
              domain: .[0].host,
              visits: length,
              typed_visits: ([.[].is_typed] | add // 0)
            })
          | sort_by(-.visits)
          | .[:20]
        ),
        top_paths: (
          $parsed
          | group_by(.short_path)
          | map({
              path: .[0].short_path,
              visits: length
            })
          | sort_by(-.visits)
          | .[:20]
        )
      }
  '
}

collect_firefox() {
  local places="${FIREFOX_PLACES:-}"
  if [ -z "$places" ]; then
    local base=""
    for base in "${XDG_CONFIG_HOME}/mozilla/firefox" "${HOME}/.mozilla/firefox"; do
      if [ -d "$base" ]; then
        places="$(find "$base" -maxdepth 2 -name 'places.sqlite' -printf '%T@ %p\n' 2>/dev/null \
          | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
        [ -n "$places" ] && break
      fi
    done
  fi

  if [ -z "$places" ] || [ ! -f "$places" ]; then
    jq -n '{status: "not_found"}'
    return
  fi
  if [ "$HAVE_SQLITE3" -ne 1 ]; then
    jq -n --arg path "$places" '{status: "missing_sqlite3", path: $path}'
    return
  fi

  local work_db="$TMPDIR_WORK/firefox.sqlite"
  copy_sqlite_db "$places" "$work_db"

  local rows_file="$TMPDIR_WORK/firefox_rows.json"
  sqlite_json "$work_db" >"$rows_file" <<SQL
SELECT p.url AS url
FROM moz_historyvisits v
JOIN moz_places p ON p.id = v.place_id
WHERE v.visit_date >= ${CUTOFF_FF_US}
  AND p.url LIKE 'http%'
LIMIT 10000;
SQL

  jq -n --arg path "$places" --slurpfile rows "$rows_file" '
    ($rows[0] // []) as $r
    | ($r | map(
        (.url | capture("^https?://(?<host>[^/?#:]+)") // null) as $m
        | select($m != null)
        | ($m.host | ascii_downcase)
      )) as $hosts
    | {
        status: "ok",
        path: $path,
        visits_in_window: ($hosts | length),
        top_domains: (
          $hosts
          | group_by(.)
          | map({domain: .[0], visits: length})
          | sort_by(-.visits)
          | .[:10]
        )
      }
  '
}

collect_rofi() {
  local hist="${ROFI_HISTORY:-${XDG_CACHE_HOME}/rofi-entry-history.txt}"
  if [ ! -f "$hist" ]; then
    jq -n --arg path "$hist" '{status: "not_found", path: $path}'
    return
  fi

  local entries='[]'
  entries="$(awk '
    NF > 0 {
      if ($1 ~ /^[0-9]+$/ && NF >= 2) {
        c = $1; $1 = ""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0
      } else {
        printf "1\t%s\n", $0
      }
    }
  ' "$hist" | sort -t$'\t' -k1,1nr | head -n 15 \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), entry: (.[1:] | join("\t"))})')"

  jq -n --arg path "$hist" --argjson top_entries "$entries" \
    '{status: "ok", path: $path, top_entries: $top_entries}'
}

collect_recently_used() {
  local xbel="${RECENTLY_USED_XBEL:-${XDG_DATA_HOME}/recently-used.xbel}"
  if [ ! -f "$xbel" ]; then
    jq -n --arg path "$xbel" '{status: "not_found", path: $path}'
    return
  fi

  local parsed_file="$TMPDIR_WORK/xbel_parsed.tsv"
  awk -v cutoff="$START_ISO" '
    /<bookmark[[:space:]]/ {
      href = ""; visited = ""; app = ""
      if (match($0, /href="file:\/\/([^"]+)"/, m)) href = m[1]
      if (match($0, /visited="([^"]+)"/, m)) visited = m[1]
      in_bm = (href != "" && visited >= cutoff)
      next
    }
    in_bm && /<bookmark:application / {
      if (app == "" && match($0, /name="([^"]+)"/, m)) app = m[1]
      next
    }
    in_bm && /<\/bookmark>/ {
      # Extract parent directory and file extension only (avoid leaking filenames).
      dir = href
      sub(/\/[^\/]*$/, "", dir)
      base = href
      sub(/^.*\//, "", base)
      ext = ""
      if (match(base, /\.([A-Za-z0-9_-]{1,12})$/, m)) ext = tolower(m[1])
      printf "%s\t%s\t%s\n", dir, ext, (app != "" ? app : "unknown")
      in_bm = 0
    }
  ' "$xbel" >"$parsed_file"

  jq -R -s --arg path "$xbel" '
    (split("\n") | map(select(length > 0) | split("\t") | {dir: .[0], ext: .[1], app: .[2]})) as $rows
    | {
        status: "ok",
        path: $path,
        entries_in_window: ($rows | length),
        top_directories: (
          $rows | group_by(.dir) | map({dir: .[0].dir, count: length}) | sort_by(-.count) | .[:12]
        ),
        top_extensions: (
          $rows | map(select(.ext != "")) | group_by(.ext) | map({ext: .[0].ext, count: length}) | sort_by(-.count) | .[:10]
        ),
        top_apps: (
          $rows | group_by(.app) | map({app: .[0].app, count: length}) | sort_by(-.count) | .[:10]
        )
      }
  ' <"$parsed_file"
}

collect_meltype() {
  local dir="${MELTYPE_DIR:-${XDG_DATA_HOME}/Meltype}"
  if [ ! -d "$dir" ]; then
    jq -n --arg dir "$dir" '{status: "not_found", dir: $dir}'
    return
  fi

  local conv_count=0
  local phrase_count=0
  local app_rules_count=0
  local disabled_apps='[]'
  if [ -f "$dir/conversions.json" ]; then
    conv_count="$(jq 'if type == "object" or type == "array" then length else 0 end' "$dir/conversions.json" 2>/dev/null || printf '0')"
  fi
  if [ -f "$dir/phrases.txt" ]; then
    phrase_count="$(wc -l <"$dir/phrases.txt" | tr -d ' ')"
  fi
  if [ -f "$dir/config.json" ]; then
    app_rules_count="$(jq '(.AppRules // []) | length' "$dir/config.json" 2>/dev/null || printf '0')"
    disabled_apps="$(jq '[(.AppRules // [])[] | select(.Enabled == false) | .Process]' "$dir/config.json" 2>/dev/null || printf '[]')"
  fi

  jq -n \
    --argjson learned_conversions "$conv_count" \
    --argjson phrases_lines "$phrase_count" \
    --argjson app_rules_count "$app_rules_count" \
    --argjson disabled_apps "$disabled_apps" \
    '{status: "ok", learned_conversions: $learned_conversions, phrases_lines: $phrases_lines, app_rules_count: $app_rules_count, disabled_apps: $disabled_apps}'
}

collect_ai_agents() {
  local opencode_prompts=0
  local hermes_hist=0
  local codex_threads=0
  local oc_file="${XDG_STATE_HOME}/opencode/prompt-history.jsonl"
  local hm_file="${XDG_DATA_HOME}/hermes/.hermes_history"
  local cx_db="${XDG_CONFIG_HOME}/codex/thread_history_1.sqlite"

  [ -f "$oc_file" ] && opencode_prompts="$(wc -l <"$oc_file" | tr -d ' ')"
  [ -f "$hm_file" ] && hermes_hist="$(wc -l <"$hm_file" | tr -d ' ')"
  if [ -f "$cx_db" ] && [ "$HAVE_SQLITE3" -eq 1 ]; then
    local cx_copy="$TMPDIR_WORK/codex.sqlite"
    copy_sqlite_db "$cx_db" "$cx_copy"
    codex_threads="$(sqlite3 "$cx_copy" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || printf '0')"
  fi

  jq -n \
    --argjson opencode_prompt_lines "$opencode_prompts" \
    --argjson hermes_history_lines "$hermes_hist" \
    --argjson codex_db_tables "$codex_threads" \
    --argjson t3_present "$([ -d "${XDG_DATA_HOME}/t3" ] && printf true || printf false)" \
    --argjson claude_present "$([ -d "${XDG_CONFIG_HOME}/claude" ] && printf true || printf false)" \
    '{
      status: "ok",
      opencode_prompt_lines: $opencode_prompt_lines,
      hermes_history_lines: $hermes_history_lines,
      codex_db_tables: $codex_db_tables,
      t3_present: $t3_present,
      claude_present: $claude_present
    }'
}

collect_clipboard() {
  if [ "$INCLUDE_CLIPBOARD" -ne 1 ]; then
    jq -n '{status: "disabled_by_default", hint: "Pass --include-clipboard to opt in"}'
    return
  fi
  if ! command -v cliphist >/dev/null 2>&1; then
    jq -n '{status: "cliphist_not_found"}'
    return
  fi

  local clip_json='[]'
  clip_json="$(cliphist list 2>/dev/null \
    | sed -E 's/^[0-9]+\t//' \
    | awk 'length($0) >= 4 && length($0) <= 120 && $0 !~ /^\[\[ binary data/' \
    | sort | uniq -c | sort -nr \
    | awk '$1 >= 2 { c=$1; $1=""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", c, $0 }' \
    | head -n 10 \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {count: (.[0] | tonumber), snippet: (.[1:] | join("\t"))})')"

  jq -n --argjson repeated_snippets "$clip_json" '{status: "ok", repeated_snippets: $repeated_snippets}'
}

collect_current_config() {
  local cheatsheet='[]'
  local hypr_binds='[]'
  local aliases='[]'
  local shell_funcs='[]'
  local keyd_lines='[]'

  if [ -f "${REPO_PATH}/home/hyprland.nix" ]; then
    cheatsheet="$(awk '
      /cheatsheetEntries =/ { in_cs = 1; next }
      in_cs && /^[[:space:]]*\];/ { in_cs = 0 }
      in_cs && /section[[:space:]]*=/ { sec = $0; sub(/.*section[[:space:]]*=[[:space:]]*"/, "", sec); sub(/".*/, "", sec) }
      in_cs && /label[[:space:]]*=/ { lbl = $0; sub(/.*label[[:space:]]*=[[:space:]]*"/, "", lbl); sub(/".*/, "", lbl) }
      in_cs && /keys[[:space:]]*=/ { keys = $0; sub(/.*keys[[:space:]]*=[[:space:]]*"/, "", keys); sub(/".*/, "", keys) }
      in_cs && /run[[:space:]]*=/ { run = $0; sub(/.*run[[:space:]]*=[[:space:]]*"/, "", run); sub(/".*/, "", run) }
      in_cs && /\}/ {
        if (lbl != "") {
          trigger = (keys != "" ? keys : run)
          printf "%s | %s | %s\n", sec, trigger, lbl
          sec = ""; lbl = ""; keys = ""; run = ""
        }
      }
    ' "${REPO_PATH}/home/hyprland.nix" \
      | jq -R -s 'split("\n") | map(select(length > 0))')"

    hypr_binds="$(rg -N 'hl\.bind[a-z]*\(' "${REPO_PATH}/home/hyprland.nix" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//' | head -n 120 \
      | jq -R -s 'split("\n") | map(select(length > 0))')"
  fi

  if [ -f "${REPO_PATH}/home/shell.nix" ]; then
    aliases="$(awk '
      /shellAliases = \{/ { in_a = 1; next }
      in_a && /^[[:space:]]*\};/ { in_a = 0 }
      in_a && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        print line
      }
    ' "${REPO_PATH}/home/shell.nix" | jq -R -s 'split("\n") | map(select(length > 0))')"

    shell_funcs="$(rg -No '^[[:space:]]*([A-Za-z0-9_-]+)\(\)[[:space:]]*\{' "${REPO_PATH}/home/shell.nix" 2>/dev/null \
      | sed -E 's/^[[:space:]]*//; s/\(\).*//' \
      | jq -R -s 'split("\n") | map(select(length > 0))')"
  fi

  local keyd_files=()
  [ -f "${REPO_PATH}/modules/nixos/laptop/input.nix" ] && keyd_files+=("${REPO_PATH}/modules/nixos/laptop/input.nix")
  [ -f "${REPO_PATH}/modules/nixos/chromebook/input.nix" ] && keyd_files+=("${REPO_PATH}/modules/nixos/chromebook/input.nix")
  if [ "${#keyd_files[@]}" -gt 0 ]; then
    keyd_lines="$(awk '
      /extraConfig = '\'''\''/ { in_k = 1; next }
      in_k && /'\'''\'';/ { in_k = 0 }
      in_k && !/^[[:space:]]*#/ && NF > 0 {
        sub(/^[[:space:]]+/, "")
        print
      }
    ' "${keyd_files[@]}" | head -n 80 | jq -R -s 'split("\n") | map(select(length > 0))')"
  fi

  local tools_json='{}'
  local tool=""
  local -a check_tools=(
    fzf zoxide atuin tmux yazi rg fd bat rofi cliphist whatpulse awatcher
    screenpipe qalc lazygit jq eza direnv starship nvim ghostty
  )
  for tool in "${check_tools[@]}"; do
    local present=false
    command -v "$tool" >/dev/null 2>&1 && present=true
    tools_json="$(jq --arg k "$tool" --argjson v "$present" '. + {($k): $v}' <<<"$tools_json")"
  done

  jq -n \
    --arg repo_path "$REPO_PATH" \
    --argjson cheatsheet "$cheatsheet" \
    --argjson hypr_binds "$hypr_binds" \
    --argjson shell_aliases "$aliases" \
    --argjson shell_functions "$shell_funcs" \
    --argjson keyd_mappings "$keyd_lines" \
    --argjson installed_tools "$tools_json" '
    {
      repo_path: $repo_path,
      cheatsheet_count: ($cheatsheet | length),
      cheatsheet: $cheatsheet,
      hypr_binds_count: ($hypr_binds | length),
      hypr_binds: $hypr_binds,
      shell_aliases: $shell_aliases,
      shell_functions: $shell_functions,
      keyd_mappings: $keyd_mappings,
      installed_tools: $installed_tools
    }
  '
}

collect_feedback() {
  local fb="${OPS_ADVISOR_FEEDBACK:-${XDG_STATE_HOME}/ops-advisor/feedback.json}"
  if [ -f "$fb" ] && jq -e . "$fb" >/dev/null 2>&1; then
    cat "$fb"
  else
    jq -n '{adopted: [], dismissed: []}'
  fi
}

run_collect() {
  local aw wp bh viv ff rf ru mt ai cb cfg fb
  aw="$(collect_activitywatch)"
  wp="$(collect_whatpulse)"
  bh="$(collect_bash_history)"
  viv="$(collect_vivaldi)"
  ff="$(collect_firefox)"
  rf="$(collect_rofi)"
  ru="$(collect_recently_used)"
  mt="$(collect_meltype)"
  ai="$(collect_ai_agents)"
  cb="$(collect_clipboard)"
  cfg="$(collect_current_config)"
  fb="$(collect_feedback)"

  jq -n \
    --arg generated_at "$END_ISO" \
    --arg window_start "$START_ISO" \
    --arg window_end "$END_ISO" \
    --arg host "$HOST_NAME" \
    --argjson days "$DAYS" \
    --argjson activitywatch "$aw" \
    --argjson whatpulse "$wp" \
    --argjson bash_history "$bh" \
    --argjson vivaldi "$viv" \
    --argjson firefox "$ff" \
    --argjson rofi "$rf" \
    --argjson recently_used "$ru" \
    --argjson meltype "$mt" \
    --argjson ai_agents "$ai" \
    --argjson clipboard "$cb" \
    --argjson current_config "$cfg" \
    --argjson feedback "$fb" '
    {
      meta: {
        generated_at: $generated_at,
        host: $host,
        days: $days,
        window_start: $window_start,
        window_end: $window_end
      },
      sources: {
        activitywatch: $activitywatch,
        whatpulse: $whatpulse,
        bash_history: $bash_history,
        vivaldi: $vivaldi,
        firefox: $firefox,
        rofi: $rofi,
        recently_used: $recently_used,
        meltype: $meltype,
        ai_agents: $ai_agents,
        clipboard: $clipboard
      },
      current_config: $current_config,
      feedback: $feedback
    }
  ' | redact_json
}

run_self_test() {
  local sb="$TMPDIR_WORK/selftest"
  mkdir -p "$sb"

  # 1. Redaction checks
  local redacted=""
  redacted="$(jq -n '{
    url: "https://user:pass@example.com/path?token=abc&foo=bar#frag",
    cmd: "curl -H \"Authorization: Bearer supersecrettoken123\" https://api.example.com --password=mysecret",
    gh: "ghp_1234567890abcdefghij1234567890abcd",
    email: "alice@example.org",
    env: "API_KEY=secret_value_999 run"
  }' | redact_json)"

  jq -e '
    (.url | contains("pass") | not)
    and (.url | contains("token=abc") | not)
    and (.url == "https://[REDACTED]@example.com/path")
    and (.cmd | contains("supersecrettoken123") | not)
    and (.cmd | contains("mysecret") | not)
    and (.gh == "[REDACTED_TOKEN]")
    and (.email == "[REDACTED_EMAIL]")
    and (.env | contains("secret_value_999") | not)
  ' <<<"$redacted" >/dev/null || { printf 'FAIL: redaction check\n%s\n' "$redacted" >&2; exit 1; }

  # 2. Bash history aggregation (with timestamps + bigrams + long repeated)
  cat >"$sb/bash_history" <<EOF
#${NOW_EPOCH}
git status
#${NOW_EPOCH}
nix eval .#nixosConfigurations.vaio.config.networking.hostName
#${NOW_EPOCH}
git status
#${NOW_EPOCH}
nix eval .#nixosConfigurations.vaio.config.networking.hostName
#1000000000
ancient_command_should_be_excluded
EOF
  local bh_out=""
  bh_out="$(BASH_HISTFILE="$sb/bash_history" collect_bash_history)"
  jq -e '
    .status == "ok"
    and .has_timestamps == true
    and .total_commands == 4
    and (.long_repeated_commands | length == 1)
    and (.repeated_sequences[0].count == 2)
  ' <<<"$bh_out" >/dev/null || { printf 'FAIL: bash history check\n%s\n' "$bh_out" >&2; exit 1; }

  # 3. WhatPulse SQLite fixture (if sqlite3 available)
  if [ "$HAVE_SQLITE3" -eq 1 ]; then
    local wp_db="$sb/whatpulse.db"
    sqlite3 "$wp_db" <<SQL
CREATE TABLE applications (path TEXT PRIMARY KEY, name TEXT);
CREATE TABLE input_per_application (day TEXT, hour INTEGER, path TEXT, keys INTEGER, clicks INTEGER, distance_inches REAL, scrolls INTEGER, profile_id INTEGER);
CREATE TABLE keycombo_frequency_application (day TEXT, hour INTEGER, combo TEXT, count INTEGER, path TEXT, profile_id INTEGER);
CREATE TABLE keypress_frequency_application (day TEXT, hour INTEGER, key INTEGER, count INTEGER, path TEXT, profile_id INTEGER);
INSERT INTO applications VALUES ('/usr/bin/vivaldi', 'Vivaldi');
INSERT INTO input_per_application VALUES ('${CUTOFF_DAY}', 10, '/usr/bin/vivaldi', 500, 200, 100.0, 50, 1);
INSERT INTO input_per_application VALUES ('0000-00-00', 0, '/usr/bin/vivaldi', 99999, 99999, 999.0, 999, 1);
INSERT INTO keycombo_frequency_application VALUES ('${CUTOFF_DAY}', 10, 'control,shift,84', 42, '/usr/bin/vivaldi', 1);
INSERT INTO keypress_frequency_application VALUES ('${CUTOFF_DAY}', 10, 16777219, 300, '/usr/bin/vivaldi', 1);
SQL
    local wp_out=""
    wp_out="$(WHATPULSE_DB="$wp_db" collect_whatpulse)"
    jq -e '
      .status == "ok"
      and .totals.keys == 500
      and .totals.clicks == 200
      and .input_per_app[0].app == "Vivaldi"
      and .input_per_app[0].clicks_per_1k_keys == 400
      and .top_keycombos[0].combo == "Ctrl+Shift+T"
      and .nav_edit_keys_per_app[0].key == "Backspace"
    ' <<<"$wp_out" >/dev/null || { printf 'FAIL: whatpulse check\n%s\n' "$wp_out" >&2; exit 1; }

    # 4. Vivaldi SQLite fixture
    local viv_db="$sb/vivaldi.sqlite"
    local now_chrome_us=$(( (NOW_EPOCH + 11644473600) * 1000000 ))
    sqlite3 "$viv_db" <<SQL
CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, transition INTEGER);
INSERT INTO urls VALUES (1, 'https://github.com/org/repo/pulls?secret=123', 'PRs', 5, 2, ${now_chrome_us}, 0);
INSERT INTO visits VALUES (1, 1, ${now_chrome_us}, 1);
INSERT INTO visits VALUES (2, 1, ${now_chrome_us}, 0);
SQL
    local viv_out=""
    viv_out="$(VIVALDI_HISTORY="$viv_db" collect_vivaldi | redact_json)"
    jq -e '
      .status == "ok"
      and .visits_in_window == 2
      and .top_domains[0].domain == "github.com"
      and .top_domains[0].typed_visits == 1
      and .top_paths[0].path == "github.com/org/repo"
    ' <<<"$viv_out" >/dev/null || { printf 'FAIL: vivaldi check\n%s\n' "$viv_out" >&2; exit 1; }
  fi

  # 5. Missing-source graceful degradation
  local empty_wp=""
  empty_wp="$(WHATPULSE_DB="$sb/nonexistent.db" XDG_CONFIG_HOME="$sb" XDG_DATA_HOME="$sb" HOME="$sb" WHATPULSE_API_URL="http://127.0.0.1:1" collect_whatpulse)"
  jq -e '.status == "not_found"' <<<"$empty_wp" >/dev/null \
    || { printf 'FAIL: missing whatpulse fallback\n%s\n' "$empty_wp" >&2; exit 1; }

  printf 'ops-advisor-collect self-test: PASS (sqlite3=%s)\n' "$HAVE_SQLITE3"
}

if [ "$SELF_TEST" -eq 1 ]; then
  run_self_test
else
  run_collect
fi
