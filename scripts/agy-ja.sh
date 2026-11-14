#!/usr/bin/env bash
# Launch Antigravity (`agy` / `agy-ja`) with a toggleable live PLaMo 0.8B translation pane.
# Non-interactive invocations, subcommands, non-TTY runs, or `--no-translate` pass
# straight through to the raw `antigravity` binary.
set -euo pipefail

AGY_BIN="${AGY_BIN:-antigravity}"
WATCH_BIN="${AGY_TRANSLATE_WATCH_BIN:-agy-translate-watch}"
PLAMO_BIN="${PLAMO_TRANSLATE_BIN:-plamo-translate}"
PANE_TOGGLE_BIN="${AGY_PANE_TOGGLE_BIN:-}"
LAUNCHER_NAME="${AGY_LAUNCHER_NAME:-$(basename "$0")}"

CACHE_DIR="${PLAMO_TRANSLATE_CACHE_DIR:-$HOME/.cache/plamo-translate}"
RUN_DIR="${CACHE_DIR}/run"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/plamo-translate"
DISABLED_FILE="${STATE_DIR}/disabled"

is_globally_enabled() {
  [ ! -e "$DISABLED_FILE" ]
}

stop_plamo_if_unused() {
  if ! pgrep -f '/bin/agy-translate-watch-py' >/dev/null 2>&1; then
    "$PLAMO_BIN" stop >/dev/null 2>&1 || true
  fi
}

cmd_on() {
  rm -f "$DISABLED_FILE"
  printf 'agy 思考翻訳: ON（次回以降の agy 起動で自動表示）\n'
}

cmd_off() {
  mkdir -p "$STATE_DIR"
  : > "$DISABLED_FILE"
  stop_plamo_if_unused
  printf 'agy 思考翻訳: OFF（次回以降の agy は翻訳なしで起動）\n'
  if pgrep -f '/bin/agy-translate-watch-py' >/dev/null 2>&1; then
    printf 'ヒント: 実行中の agy 内のペインは F9（または Ctrl+b t）で即閉じできます\n'
  fi
}

cmd_toggle() {
  if is_globally_enabled; then
    cmd_off
  else
    cmd_on
  fi
}

cmd_status() {
  local watchers
  watchers="$(pgrep -fc '/bin/agy-translate-watch-py' 2>/dev/null || true)"
  if is_globally_enabled; then
    printf 'agy auto-translate: ON（切替: agy-ja off / agy translate off / --no-translate）\n'
  else
    printf 'agy auto-translate: OFF（切替: agy-ja on / agy translate on / --translate）\n'
  fi
  printf 'active watchers: %s\n' "${watchers:-0}"
  "$PLAMO_BIN" status
}

pick_split_flag_for() {
  local mode="$1"
  local cols="$2"
  case "$mode" in
    h|horizontal|side) echo "-h" ;;
    v|vertical|stack|bottom) echo "-v" ;;
    *)
      if [ "${cols:-160}" -ge 120 ] 2>/dev/null; then
        echo "-h"
      else
        echo "-v"
      fi
      ;;
  esac
}

set_window_watch_opts() {
  local win_id="$1"
  local pane0_id="$2"
  local watch_pane="$3"
  local log_file="$4"
  local done_file="$5"
  local parent_pid="$6"
  local history_n="$7"
  local form="$8"
  local all_monitors="$9"
  local split_mode="${10}"
  local pane_pct="${11}"

  tmux set-option -t "$win_id" -w @agy_pane0_id "$pane0_id" \; \
    set-option -t "$win_id" -w @agy_watch_pane "$watch_pane" \; \
    set-option -t "$win_id" -w @agy_log_file "$log_file" \; \
    set-option -t "$win_id" -w @agy_done_file "$done_file" \; \
    set-option -t "$win_id" -w @agy_parent_pid "$parent_pid" \; \
    set-option -t "$win_id" -w @agy_history "$history_n" \; \
    set-option -t "$win_id" -w @agy_form "$form" \; \
    set-option -t "$win_id" -w @agy_all_monitors "$all_monitors" \; \
    set-option -t "$win_id" -w @agy_split_mode "$split_mode" \; \
    set-option -t "$win_id" -w @agy_pct "$pane_pct" \; \
    set-option -t "$win_id" -w @agy_ja_state "ON" >/dev/null 2>&1 || true
}

