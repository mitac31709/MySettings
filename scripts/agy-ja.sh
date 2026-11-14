#!/usr/bin/env bash
# Launch Antigravity (`agy`) paired with a live PLaMo 0.8B translation tmux pane.
set -euo pipefail

AGY_BIN="${AGY_BIN:-agy}"
WATCH_BIN="${AGY_TRANSLATE_WATCH_BIN:-agy-translate-watch}"
CACHE_DIR="${PLAMO_TRANSLATE_CACHE_DIR:-$HOME/.cache/plamo-translate}"
RUN_DIR="${CACHE_DIR}/run"
mkdir -p "$RUN_DIR"

# Prune old per-session logs/sentinels quietly so cache stays bounded.
find "$RUN_DIR" -maxdepth 1 -type f \( -name 'agy-*.log' -o -name 'agy-*.done' \) -mtime +3 -delete 2>/dev/null || true

session_tag="$$-$(date +%Y%m%d_%H%M%S)"
log_file="${RUN_DIR}/agy-${session_tag}.log"
done_file="${RUN_DIR}/agy-${session_tag}.done"
: > "$log_file"
rm -f "$done_file"

split_mode="${AGY_JA_SPLIT:-auto}"
pane_pct="${AGY_JA_PCT:-38}"
history_n="${AGY_JA_HISTORY:-2}"
form="${AGY_JA_FORM:-plain}"

pick_split_flag() {
  local cols="$1"
  case "$split_mode" in
    h|horizontal|side) echo "-h" ;;
    v|vertical|stack|bottom) echo "-v" ;;
    *)
      if [ "$cols" -ge 120 ]; then
        echo "-h"
      else
        echo "-v"
      fi
      ;;
  esac
}

watch_args=(
  "$WATCH_BIN"
  --log-file "$log_file"
  --done-file "$done_file"
  --history "$history_n"
  --form "$form"
)
if [ "${AGY_JA_ALL_MONITORS:-0}" = "1" ]; then
  watch_args+=(--all-monitors)
fi

if [ -n "${TMUX:-}" ]; then
  cols="$(tmux display-message -p '#{pane_width}' 2>/dev/null || echo 160)"
  split_flag="$(pick_split_flag "$cols")"
  watch_pane="$(
    tmux split-window "$split_flag" -l "${pane_pct}%" -d -P -F '#{pane_id}' -c "$PWD" \
      env PATH="$PATH" "${watch_args[@]}" --parent-pid "$$"
  )"
  cleanup_in_tmux() {
    touch "$done_file" 2>/dev/null || true
    if [ -n "${watch_pane:-}" ]; then
      tmux kill-pane -t "$watch_pane" 2>/dev/null || true
    fi
    rm -f "$done_file" 2>/dev/null || true
  }
  trap cleanup_in_tmux EXIT INT TERM
  set +e
  "$AGY_BIN" --log-file "$log_file" "$@"
  rc=$?
  set -e
  exit "$rc"
fi

cols="$(tput cols 2>/dev/null || echo 160)"
split_flag="$(pick_split_flag "$cols")"
sess="agy-ja-${$}"

quoted_args=""
for a in "$@"; do
  quoted_args+=" $(printf '%q' "$a")"
done

agy_cmd=$(printf 'export PATH=%q COLORTERM=%q; %q --log-file %q%s; rc=$?; touch %q; exit "$rc"' \
  "$PATH" "${COLORTERM:-truecolor}" "$AGY_BIN" "$log_file" "$quoted_args" "$done_file")

cleanup_tmux_session() {
  touch "$done_file" 2>/dev/null || true
  tmux kill-session -t "$sess" 2>/dev/null || true
  rm -f "$done_file" 2>/dev/null || true
}
trap cleanup_tmux_session EXIT INT TERM

tmux new-session -d -s "$sess" -c "$PWD" "$agy_cmd"
tmux set-option -t "$sess" mouse on >/dev/null 2>&1 || true
tmux set-option -t "$sess" history-limit 10000 >/dev/null 2>&1 || true
tmux set-option -t "$sess" default-terminal "tmux-256color" >/dev/null 2>&1 || true
tmux set-option -as -t "$sess" terminal-overrides ",*:RGB" >/dev/null 2>&1 || true

pane0_pid="$(tmux display-message -t "${sess}:0.0" -p '#{pane_pid}' 2>/dev/null || true)"
watch_extra=()
if [ -n "$pane0_pid" ]; then
  watch_extra=(--parent-pid "$pane0_pid")
fi

tmux split-window -t "${sess}:0.0" "$split_flag" -l "${pane_pct}%" -d -c "$PWD" \
  env PATH="$PATH" "${watch_args[@]}" "${watch_extra[@]}"

tmux select-pane -t "${sess}:0.0" >/dev/null 2>&1 || true
set +e
tmux attach-session -t "$sess"
rc=$?
set -e
exit "$rc"