install_tmux_toggle_bindings() {
  local enable_status_click="${1:-0}"
  [ -n "$PANE_TOGGLE_BIN" ] || return 0
  local esc_bin run_action
  esc_bin="$(printf '%q' "$PANE_TOGGLE_BIN")"
  run_action="run-shell -b \"${esc_bin} #{window_id}\""
  tmux bind-key -T root F9 if-shell -F '#{@agy_log_file}' "$run_action" 'send-keys F9' \; \
    bind-key -T prefix t if-shell -F '#{@agy_log_file}' "$run_action" 'clock-mode' >/dev/null 2>&1 || true
  if [ "$enable_status_click" -eq 1 ]; then
    tmux bind-key -T root MouseDown1Status if-shell -F '#{==:#{mouse_status_range},agy_toggle}' "$run_action" 'switch-client -t =' >/dev/null 2>&1 || true
  fi
}

pane_toggle() {
  local win_id="${1:-}"
  if [ -z "$win_id" ]; then
    win_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
  fi
  [ -n "$win_id" ] || return 0

  local log_file done_file pane0_id parent_pid watch_pane history_n form all_monitors split_mode pct
  log_file="$(tmux show-options -t "$win_id" -wqv @agy_log_file 2>/dev/null || true)"
  [ -n "$log_file" ] || return 0

  done_file="$(tmux show-options -t "$win_id" -wqv @agy_done_file 2>/dev/null || true)"
  pane0_id="$(tmux show-options -t "$win_id" -wqv @agy_pane0_id 2>/dev/null || true)"
  parent_pid="$(tmux show-options -t "$win_id" -wqv @agy_parent_pid 2>/dev/null || true)"
  watch_pane="$(tmux show-options -t "$win_id" -wqv @agy_watch_pane 2>/dev/null || true)"
  history_n="$(tmux show-options -t "$win_id" -wqv @agy_history 2>/dev/null || true)"
  form="$(tmux show-options -t "$win_id" -wqv @agy_form 2>/dev/null || true)"
  all_monitors="$(tmux show-options -t "$win_id" -wqv @agy_all_monitors 2>/dev/null || true)"
  split_mode="$(tmux show-options -t "$win_id" -wqv @agy_split_mode 2>/dev/null || true)"
  pct="$(tmux show-options -t "$win_id" -wqv @agy_pct 2>/dev/null || true)"

  history_n="${history_n:-2}"
  form="${form:-plain}"
  all_monitors="${all_monitors:-0}"
  split_mode="${split_mode:-auto}"
  pct="${pct:-38}"

  local is_open=0
  if [ -n "$watch_pane" ] && tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | grep -qxF "$watch_pane"; then
    is_open=1
  fi

  if [ "$is_open" -eq 1 ]; then
    tmux kill-pane -t "$watch_pane" 2>/dev/null || true
    tmux set-option -t "$win_id" -w @agy_watch_pane "" 2>/dev/null || true
    tmux set-option -t "$win_id" -w @agy_ja_state "OFF" 2>/dev/null || true
    if [ -n "$pane0_id" ]; then
      tmux select-pane -t "$pane0_id" 2>/dev/null || true
    fi
    tmux refresh-client -S 2>/dev/null || true
    sleep 0.3
    stop_plamo_if_unused
    return 0
  fi

  local target_pane="$pane0_id"
  if [ -z "$target_pane" ] || ! tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | grep -qxF "$target_pane"; then
    target_pane="$(tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | head -n 1 || true)"
  fi
  [ -n "$target_pane" ] || return 0

  local cols split_flag
  cols="$(tmux display-message -t "$target_pane" -p '#{pane_width}' 2>/dev/null || echo 160)"
  split_flag="$(pick_split_flag_for "$split_mode" "$cols")"

  local -a w_args=(
    "$WATCH_BIN"
    --log-file "$log_file"
    --history "$history_n"
    --form "$form"
  )
  [ -n "$done_file" ] && w_args+=(--done-file "$done_file")
  [ -n "$parent_pid" ] && w_args+=(--parent-pid "$parent_pid")
  [ "$all_monitors" = "1" ] && w_args+=(--all-monitors)

  local new_pane
  new_pane="$(
    tmux split-window -t "$target_pane" "$split_flag" -l "${pct}%" -d -P -F '#{pane_id}' \
      env PATH="$PATH" "${w_args[@]}"
  )" || return 0

  tmux set-option -t "$win_id" -w @agy_watch_pane "$new_pane" 2>/dev/null || true
  tmux set-option -t "$win_id" -w @agy_ja_state "ON" 2>/dev/null || true
  tmux select-pane -t "$target_pane" 2>/dev/null || true
  tmux refresh-client -S 2>/dev/null || true
}

if [ "${1:-}" = "_pane-toggle" ]; then
  shift
  pane_toggle "$@"
  exit 0
fi

if [ "$LAUNCHER_NAME" = "agy-ja" ] && [ "$#" -eq 1 ]; then
  case "$1" in
    on|enable)
      cmd_on
      exit 0
      ;;
    off|disable)
      cmd_off
      exit 0
      ;;
    toggle)
      cmd_toggle
      exit 0
      ;;
    status)
      cmd_status
      exit $?
      ;;
  esac
fi

if [ "$#" -eq 2 ] && [ "$1" = "translate" ]; then
  case "$2" in
    on|enable)
      cmd_on
      exit 0
      ;;
    off|disable)
      cmd_off
      exit 0
      ;;
    toggle)
      cmd_toggle
      exit 0
      ;;
    status)
      cmd_status
      exit $?
      ;;
  esac
fi

if [ "$LAUNCHER_NAME" = "agy-ja" ]; then
  want_translate=1
elif is_globally_enabled; then
  want_translate=1
else
  want_translate=0
fi

if [ "${AGY_TRANSLATE:-0}" = "1" ]; then
  want_translate=1
fi
if [ "${AGY_NO_TRANSLATE:-0}" = "1" ]; then
  want_translate=0
fi

force_passthrough=0
if [ "${AGY_JA_ACTIVE:-0}" = "1" ]; then
  force_passthrough=1
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  force_passthrough=1
fi

pass_args=()
user_log_file=""
expect_value=""
seen_positional=0

for arg in "$@"; do
  if [ -n "$expect_value" ]; then
    if [ "$expect_value" = "log_file" ]; then
      user_log_file="$arg"
    fi
    pass_args+=("$arg")
    expect_value=""
    continue
  fi

  case "$arg" in
    --translate)
      want_translate=1
      continue
      ;;
    --no-translate)
      want_translate=0
      continue
      ;;
    -h|--help|-v|--version)
      force_passthrough=1
      ;;
    -p|--print|--prompt|-p=*|--print=*|--prompt=*|--input-format|--input-format=*|--output-format|--output-format=*|--json-schema|--json-schema=*)
      force_passthrough=1
      ;;
    --log-file)
      expect_value="log_file"
      ;;
    --log-file=*)
      user_log_file="${arg#--log-file=}"
      ;;
    -i|--prompt-interactive|--add-dir|--agent|--conversation|--effort|--mode|--model|--print-timeout|--project|--settings)
      expect_value="other"
      ;;
    --)
      seen_positional=1
      ;;
    -*)
      ;;
    *)
      if [ "$seen_positional" -eq 0 ]; then
        seen_positional=1
        case "$arg" in
          acp|agent|agents|changelog|help|install|mcp|mic-serve|models|plugin|plugins|remote-control|update)
            force_passthrough=1
            ;;
        esac
      fi
      ;;
  esac

  pass_args+=("$arg")
done

if [ "$force_passthrough" -eq 1 ] || [ "$want_translate" -eq 0 ]; then
  exec "$AGY_BIN" "${pass_args[@]}"
fi

mkdir -p "$RUN_DIR"
find "$RUN_DIR" -maxdepth 1 -type f \( -name 'agy-*.log' -o -name 'agy-*.done' \) -mtime +3 -delete 2>/dev/null || true

session_tag="$$-$(date +%Y%m%d_%H%M%S)"
done_file="${RUN_DIR}/agy-${session_tag}.done"
rm -f "$done_file"

if [ -n "$user_log_file" ]; then
  log_file="$user_log_file"
  mkdir -p "$(dirname "$log_file")"
  agy_log_args=()
else
  log_file="${RUN_DIR}/agy-${session_tag}.log"
  : > "$log_file"
  agy_log_args=(--log-file "$log_file")
fi

split_mode="${AGY_JA_SPLIT:-auto}"
pane_pct="${AGY_JA_PCT:-38}"
history_n="${AGY_JA_HISTORY:-2}"
form="${AGY_JA_FORM:-plain}"
all_monitors="${AGY_JA_ALL_MONITORS:-0}"

tty_dims() {
  local rows=0 cols=0 size=""
  size="$(stty size </dev/tty 2>/dev/null || true)"
  if [ -n "$size" ]; then
    read -r rows cols <<< "$size" || true
  fi
  if [ "${rows:-0}" -le 0 ] 2>/dev/null; then
    rows="$(tput lines 2>/dev/null || echo 40)"
  fi
  if [ "${cols:-0}" -le 0 ] 2>/dev/null; then
    cols="$(tput cols 2>/dev/null || echo 160)"
  fi
  [ "${rows:-0}" -gt 0 ] 2>/dev/null || rows=40
  [ "${cols:-0}" -gt 0 ] 2>/dev/null || cols=160
  printf '%s %s\n' "$rows" "$cols"
}

watch_args=(
  "$WATCH_BIN"
  --log-file "$log_file"
  --done-file "$done_file"
  --history "$history_n"
  --form "$form"
)
if [ "$all_monitors" = "1" ]; then
  watch_args+=(--all-monitors)
fi

export AGY_JA_ACTIVE=1

if [ -n "${TMUX:-}" ]; then
  cur_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  win_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
  cols="$(tmux display-message -p '#{pane_width}' 2>/dev/null || echo 160)"
  split_flag="$(pick_split_flag_for "$split_mode" "$cols")"
  watch_pane="$(
    tmux split-window "$split_flag" -l "${pane_pct}%" -d -P -F '#{pane_id}' \
      env PATH="$PATH" "${watch_args[@]}" --parent-pid "$$"
  )"
  if [ -n "$win_id" ]; then
    set_window_watch_opts "$win_id" "$cur_pane" "$watch_pane" "$log_file" "$done_file" "$$" \
      "$history_n" "$form" "$all_monitors" "$split_mode" "$pane_pct"
    install_tmux_toggle_bindings 0
  fi
  # shellcheck disable=SC2329
  cleanup_in_tmux() {
    touch "$done_file" 2>/dev/null || true
    local active_watch=""
    if [ -n "${win_id:-}" ]; then
      active_watch="$(tmux show-options -t "$win_id" -wqv @agy_watch_pane 2>/dev/null || true)"
      if [ -n "$active_watch" ]; then
        tmux kill-pane -t "$active_watch" 2>/dev/null || true
      fi
      for opt in @agy_pane0_id @agy_watch_pane @agy_log_file @agy_done_file @agy_parent_pid @agy_history @agy_form @agy_all_monitors @agy_split_mode @agy_pct @agy_ja_state; do
        tmux set-option -t "$win_id" -wu "$opt" 2>/dev/null || true
      done
    elif [ -n "${watch_pane:-}" ]; then
      tmux kill-pane -t "$watch_pane" 2>/dev/null || true
    fi
    rm -f "$done_file" 2>/dev/null || true
  }
  trap cleanup_in_tmux EXIT INT TERM
  set +e
  "$AGY_BIN" "${agy_log_args[@]}" "${pass_args[@]}"
  rc=$?
  set -e
  exit "$rc"
fi

read -r rows cols <<< "$(tty_dims)"
split_flag="$(pick_split_flag_for "$split_mode" "$cols")"
sess="agy-ja-${$}"

quoted_args=""
for a in "${agy_log_args[@]}" "${pass_args[@]}"; do
  quoted_args+=" $(printf '%q' "$a")"
done

# shellcheck disable=SC2016
agy_cmd=$(printf 'export PATH=%q COLORTERM=%q AGY_JA_ACTIVE=1; %q%s; rc=$?; touch %q; exit "$rc"' \
  "$PATH" "${COLORTERM:-truecolor}" "$AGY_BIN" "$quoted_args" "$done_file")

# shellcheck disable=SC2329
cleanup_tmux_session() {
  touch "$done_file" 2>/dev/null || true
  tmux kill-session -t "$sess" 2>/dev/null || true
  rm -f "$done_file" 2>/dev/null || true
}
trap cleanup_tmux_session EXIT INT TERM

tmux new-session -d -s "$sess" -x "$cols" -y "$rows" -c "$PWD" "$agy_cmd"
tmux set-option -t "$sess" mouse on >/dev/null 2>&1 || true
tmux set-option -t "$sess" history-limit 10000 >/dev/null 2>&1 || true
tmux set-option -t "$sess" default-terminal "tmux-256color" >/dev/null 2>&1 || true
tmux set-option -as -t "$sess" terminal-overrides ",*:RGB" >/dev/null 2>&1 || true
tmux set-option -t "$sess" status-style "bg=colour235,fg=colour248" >/dev/null 2>&1 || true
tmux set-option -t "$sess" status-left-length 30 >/dev/null 2>&1 || true
tmux set-option -t "$sess" status-left " #[fg=colour39 bold]agy#[default] " >/dev/null 2>&1 || true
tmux set-option -t "$sess" status-right-length 80 >/dev/null 2>&1 || true
tmux set-option -t "$sess" status-right "#[range=user|agy_toggle]#{?#{==:#{@agy_ja_state},ON},#[bg=colour28 fg=colour255 bold] 翻訳: ON #[default],#[bg=colour238 fg=colour250 bold] 翻訳: OFF #[default]}#[norange] #[fg=colour244]F9 / Ctrl-b t 切替 " >/dev/null 2>&1 || true

win_id="$(tmux display-message -t "${sess}:0.0" -p '#{window_id}' 2>/dev/null || true)"
pane0_id="$(tmux display-message -t "${sess}:0.0" -p '#{pane_id}' 2>/dev/null || true)"
pane0_pid="$(tmux display-message -t "${sess}:0.0" -p '#{pane_pid}' 2>/dev/null || true)"

if [ -n "$win_id" ]; then
  set_window_watch_opts "$win_id" "$pane0_id" "" "$log_file" "$done_file" "$pane0_pid" \
    "$history_n" "$form" "$all_monitors" "$split_mode" "$pane_pct"
  install_tmux_toggle_bindings 1
fi

watch_extra=()
if [ -n "$pane0_pid" ]; then
  watch_extra=(--parent-pid "$pane0_pid")
fi

watch_pane="$(
  tmux split-window -t "${sess}:0.0" "$split_flag" -l "${pane_pct}%" -d -P -F '#{pane_id}' \
    env PATH="$PATH" "${watch_args[@]}" "${watch_extra[@]}"
)"
if [ -n "$win_id" ]; then
  tmux set-option -t "$win_id" -w @agy_watch_pane "$watch_pane" >/dev/null 2>&1 || true
fi

tmux select-pane -t "${sess}:0.0" >/dev/null 2>&1 || true
set +e
tmux attach-session -t "$sess"
rc=$?
set -e
exit "$rc"
