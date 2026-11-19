# Hyprland Home Manager: standard Hyprland 0.57+ Lua desktop (UWSM).
# Visual system: Nocturne Slate (lib/theme.nix) — translucent dark slate, glacial teal
# & arctic sky accents, rounded geometry, blur/shadow depth, fluid spring/bezier motion.
# Ecosystem: hyprpaper, hyprlock, hypridle, hyprshot, hyprpicker, satty, waybar, rofi, mako.
{
  config,
  pkgs,
  lib,
  flakeTarget ? "chromebook",
  ...
}:

let
  theme = import ../lib/theme.nix;
  p = theme.palette;
  wallpaperPng = theme.mkWallpaper pkgs;

  isChromebook = flakeTarget == "chromebook";
  inputSection = if isChromebook then "入力・Chromebook" else "入力・VAIO";
  powerSection = if isChromebook then "電源・Type-C" else "電源・省電力";
  repoPath = config.mitac.repoPath;
  flakeUpdateCheck = lib.getExe config.mitac.scripts.flakeUpdateCheck;
  flakeUpdate = lib.getExe config.mitac.scripts.flakeUpdate;
  startupSoundBin = lib.getExe config.mitac.scripts.startupSound;

  waybarFont = theme.font.mono;
  ghosttyBin = "${pkgs.ghostty}/bin/ghostty";
  rofiBin = lib.getExe config.programs.rofi.package;
  yaziBin = "${pkgs.yazi}/bin/yazi";
  hyprlockBin = "${pkgs.hyprlock}/bin/hyprlock";
  hyprpickerBin = "${pkgs.hyprpicker}/bin/hyprpicker";
  hyprctlBin = "${pkgs.hyprland}/bin/hyprctl";
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  btopBin = "${pkgs.btop}/bin/btop";
  nmtuiBin = "${pkgs.networkmanager}/bin/nmtui";

  # Safe wrapper for Hyprland 0.57+ Lua `hl.dsp.exec_cmd(...)` via hyprctl dispatch.
  # Accepts either a single shell command string or argv tokens.
  hyprExec = pkgs.writeShellApplication {
    name = "hypr-exec";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      if [ "$#" -eq 0 ]; then
        exit 0
      fi
      if [ "$#" -eq 1 ]; then
        cmd="$1"
      else
        cmd=""
        for arg in "$@"; do
          cmd+="''${cmd:+ }$(printf '%q' "$arg")"
        done
      fi
      lua_expr="$(jq -Rn --arg c "$cmd" '"hl.dsp.exec_cmd(" + ($c | tojson) + ")"')"
      exec ${hyprctlBin} dispatch "$lua_expr" >/dev/null
    '';
  };
  hyprExecBin = lib.getExe hyprExec;

  flakeUpdateRunner = pkgs.writeShellScript "open-flake-update" ''
    rc=0
    ${flakeUpdate} || rc=$?
    printf '\n終了コード: %d [Enter で閉じる] ' "$rc"
    IFS= read -r _ || true
  '';
  openFlakeUpdate = "${ghosttyBin} -e ${flakeUpdateRunner}";

  # pactl +N% has no ceiling; cap volume at 100% to avoid soft-boost distortion.
  volumeUp = pkgs.writeShellScript "volume-up" ''
    out="$(${pactl} get-sink-volume @DEFAULT_SINK@)" || exit 1
    if [[ "$out" =~ ([0-9]+)% ]]; then
      vol="''${BASH_REMATCH[1]}"
    else
      exit 1
    fi
    new=$((vol + 5))
    if [ "$new" -gt 100 ]; then
      new=100
    fi
    exec ${pactl} set-sink-volume @DEFAULT_SINK@ "''${new}%"
  '';

  screenshotBin = pkgs.writeShellApplication {
    name = "screenshot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprshot
      pkgs.libnotify
      pkgs.procps
      config.programs.rofi.package
      pkgs.satty
      pkgs.wl-clipboard
    ];
    text = ''
      mode="''${1:-region}"
      out_dir="$HOME/Pictures/Screenshots"
      mkdir -p "$out_dir"
      out_pattern="$out_dir/screenshot-%Y%m%d-%H%M%S.png"

      if [ "$mode" = "menu" ]; then
        choice="$(
          printf '%s\n' \
            "範囲選択 → Satty 編集 (Super+Shift+S / Shift+Print)" \
            "全画面（出力） → Satty 切り抜き・編集 (Print)" \
            "ウィンドウ → Satty 編集 (Super+Print)" \
            "範囲選択 → 即クリップボード" \
            "全画面（出力） → 即クリップボード" \
            | rofi -dmenu -i -p 'スクリーンショット' || true
        )"
        case "$choice" in
          "範囲選択 → Satty"*) mode="region" ;;
          "全画面（出力） → Satty"*) mode="full" ;;
          "ウィンドウ"*) mode="window" ;;
          "範囲選択 → 即"*) mode="quick-region" ;;
          "全画面（出力） → 即"*) mode="quick-full" ;;
          *) exit 0 ;;
        esac
      fi

      open_satty() {
        local file="$1"
        local tool="$2"
        wl-copy --type image/png < "$file"
        satty \
          --filename "$file" \
          --initial-tool "$tool" \
          --output-filename "$out_pattern" \
          --copy-command wl-copy \
          --early-exit copy \
          --early-exit save \
          --actions-on-enter save-to-clipboard \
          --actions-on-enter exit \
          --actions-on-escape exit \
          --corner-roundness ${toString theme.radius.window}
      }

      tmp="$(mktemp --suffix=.png)"
      trap 'rm -f "$tmp"' EXIT

      case "$mode" in
        region)
          hyprshot -m region -s -z -r >"$tmp" || exit 0
          [ -s "$tmp" ] || exit 0
          open_satty "$tmp" arrow
          ;;
        full)
          hyprshot -m output -s -z -r >"$tmp" || exit 0
          [ -s "$tmp" ] || exit 0
          open_satty "$tmp" crop
          ;;
        window)
          hyprshot -m window -s -z -r >"$tmp" || exit 0
          [ -s "$tmp" ] || exit 0
          open_satty "$tmp" arrow
          ;;
        quick-region)
          hyprshot -m region -s -z -r >"$tmp" || exit 0
          [ -s "$tmp" ] || exit 0
          wl-copy --type image/png < "$tmp"
          notify-send "スクリーンショット" "選択範囲をクリップボードへコピーしました" >/dev/null 2>&1 || true
          ;;
        quick-full)
          hyprshot -m output -s -z -r >"$tmp" || exit 0
          [ -s "$tmp" ] || exit 0
          wl-copy --type image/png < "$tmp"
          notify-send "スクリーンショット" "全画面をクリップボードへコピーしました" >/dev/null 2>&1 || true
          ;;
        *)
          printf 'Usage: screenshot [region|full|window|quick-region|quick-full|menu]\n' >&2
          exit 2
          ;;
      esac
    '';
  };
  capsomniaPkg = pkgs.callPackage ../pkgs/capsomnia { };

  # Presentation marker toggled with waybar keep-screen-on button or Capsomnia Keep Display Awake.
  # XDG_RUNTIME_DIR is session-scoped so it clears automatically on logout.
  lockOnceCmd = pkgs.writeShellScript "hypr-lock-once" ''
    if ${pkgs.procps}/bin/pgrep -x hyprlock >/dev/null 2>&1; then
      exit 0
    fi
    exec ${hyprlockBin}
  '';
  idleDimCmd = pkgs.writeShellScript "hypr-idle-dim" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ] || [ -e "''${XDG_RUNTIME_DIR}/capsomnia/keep-display-awake" ]; then
      exit 0
    fi
    ${brightnessctl} -s set 20% >/dev/null 2>&1 || true
  '';
  idleUndimCmd = pkgs.writeShellScript "hypr-idle-undim" ''
    ${brightnessctl} -r >/dev/null 2>&1 || true
  '';
  idleLockCmd = pkgs.writeShellScript "hypr-idle-lock" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ] || [ -e "''${XDG_RUNTIME_DIR}/capsomnia/keep-display-awake" ]; then
      exit 0
    fi
    exec ${lockOnceCmd}
  '';
  idleDpmsOffCmd = pkgs.writeShellScript "hypr-idle-dpms-off" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ] || [ -e "''${XDG_RUNTIME_DIR}/capsomnia/keep-display-awake" ]; then
      exit 0
    fi
    exec ${hyprctlBin} dispatch 'hl.dsp.dpms("off")'
  '';
  idleDpmsOnCmd = pkgs.writeShellScript "hypr-idle-dpms-on" ''
    ${hyprctlBin} dispatch 'hl.dsp.dpms("on")' >/dev/null 2>&1 || true
    ${brightnessctl} -r >/dev/null 2>&1 || true
  '';
  toggleKeepScreenOn = pkgs.writeShellScript "hypr-toggle-keep-screen-on" ''
    marker="''${XDG_RUNTIME_DIR}/hypr-keep-screen-on"
    if [ -e "$marker" ]; then
      rm -f "$marker"
    else
      touch "$marker"
    fi
    ${pkgs.procps}/bin/pkill -SIGRTMIN+14 -x waybar >/dev/null 2>&1 || true
  '';
  waybarKeepScreenOn = pkgs.writeShellScript "waybar-keep-screen-on" ''
    marker="''${XDG_RUNTIME_DIR}/hypr-keep-screen-on"
    if [ -e "$marker" ]; then
      printf '%s\n' '{"text":"󰅶 ON","class":"activated","tooltip":"画面常時オン（減光・ロック・消灯なし／クリックで解除）"}'
    else
      printf '%s\n' '{"text":"󰾪","class":"deactivated","tooltip":"画面を常時オンにする（減光・ロック・消灯を抑制）"}'
    fi
  '';

  # Route Rofi launches through hypr-exec so new windows spawn on the active workspace.
  rofiLauncher = "${rofiBin} -show drun -run-command \"${hyprExecBin} {cmd}\" -run-shell-command \"${hyprExecBin} ${ghosttyBin} -e {cmd}\"";
  # Super+P: one-off command runner (`rofi -show run`).
  # Enter runs via hypr-exec; Shift+Enter (or Ctrl+Shift+Enter for custom
  # text) runs in an interactive Ghostty shell that waits before closing.
  rofiRunTerm = pkgs.writeShellScript "rofi-run-term" ''
    args=()
    for arg in "$@"; do
      if [[ "$arg" =~ [[:space:]] ]]; then
        printf -v q '%q' "$arg"
        args+=("$q")
      else
        args+=("$arg")
      fi
    done
    cmd="''${args[*]}"
    [ -n "$cmd" ] || exit 0
    exec ${ghosttyBin} -e ${pkgs.bash}/bin/bash -ic '
      eval "$1"
      rc=$?
      printf "\n終了コード: %d [Enter で閉じる] " "$rc"
      IFS= read -r _ || true
    ' _ "$cmd"
  '';
  rofiRunner = pkgs.writeShellScript "rofi-run" ''
    exec ${rofiBin} -show run \
      -mesg 'Enter: 実行  │  Shift+Enter: 端末で実行  │  Ctrl+(Shift+)Enter: 自由入力実行' \
      -run-command '${hyprExecBin} {cmd}' \
      -run-shell-command '${rofiRunTerm} {cmd}'
  '';
  # Super+N: switch to the lowest unused numbered workspace (no-op if current
  # workspace is already empty, ignoring pinned floating windows).
  newWorkspace = pkgs.writeShellApplication {
    name = "hypr-new-workspace";
    runtimeInputs = [
      pkgs.jq
    ];
    text = ''
      cur_id="$(${hyprctlBin} -j activeworkspace | jq -r '.id // empty')"
      if [ -n "$cur_id" ] && [ "$cur_id" -gt 0 ]; then
        non_pinned="$(
          ${hyprctlBin} -j clients | jq --argjson id "$cur_id" '
            [ .[] | select(.workspace.id == $id and (.pinned | not)) ] | length
          '
        )"
        if [ "$non_pinned" = "0" ]; then
          exit 0
        fi
      fi
      next_num="$(
        ${hyprctlBin} -j workspaces | jq -r '
          ([ .[] | .id | select(. != null and . > 0) ]) as $used |
          first(range(1; 1000) | select(. as $n | ($used | index($n) | not)))
        '
      )"
      [ -n "$next_num" ] || exit 0
      exec ${hyprctlBin} dispatch "hl.dsp.focus({ workspace = $next_num })"
    '';
  };
  # waybar cpu / mem → Ghostty + btop; network → Ghostty + nmtui; clock → NTP sync
  openBtop = "${ghosttyBin} -e ${btopBin}";
  openNmtui = "${ghosttyBin} -e ${nmtuiBin}";
  openYazi = "${ghosttyBin} -e ${yaziBin}";

  waybarClock = pkgs.writeShellScript "waybar-clock" ''
    export LC_ALL=C
    export TZDIR="${pkgs.tzdata}/share/zoneinfo"
    printf -v now '%(%s)T' -1
    TZ="Asia/Tokyo" printf -v bar '%(%a %m-%d  %H:%M:%S)T' "$now"
    lines=""
    sep='\n'
    for tz in Asia/Tokyo UTC America/Los_Angeles Asia/Shanghai; do
      TZ="$tz" printf -v abbr '%(%Z)T' "$now"
      TZ="$tz" printf -v ts '%(%Y-%m-%d (%a) %H:%M:%S)T' "$now"
      TZ="$tz" printf -v off '%(%z)T' "$now"
      printf -v row '%-4s %s (%s:%s)' "$abbr" "$ts" "''${off:0:3}" "''${off:3:2}"
      lines+="''${lines:+$sep}$row"
    done

    # Derive TAI-UTC from tzdata leap-seconds.list; GPST = TAI - 19s (epoch 1980-01-06).
    ntp_now=$((now + 2208988800))
    dtai=19
    while read -r ntp val _; do
      case "$ntp" in
        ""|\#*) continue ;;
      esac
      if [ "$ntp" -le "$ntp_now" ]; then
        dtai="$val"
      fi
    done < "$TZDIR/leap-seconds.list"
    gps_off=$((dtai - 19))
    gps_unix=$((now + gps_off))
    gps_sec=$((now - 315964800 + gps_off))
    gps_week=$((gps_sec / 604800))
    gps_tow=$((gps_sec % 604800))
    TZ="UTC" printf -v gps_ts '%(%Y-%m-%d (%a) %H:%M:%S)T' "$gps_unix"
    printf -v gps_row '%-4s %s (UTC%+ds / W%d %ds)' "GPST" "$gps_ts" "$gps_off" "$gps_week" "$gps_tow"
    printf -v unix_row '%-4s %s' "UNIX" "$now"
    lines+="$sep$gps_row$sep$unix_row"

    if [ -e /run/systemd/timesync/synchronized ]; then
      ntp_line="NTP: 同期済み（クリックで時刻同期）"
    else
      ntp_line="NTP: 同期待ち（クリックで時刻同期）"
    fi
    tooltip="$lines\n\n$ntp_line"
    printf '{"text":"%s","tooltip":"%s"}\n' "$bar" "$tooltip"
  '';

  waybarBattery = pkgs.writeShellApplication {
    name = "waybar-battery";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      pref_bat=""
      pref_adapter=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --bat)
            pref_bat="''${2:-}"
            shift 2
            ;;
          --adapter)
            pref_adapter="''${2:-}"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done

      ps_root="''${WAYBAR_POWER_SUPPLY_DIR:-/sys/class/power_supply}"

      bat_dir=""
      if [ -n "$pref_bat" ] && [ -d "$ps_root/$pref_bat" ]; then
        bat_dir="$ps_root/$pref_bat"
      else
        for d in "$ps_root"/BAT* "$ps_root"/*; do
          [ -d "$d" ] || continue
          [ -r "$d/type" ] || continue
          IFS= read -r tp < "$d/type" || continue
          [ "$tp" = "Battery" ] || continue
          if [ -r "$d/scope" ]; then
            IFS= read -r sc < "$d/scope" || sc=""
            if [ "''${sc,,}" = "device" ]; then
              continue
            fi
          fi
          bat_dir="$d"
          break
        done
      fi

      if [ -z "$bat_dir" ] || [ ! -d "$bat_dir" ]; then
        printf '{"text":"","class":"empty"}\n'
        exit 0
      fi

      read_val() {
        local f="$1" def="''${2:-}" v
        if [ -r "$f" ]; then
          IFS= read -r v < "$f" || v="$def"
          printf '%s' "$v"
        else
          printf '%s' "$def"
        fi
      }

      bat_name="$(basename "$bat_dir")"
      status="$(read_val "$bat_dir/status" "Unknown")"
      raw_cap="$(read_val "$bat_dir/capacity" "")"
      vn="$(read_val "$bat_dir/voltage_now" "0")"
      vmin="$(read_val "$bat_dir/voltage_min_design" "0")"

      adapter_online=""
      if [ -n "$pref_adapter" ] && [ -r "$ps_root/$pref_adapter/online" ]; then
        adapter_online="$(read_val "$ps_root/$pref_adapter/online" "")"
      else
        for d in "$ps_root"/*; do
          [ -d "$d" ] || continue
          [ -r "$d/type" ] || continue
          IFS= read -r tp < "$d/type" || continue
          if [ "$tp" = "Mains" ] && [ -r "$d/online" ]; then
            adapter_online="$(read_val "$d/online" "")"
            break
          fi
        done
      fi

      mode=""
      now_val=0
      full_val=0
      design_val=0
      power_val=0
      pw_unit=""
      has_power=0
      if [ -r "$bat_dir/energy_now" ] && [ -r "$bat_dir/energy_full" ]; then
        mode="energy"
        now_val="$(read_val "$bat_dir/energy_now" "0")"
        full_val="$(read_val "$bat_dir/energy_full" "0")"
        design_val="$(read_val "$bat_dir/energy_full_design" "0")"
      elif [ -r "$bat_dir/charge_now" ] && [ -r "$bat_dir/charge_full" ]; then
        mode="charge"
        now_val="$(read_val "$bat_dir/charge_now" "0")"
        full_val="$(read_val "$bat_dir/charge_full" "0")"
        design_val="$(read_val "$bat_dir/charge_full_design" "0")"
      fi

      if [ -r "$bat_dir/power_now" ]; then
        power_val="$(read_val "$bat_dir/power_now" "0")"
        pw_unit="W"
        has_power=1
      elif [ -r "$bat_dir/current_now" ]; then
        power_val="$(read_val "$bat_dir/current_now" "0")"
        pw_unit="A"
        has_power=1
      fi

      disp_status="$status"
      if [ "$status" = "Unknown" ]; then
        if [ "$adapter_online" = "1" ]; then
          disp_status="Plugged"
        else
          disp_status="Discharging"
        fi
      elif [ "$status" = "Not charging" ] && [ "$adapter_online" = "1" ]; then
        disp_status="Plugged"
      fi

      {
        IFS= read -r -d "" text
        IFS= read -r -d "" classes
        IFS= read -r -d "" tip
      } < <(awk \
        -v bat="$bat_name" \
        -v st="$disp_status" \
        -v ac="$adapter_online" \
        -v raw_cap="$raw_cap" \
        -v vn="$vn" \
        -v vmin="$vmin" \
        -v mode="$mode" \
        -v now_v="$now_val" \
        -v full_v="$full_val" \
        -v design_v="$design_val" \
        -v pw_v="$power_val" \
        -v pw_unit="$pw_unit" \
        -v has_pw="$has_power" \
        'BEGIN {
          if (pw_v < 0) pw_v = -pw_v
          cap = 0
          if ((mode == "energy" || mode == "charge") && full_v > 0) {
            cap = int((100.0 * now_v / full_v) + 0.5)
          } else if (raw_cap != "") {
            cap = int(raw_cap + 0)
          }
          if (cap < 0) cap = 0
          if (cap > 100) cap = 100

          if (cap == 100 && st == "Charging") st = "Full"

          if (st == "Charging") icon = "󰂄"
          else if (st == "Plugged" || st == "Full") icon = "󰚥"
          else if (cap <= 15) icon = "󰂎"
          else if (cap <= 35) icon = "󰁼"
          else if (cap <= 60) icon = "󰁾"
          else if (cap <= 85) icon = "󰂀"
          else icon = "󰁹"
          text = sprintf("%s %d%%", icon, cap)

          cls_st = tolower(st)
          gsub(/ /, "-", cls_st)
          classes = cls_st
          if (cap <= 15) classes = classes " critical"
          else if (cap <= 30) classes = classes " warning"

          ac_note = (ac == "1") ? "（AC 接続中）" : ""
          line1 = sprintf("%s: %s %d%%%s", bat, st, cap, ac_note)

          line2 = ""
          if (vn > 0) {
            if (vmin > 0) {
              line2 = sprintf("電圧: %.2f V（設計下限 %.2f V）", vn / 1e6, vmin / 1e6)
            } else {
              line2 = sprintf("電圧: %.2f V", vn / 1e6)
            }
          }

          v_ref = (vn > 0) ? (vn / 1e6) : ((vmin > 0) ? (vmin / 1e6) : 0)
          pw_w = 0
          if (has_pw) {
            if (pw_unit == "W") pw_w = pw_v / 1e6
            else if (pw_unit == "A" && v_ref > 0) pw_w = (pw_v / 1e6) * v_ref
          }

          line3 = ""
          rem_h = 0
          if (mode == "energy") {
            health = (design_v > 0) ? (100.0 * full_v / design_v) : 0
            if (design_v > 0) {
              line3 = sprintf("容量: %.2f / %.2f Wh（設計 %.2f Wh / 健康度 %.0f%%）", now_v / 1e6, full_v / 1e6, design_v / 1e6, health)
            } else {
              line3 = sprintf("容量: %.2f / %.2f Wh", now_v / 1e6, full_v / 1e6)
            }
            if (pw_w > 0.1) {
              if (st == "Discharging" && now_v > 0) rem_h = (now_v / 1e6) / pw_w
              else if (st == "Charging" && full_v > now_v) rem_h = ((full_v - now_v) / 1e6) / pw_w
            }
          } else if (mode == "charge") {
            health = (design_v > 0) ? (100.0 * full_v / design_v) : 0
            if (v_ref > 0) {
              now_wh = (now_v / 1e6) * v_ref
              full_wh = (full_v / 1e6) * v_ref
              if (design_v > 0) {
                line3 = sprintf("容量: %.2f / %.2f Wh（%.2f / %.2f Ah / 健康度 %.0f%%）", now_wh, full_wh, now_v / 1e6, full_v / 1e6, health)
              } else {
                line3 = sprintf("容量: %.2f / %.2f Wh（%.2f / %.2f Ah）", now_wh, full_wh, now_v / 1e6, full_v / 1e6)
              }
              if (pw_w > 0.1) {
                if (st == "Discharging" && now_v > 0) rem_h = now_wh / pw_w
                else if (st == "Charging" && full_v > now_v) rem_h = (full_wh - now_wh) / pw_w
              }
            } else if (design_v > 0) {
              line3 = sprintf("容量: %.2f / %.2f Ah（健康度 %.0f%%）", now_v / 1e6, full_v / 1e6, health)
            } else {
              line3 = sprintf("容量: %.2f / %.2f Ah", now_v / 1e6, full_v / 1e6)
            }
          }

          line4 = ""
          if (has_pw && (pw_unit == "W" || v_ref > 0)) {
            sign = (st == "Charging") ? "+" : ((st == "Discharging") ? "-" : "")
            eta_str = ""
            if (rem_h > 0) {
              tot_m = int(rem_h * 60 + 0.5)
              hh = int(tot_m / 60)
              mm = tot_m % 60
              dur = (hh > 0) ? sprintf("%d時間%d分", hh, mm) : sprintf("%d分", mm)
              eta_ts = strftime("%H:%M", systime() + int(rem_h * 3600 + 0.5))
              if (st == "Charging") {
                eta_str = sprintf("  満充電まで %s (%s)", dur, eta_ts)
              } else if (st == "Discharging") {
                eta_str = sprintf("  残り %s (%s)", dur, eta_ts)
              }
            }
            line4 = sprintf("電力: %s%.2f W%s", sign, pw_w, eta_str)
          }

          tip = line1
          if (line2 != "") tip = tip "\n" line2
          if (line3 != "") tip = tip "\n" line3
          if (line4 != "") tip = tip "\n" line4

          if (cap == 0 && st == "Discharging" && vn > 5500000) {
            tip = tip "\n注: 残量 0% 表示でも電圧あり（満充電→空→満充電で較正）"
          } else if (raw_cap != "" && int(raw_cap + 0) != cap) {
            tip = tip sprintf("\n注: カーネル capacity=%s%%", raw_cap)
          }

          printf "%s\0%s\0%s\0", text, classes, tip
        }')

      jq -cn \
        --arg text "$text" \
        --arg tooltip "$tip" \
        --arg classes "$classes" \
        '{text: $text, tooltip: $tooltip, class: ($classes | split(" ") | map(select(length > 0)))}'
    '';
  };

  ntpSync = pkgs.writeShellApplication {
    name = "waybar-ntp-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      notify() {
        notify-send "$@" >/dev/null 2>&1 || true
      }

      if ! err="$(systemctl restart systemd-timesyncd.service 2>&1)"; then
        notify -u critical "NTP 時刻同期に失敗しました" "systemd-timesyncd の再起動が拒否または失敗しました: ''${err:-exit $?}"
        exit 1
      fi

      synced=0
      server=""
      status=""
      for _ in $(seq 1 20); do
        status="$(systemctl show -p StatusText --value systemd-timesyncd.service 2>/dev/null || true)"
        server="$(timedatectl show-timesync -p ServerName --value 2>/dev/null || true)"
        msg="$(timedatectl show-timesync -p NTPMessage --value 2>/dev/null || true)"
        if [ -n "$server" ] && [[ "$msg" != *"PacketCount=0"* ]]; then
          synced=1
          break
        fi
        sleep 0.25
      done

      pkill -SIGRTMIN+11 -x waybar >/dev/null 2>&1 || true

      now_jst="$(TZ="Asia/Tokyo" date '+%Y-%m-%d %H:%M:%S %Z')"
      now_utc="$(TZ="UTC" date '+%Y-%m-%d %H:%M:%S %Z')"
      if [ "$synced" -eq 1 ]; then
        body="$(printf '%s\n%s\n%s' "$now_jst" "$now_utc" "''${status:-server: $server}")"
        notify "NTP 時刻同期完了" "$body"
      else
        body="$(printf '%s\n%s\n%s' "$now_jst" "$now_utc" "''${status:-応答待ち（オフラインまたは同期待ち）}")"
        notify -u normal "NTP 時刻同期を要求しました" "$body"
      fi
    '';
  };

  # Dedicated left-dock JQuake slot: status indicator + click-to-open + right-click menu.
  waybarJquake = pkgs.writeShellApplication {
    name = "waybar-jquake";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      mapfile -t ust < <(
        systemctl --user is-active \
          jquake.service \
          stalonetray-jquake.service \
          jquake-hypr-alert.service 2>/dev/null || true
      )
      jq_s="''${ust[0]:-unknown}"
      st_s="''${ust[1]:-unknown}"
      al_s="''${ust[2]:-unknown}"

      is_open=0
      if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
        is_open=1
      fi

      glyph=$'\uf469'
      if [ "$jq_s" = "failed" ] || [ "$st_s" = "failed" ] || [ "$al_s" = "failed" ]; then
        cls="failed"
        glyph=$'\uf071'
        tip=$'✗ JQuake: 異常停止\njquake='"$jq_s"$' tray='"$st_s"$' alert='"$al_s"$'\n\n左クリックで起動・表示\n右クリックで管理メニュー'
      elif [ "$jq_s" = "active" ] && [ "$st_s" = "active" ] && [ "$al_s" = "active" ]; then
        if [ "$is_open" -eq 1 ]; then
          cls="open"
          tip=$'JQuake: 表示中\n\n左クリックでフォーカス\n右クリックで管理メニュー'
        else
          cls="active"
          tip=$'JQuake: 待機中（強震モニタ・EEW 監視）\n\n左クリックで表示\n右クリックで管理メニュー'
        fi
      else
        cls="degraded"
        tip=$'! JQuake: 停止中\njquake='"$jq_s"$' tray='"$st_s"$' alert='"$al_s"$'\n\n左クリックで起動・表示\n右クリックで管理メニュー'
      fi

      jq -cn --arg text "$glyph" --arg tooltip "$tip" --arg class "$cls" \
        '{text: $text, tooltip: $tooltip, class: $class}'
    '';
  };

  waybarJquakeOpen = pkgs.writeShellApplication {
    name = "waybar-jquake-open";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.libnotify
      pkgs.stalonetray
      pkgs.systemd
    ];
    text = ''
      refresh_jquake_bar() {
        systemctl --user kill --kill-who=main --signal=RTMIN+12 waybar.service >/dev/null 2>&1 || true
      }

      mapfile -t ust < <(
        systemctl --user is-active \
          stalonetray-jquake.service \
          jquake.service \
          jquake-hypr-alert.service 2>/dev/null || true
      )
      if [ "''${ust[0]:-}" != "active" ] || [ "''${ust[1]:-}" != "active" ] || [ "''${ust[2]:-}" != "active" ]; then
        systemctl --user reset-failed stalonetray-jquake.service jquake.service jquake-hypr-alert.service >/dev/null 2>&1 || true
        systemctl --user start stalonetray-jquake.service jquake.service jquake-hypr-alert.service
        refresh_jquake_bar
      fi

      if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
        ${hyprctlBin} dispatch 'hl.dsp.focus({ window = "class:^net-jquake-app-Main$" })' >/dev/null 2>&1 || true
        refresh_jquake_bar
        exit 0
      fi

      disp="''${DISPLAY:-:0}"
      clicked=0
      for _ in $(seq 1 40); do
        # Target AWT's child canvas directly so stalonetray hits XTrayIconPeer.
        if stalonetray -display "$disp" \
          --remote-click-icon sun-awt-X11-XCanvasPeer \
          --remote-click-button 1 \
          --remote-click-type double >/dev/null 2>&1; then
          clicked=1
          break
        fi
        sleep 0.25
      done

      if [ "$clicked" -eq 0 ]; then
        notify-send -u normal "JQuake" "トレイアイコンが見つかりません。状態を確認してください。" >/dev/null 2>&1 || true
        refresh_jquake_bar
        exit 1
      fi

      for _ in $(seq 1 20); do
        if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
          ${hyprctlBin} dispatch 'hl.dsp.focus({ window = "class:^net-jquake-app-Main$" })' >/dev/null 2>&1 || true
          break
        fi
        sleep 0.1
      done
      refresh_jquake_bar
    '';
  };

  waybarJquakeMenu = pkgs.writeShellApplication {
    name = "waybar-jquake-menu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.ghostty
      pkgs.rofi
      pkgs.systemd
    ];
    text = ''
            jq_s="$(systemctl --user is-active jquake.service 2>/dev/null || true)"
            if [ "$jq_s" = "active" ]; then
              toggle_label="JQuake [$jq_s] │ 停止"
            else
              toggle_label="JQuake [$jq_s] │ 開始"
            fi

            menu="$(cat <<EOF
      JQuake [$jq_s] │ ウィンドウを開く
      JQuake │ 再起動 (3ユニット)
      $toggle_label
      JQuake │ 状態・ログ表示
      EOF
            )"

            choice="$(printf '%s\n' "$menu" | ${rofiBin} -dmenu -i -p 'JQuake' || true)"
            [ -n "$choice" ] || exit 0

            refresh_jquake_bar() {
              systemctl --user kill --kill-who=main --signal=RTMIN+12 waybar.service >/dev/null 2>&1 || true
            }

            case "$choice" in
              *"ウィンドウを開く")
                exec ${lib.getExe waybarJquakeOpen}
                ;;
              *"再起動"*)
                systemctl --user reset-failed stalonetray-jquake.service jquake.service jquake-hypr-alert.service >/dev/null 2>&1 || true
                systemctl --user restart stalonetray-jquake.service jquake.service jquake-hypr-alert.service
                refresh_jquake_bar
                ;;
              *"停止")
                systemctl --user stop jquake.service jquake-hypr-alert.service stalonetray-jquake.service
                refresh_jquake_bar
                ;;
              *"開始")
                systemctl --user reset-failed stalonetray-jquake.service jquake.service jquake-hypr-alert.service >/dev/null 2>&1 || true
                systemctl --user start stalonetray-jquake.service jquake.service jquake-hypr-alert.service
                refresh_jquake_bar
                ;;
              *"状態・ログ表示")
                exec ${ghosttyBin} -e ${pkgs.bash}/bin/bash -lc "systemctl --user status jquake stalonetray-jquake jquake-hypr-alert --no-pager; echo; journalctl --user -u jquake -u stalonetray-jquake -u jquake-hypr-alert -n 30 --no-pager; printf '\n[Enter で閉じる] '; IFS= read -r _ || true"
                ;;
            esac
    '';
  };

  # Bottom of sideBar: background daemon & system status + interactive menu.
  waybarServices = pkgs.writeShellApplication {
    name = "waybar-services";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      mapfile -t ust < <(
        systemctl --user is-active \
          uniclipd.service \
          lan-mouse.service \
          taildrop-receive.service \
          cliphist-text.service \
          cliphist-image.service 2>/dev/null || true
      )
      mapfile -t sst < <(
        systemctl is-active \
          tailscaled.service \
          restic-backups-home.service \
          restic-backups-home.timer 2>/dev/null || true
      )

      uc_s="''${ust[0]:-unknown}"
      lm_s="''${ust[1]:-unknown}"
      td_s="''${ust[2]:-unknown}"
      ct_s="''${ust[3]:-unknown}"
      ci_s="''${ust[4]:-unknown}"

      ts_s="''${sst[0]:-unknown}"
      rb_s="''${sst[1]:-unknown}"
      rt_s="''${sst[2]:-unknown}"
      rb_res="$(systemctl show -p Result --value restic-backups-home.service 2>/dev/null || echo "")"

      overall="ok"
      mark_level() {
        case "$1" in
          failed) overall="failed" ;;
          warn)
            if [ "$overall" = "ok" ]; then
              overall="degraded"
            fi
            ;;
        esac
      }

      lines=()
      tips=("裏方デーモン・システム状態")

      add_icon() {
        local state="$1" glyph="$2"
        case "$state" in
          active)
            lines+=("<span color='${p.fgSecondary}'>''${glyph}</span>")
            ;;
          running)
            lines+=("<span color='${p.accent}'>''${glyph}</span>")
            ;;
          failed)
            mark_level failed
            lines+=("<span color='${p.danger}'>''${glyph}</span>")
            ;;
          *)
            mark_level warn
            lines+=("<span color='${p.warning}'>''${glyph}</span>")
            ;;
        esac
      }

      add_icon "$uc_s" $'\uf0ea'
      tips+=("• UniClipboard (uniclipd): $uc_s")

      add_icon "$lm_s" $'\uf245'
      tips+=("• LAN Mouse: $lm_s")

      add_icon "$td_s" $'\uf019'
      tips+=("• Taildrop Receive: $td_s")

      if [ "$ct_s" = "active" ] && [ "$ci_s" = "active" ]; then
        add_icon active $'\uf0c5'
        tips+=("• Cliphist (text/image): active / active")
      elif [ "$ct_s" = "failed" ] || [ "$ci_s" = "failed" ]; then
        add_icon failed $'\uf0c5'
        tips+=("✗ Cliphist: text=$ct_s image=$ci_s")
      else
        add_icon warn $'\uf0c5'
        tips+=("! Cliphist: text=$ct_s image=$ci_s")
      fi

      if [ "$ts_s" = "active" ]; then
        if [ -e /sys/class/net/tailscale0 ]; then
          add_icon active $'\uf0e8'
          tips+=("• Tailscale: active (tailscale0 UP)")
        else
          add_icon warn $'\uf0e8'
          tips+=("! Tailscale: active (tailscale0 未接続)")
        fi
      else
        add_icon "$ts_s" $'\uf0e8'
        tips+=("• Tailscale: $ts_s")
      fi

      if [ "$rb_s" = "active" ] || [ "$rb_s" = "activating" ]; then
        add_icon running $'\uf1c0'
        tips+=("↻ Restic Backup: 実行中 (timer=$rt_s)")
      elif [ "$rb_s" = "failed" ] || { [ -n "$rb_res" ] && [ "$rb_res" != "success" ]; }; then
        add_icon failed $'\uf1c0'
        tips+=("✗ Restic Backup: service=$rb_s result=$rb_res (timer=$rt_s)")
      elif [ "$rt_s" = "active" ]; then
        add_icon active $'\uf1c0'
        tips+=("• Restic Backup: 待機 (timer active / 正常)")
      else
        add_icon "$rt_s" $'\uf1c0'
        tips+=("! Restic Backup: timer=$rt_s service=$rb_s")
      fi

      tips+=("")
      tips+=("クリックでサービス管理メニュー")

      IFS=$'\n'
      text="''${lines[*]}"
      tooltip="''${tips[*]}"
      unset IFS
      jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$overall" \
        '{text: $text, tooltip: $tooltip, class: $class}'
    '';
  };

  waybarServicesMenu = pkgs.writeShellApplication {
    name = "waybar-services-menu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.ghostty
      pkgs.rofi
      pkgs.systemd
      pkgs.yazi
      hyprExec
    ];
    text = ''
            u_state() { systemctl --user is-active "$1" 2>/dev/null || true; }
            s_state() { systemctl is-active "$1" 2>/dev/null || true; }
            toggle_verb() { if [ "$1" = "active" ]; then printf '停止'; else printf '開始'; fi; }
            run_term() {
              local cmd="$1"
              ${ghosttyBin} -e ${pkgs.bash}/bin/bash -lc "$cmd; printf '\n[Enter で閉じる] '; IFS= read -r _ || true"
            }
            refresh_bar() {
              systemctl --user kill --kill-who=main --signal=RTMIN+10 waybar.service >/dev/null 2>&1 || true
            }

            uc_s="$(u_state uniclipd.service)"
            lm_s="$(u_state lan-mouse.service)"
            td_s="$(u_state taildrop-receive.service)"
            ct_s="$(u_state cliphist-text.service)"
            ci_s="$(u_state cliphist-image.service)"
            ts_s="$(s_state tailscaled.service)"
            rb_s="$(s_state restic-backups-home.service)"
            rt_s="$(s_state restic-backups-home.timer)"

            menu="$(cat <<EOF
      UniClipboard [$uc_s] │ 再起動
      UniClipboard [$uc_s] │ $(toggle_verb "$uc_s")
      UniClipboard │ GUI を開く
      LAN Mouse [$lm_s] │ 再起動
      LAN Mouse [$lm_s] │ $(toggle_verb "$lm_s")
      LAN Mouse │ GUI を開く
      Taildrop Receive [$td_s] │ 再起動
      Taildrop Receive [$td_s] │ $(toggle_verb "$td_s")
      Taildrop │ ~/Downloads を yazi で開く
      Cliphist [t:$ct_s i:$ci_s] │ 再起動
      Cliphist │ 履歴メニューを開く
      Tailscale [$ts_s] │ Trayscale GUI を開く
      Tailscale │ 状態・IP確認 (tailscale status)
      Tailscale │ デーモン再起動 (sudo)
      Restic [$rb_s / timer:$rt_s] │ 状態 (backup status)
      Restic │ ログ表示 (backup log)
      Restic │ 今すぐバックアップ (sudo backup run)
      EOF
            )"

            choice="$(printf '%s\n' "$menu" | ${rofiBin} -dmenu -i -p 'サービス管理' || true)"
            [ -n "$choice" ] || exit 0

            case "$choice" in
              *"UniClipboard"*"再起動")
                systemctl --user restart uniclipd.service
                refresh_bar
                ;;
              *"UniClipboard"*"開始")
                systemctl --user start uniclipd.service
                refresh_bar
                ;;
              *"UniClipboard"*"停止")
                systemctl --user stop uniclipd.service
                refresh_bar
                ;;
              *"UniClipboard"*"GUI を開く")
                exec ${hyprExecBin} uniclipboard
                ;;
              *"LAN Mouse"*"再起動")
                systemctl --user restart lan-mouse.service
                refresh_bar
                ;;
              *"LAN Mouse"*"開始")
                systemctl --user start lan-mouse.service
                refresh_bar
                ;;
              *"LAN Mouse"*"停止")
                systemctl --user stop lan-mouse.service
                refresh_bar
                ;;
              *"LAN Mouse"*"GUI を開く")
                exec ${hyprExecBin} lan-mouse
                ;;
              *"Taildrop Receive"*"再起動")
                systemctl --user restart taildrop-receive.service
                refresh_bar
                ;;
              *"Taildrop Receive"*"開始")
                systemctl --user start taildrop-receive.service
                refresh_bar
                ;;
              *"Taildrop Receive"*"停止")
                systemctl --user stop taildrop-receive.service
                refresh_bar
                ;;
              *"Taildrop"*"yazi"*)
                exec ${hyprExecBin} "${ghosttyBin}" -e "${yaziBin}" "$HOME/Downloads"
                ;;
              *"Cliphist"*"再起動")
                systemctl --user restart cliphist-text.service cliphist-image.service
                refresh_bar
                ;;
              *"Cliphist"*"履歴メニューを開く")
                exec ${hyprExecBin} clipboard-history
                ;;
              *"Tailscale"*"Trayscale"*)
                exec ${hyprExecBin} trayscale
                ;;
              *"Tailscale"*"tailscale status"*)
                run_term "tailscale status"
                ;;
              *"Tailscale"*"sudo"*)
                run_term "sudo systemctl restart tailscaled.service && tailscale status"
                refresh_bar
                ;;
              *"Restic"*"backup status"*)
                run_term "backup status"
                ;;
              *"Restic"*"backup log"*)
                run_term "backup log"
                ;;
              *"Restic"*"sudo backup run"*)
                run_term "sudo backup run"
                refresh_bar
                ;;
            esac
    '';
  };

  # Searchable / clickable cheatsheet (rofi -dmenu).
  # - keys only → notify-send (no key injection)
  # - run + mode=term → Ghostty interactive shell
  # - run + mode=exec → hypr-exec (Hyprland hl.dsp.exec_cmd)
  # - run + mode=show → Ghostty shows command; does not run (dangerous)
  cheatsheetEntries = lib.flatten [
    # 起動・終了
    {
      section = "起動・終了";
      label = "Ghostty";
      keys = "Super+Return / Ctrl+Alt+T";
    }
    {
      section = "起動・終了";
      label = "rofi（アクティブ WS に起動）";
      keys = "Super+D / Alt+Space";
    }
    {
      section = "起動・終了";
      label = "rofi コマンド実行（Enter / 端末: Shift+Enter）";
      keys = "Super+P";
    }
    {
      section = "起動・終了";
      label = "Zed エディタ";
      run = "zeditor";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "ウィンドウを閉じる";
      keys = "Super+Q / Super+Shift+Q";
    }
    {
      section = "起動・終了";
      label = "画面ロック (hyprlock)";
      keys = "Super+L";
    }
    {
      section = "起動・終了";
      label = "Hyprland 設定リロード";
      run = "${hyprctlBin} reload config-only";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "ログアウト (Hyprland 終了)";
      run = "uwsm stop";
      mode = "show";
    }
    {
      section = "起動・終了";
      label = "再起動";
      run = "systemctl reboot";
      mode = "show";
    }
    {
      section = "起動・終了";
      label = "シャットダウン";
      run = "systemctl poweroff";
      mode = "show";
    }
    {
      section = "起動・終了";
      label = "このシート（waybar ?）";
      keys = "Super+/";
    }
    {
      section = "起動・終了";
      label = "注: ELECOM は Win+Shift 同時押しが欠けること有 → Super+Q 等";
    }
    # ウィンドウ・WS
    {
      section = "ウィンドウ・WS";
      label = "フォーカス移動（右は Right、Super+L はロック）";
      keys = "Super+矢印 / Super+H/J/K";
    }
    {
      section = "ウィンドウ・WS";
      label = "ウィンドウ移動";
      keys = "Super+Shift+矢印 / H/J/K/L";
    }
    {
      section = "ウィンドウ・WS";
      label = "フルスクリーン / 最大化（バー維持）";
      keys = "Super+F / Super+Shift+F";
    }
    {
      section = "ウィンドウ・WS";
      label = "リサイズモード（矢印/hjkl, Esc/Enter終了）";
      keys = "Super+R";
    }
    {
      section = "ウィンドウ・WS";
      label = "フローティング切替 / 中央寄せ";
      keys = "Super+Shift+Space / Super+C";
    }
    {
      section = "ウィンドウ・WS";
      label = "分割方向トグル / 疑似タイル (dwindle)";
      keys = "Super+B / Super+Alt+P";
    }
    {
      section = "ウィンドウ・WS";
      label = "グループ（タブ）切替 / タブ移動 / ロック";
      keys = "Super+G / Super+(Shift+)Tab / Super+Alt+G";
    }
    {
      section = "ウィンドウ・WS";
      label = "スクラッチパッド表示 / 退避 (special:magic)";
      keys = "Super+S / Super+Alt+S";
    }
    {
      section = "ウィンドウ・WS";
      label = "新しい空き WS へ移動";
      keys = "Super+N";
    }
    {
      section = "ウィンドウ・WS";
      label = "WS 切替 / ウィンドウ移動（1〜9, 0=10）";
      keys = "Super+1…0 / Super+Shift+1…0";
    }
    {
      section = "ウィンドウ・WS";
      label = "マウス移動・リサイズ / WS スクロール";
      keys = "Super+左・右ドラッグ / Super+ホイール";
    }
    {
      section = "ウィンドウ・WS";
      label = "タッチパッド WS 切替";
      keys = "3本指 水平スワイプ";
    }
    {
      section = "ウィンドウ・WS";
      label = "注: Super+E は Yazi、外部リンクは Vivaldi へ自動フォーカス";
    }
    # スクショ・音量・輝度・履歴
    {
      section = "スクショ・音量・輝度";
      label = "範囲選択 → Satty 編集・コピー (hyprshot)";
      keys = "Super+Shift+S / Shift+Print";
      run = "${lib.getExe screenshotBin} region";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "全画面（出力） → Satty 切り抜き・編集・コピー (hyprshot)";
      keys = "Print";
      run = "${lib.getExe screenshotBin} full";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "ウィンドウ → Satty 編集 (hyprshot)";
      keys = "Super+Print";
      run = "${lib.getExe screenshotBin} window";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "スクショメニュー（即コピー含む）";
      run = "${lib.getExe screenshotBin} menu";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "カラーピッカー（コピー）";
      keys = "Super+Shift+P";
      run = "${hyprpickerBin} -a";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "クリップボード履歴（rofi）";
      keys = "Super+V";
    }
    {
      section = "スクショ・音量・輝度";
      label = "±5%（音量は最大100%） / ミュート / 輝度";
      keys = "音量 / MicMute / 輝度キー";
    }
    {
      section = "スクショ・音量・輝度";
      label = "起動音メニュー（一覧・編集・ON/OFF・再生）";
      keys = "左バー ♪";
      run = "startup-sound --menu";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "起動音をランダム再生（テスト）";
      run = "startup-sound";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "起動音 ON/OFF 切替";
      run = "startup-sound --toggle-and-notify";
      mode = "exec";
    }
    {
      section = "スクショ・音量・輝度";
      label = "起動音一覧 (CLI)";
      run = "startup-sound --list";
      mode = "term";
    }
    # 入力（Chromebook / VAIO）
    {
      section = inputSection;
      label = "IME 有効/無効（Meltype）";
      keys = "Super+Space";
    }
    {
      section = inputSection;
      label = "Meltype 内: 英数 ⇔ 日本語";
      keys = "半角/全角";
    }
    {
      section = inputSection;
      label = "注: Cursor=General（AppRules）。Code だと矢印で英数に戻る";
    }
    {
      section = inputSection;
      label = "注: rofi は AppRules _empty=OFF（Wayland program 空）+ wayland-layer=top";
    }
    {
      section = inputSection;
      label = "←↓↑→ ・ … など";
      keys = "zh/zj/zk/zl / z/ z.";
    }
    {
      section = inputSection;
      label = "ChatGPT で英語のまま戻らない → 再起動";
      keys = "ShareInputState + Meltype先頭";
    }
    {
      section = inputSection;
      label = "Cursor で Meltype → 終了して開き直す";
      keys = "Wayland IME フラグ";
    }
    {
      section = inputSection;
      label = "~/.local/share/Meltype";
      keys = "学習データ";
    }
    (
      if isChromebook then
        [
          {
            section = inputSection;
            label = "右クリック（Chromebook）";
            keys = "2本指タップ・押下";
          }
          {
            section = inputSection;
            label = "F1–F10（3つ目=セッション）";
            keys = "Search+最上段";
          }
          {
            section = inputSection;
            label = "手動 OOM（内蔵=C-A-Bksp）";
            keys = "Ctrl+Alt+Del";
          }
          {
            section = inputSection;
            label = "suspend / poweroff";
            keys = "電源 短/長押し";
          }
          {
            section = inputSection;
            label = "強制ログアウト / 再起動";
            keys = "電源+Back / +Refresh";
          }
        ]
      else
        [
          {
            section = inputSection;
            label = "右クリック（タッチパッド）";
            keys = "2本指タップ・押下";
          }
          {
            section = inputSection;
            label = "スクロール速度（タッチパッド）";
            keys = "scroll_factor 0.6";
          }
          {
            section = inputSection;
            label = "手動 OOM（C-A-Bksp も可）";
            keys = "Ctrl+Alt+Del";
          }
          {
            section = inputSection;
            label = "suspend / poweroff";
            keys = "電源 短/長押し";
          }
          {
            section = inputSection;
            label = "強制ログアウト / 再起動";
            keys = "電源+F1 / +F2";
          }
        ]
    )
    {
      section = inputSection;
      label = "Windows / Mac モード";
      keys = "ELECOM Fn+Q / Fn+W";
    }
    {
      section = inputSection;
      label = "注: ELECOM を Mac のままにすると Ctrl↔Win が入れ替わる";
    }
    # Yazi / Neovim
    {
      section = "Yazi / Neovim";
      label = "Yazi（Ghostty 内）";
      keys = "Super+E";
      run = yaziBin;
      mode = "term";
    }
    {
      section = "Yazi / Neovim";
      label = "隠し表示 / spot / 開く";
      keys = ". / Tab / Enter";
    }
    {
      section = "Yazi / Neovim";
      label = "特定アプリで開く";
      keys = "O";
    }
    {
      section = "Yazi / Neovim";
      label = "パス / 親dir / 名前 コピー";
      keys = "cc / cd / cf";
    }
    {
      section = "Yazi / Neovim";
      label = "シェル / フィルタ / zoxide";
      keys = "; / : / f / z";
    }
    {
      section = "Yazi / Neovim";
      label = "終了後その dir へ cd";
      keys = "y（bash）";
    }
    {
      section = "Yazi / Neovim";
      label = "nvim リーダー";
      keys = "Space";
    }
    {
      section = "Yazi / Neovim";
      label = "ツリー / ファイル / 全文検索";
      keys = "Space e / ff / sg";
    }
    {
      section = "Yazi / Neovim";
      label = "隠しファイル既定ON（切替: ツリー H / 検索 Alt-h）";
      keys = "H / Alt-h";
    }
    {
      section = "Yazi / Neovim";
      label = "定義 / 参照 / ホバー";
      keys = "gd / gr / K";
    }
    # Waybar・日常
    {
      section = "Waybar・日常";
      label = "チートシート / 常時オン切替";
      keys = "? / 󰾪 (上バー)";
    }
    {
      section = "Waybar・日常";
      label = "btop";
      keys = "CPU/MEM クリック";
      run = btopBin;
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "nmtui";
      keys = "ネットクリック";
      run = nmtuiBin;
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "NTP 時刻同期";
      keys = "中央時計クリック";
      run = lib.getExe ntpSync;
      mode = "exec";
    }
    {
      section = "Waybar・日常";
      label = "バックアップ進捗";
      keys = "[restic]（上バー WS の右）";
    }
    {
      section = "Waybar・日常";
      label = "5分暗転 / 10分ロック / 15分消灯 (hypridle)";
      keys = "無操作";
    }
    {
      section = "Waybar・日常";
      label = "LAN 送受信 / キー表示（rofi）";
      keys = "LocalSend / showmethekey";
    }
    {
      section = "Waybar・日常";
      label = "AI（rofi から）";
      keys = "ChatGPT / Grok";
    }
    {
      section = "Waybar・日常";
      label = "Teams 等 PWA が開かない";
      keys = "古い /nix/store の Exec → vivaldi-pwa-desktop-fix";
    }
    {
      section = "Waybar・日常";
      label = "Vivaldi PWA ショートカット修復";
      run = "vivaldi-pwa-desktop-fix";
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "Vivaldi 拡張が全部壊れている";
      keys = "Extensions 欠落 → Vivaldi終了後に vivaldi-extensions-repair";
    }
    {
      section = "Waybar・日常";
      label = "Vivaldi 拡張を CRX キャッシュから復旧";
      run = "vivaldi-extensions-repair";
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "Vivaldi ChatGPT 拡張が真っ白";
      keys = "setOptions 非対応 → パッチ版を Load unpacked";
    }
    {
      section = "Waybar・日常";
      label = "ChatGPT 拡張パッチ再生成";
      run = "vivaldi-chatgpt-extension-patch";
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "パッチ版パス (~/.local/share/…)";
      keys = "vivaldi-chatgpt-extension";
    }
    # Cursor 進捗（他アプリ使用中）
    {
      section = "Cursor 進捗";
      label = "完了・入力待ち → mako";
      keys = "Settings の通知";
    }
    {
      section = "Cursor 進捗";
      label = "Agents Window";
      keys = "パレット: Open Agents Window";
    }
    {
      section = "Cursor 進捗";
      label = "ブラウザ / スマホ PWA";
      keys = "cursor.com/agents";
    }
    {
      section = "Cursor 進捗";
      label = "実行中一覧（Slack）";
      keys = "@Cursor list my agents";
    }
    # NixOS
    {
      section = "NixOS";
      label = "更新チェック（左バー ）";
      run = "flake-update-check";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "全アプリ＋flake 入力更新（rebuild 選択付き）";
      run = "flake-update";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "Cursor だけ更新（nixpkgs-cursor）";
      run = "flake-update-cursor";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "適用（sudo 後・nom ETA）";
      run = "rebuild";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "注: hiragino-otf があるとき rebuild は --impure";
    }
    {
      section = "NixOS";
      label = "世代一覧";
      run = "generations";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "壊れたとき → --rollback switch";
      run = "sudo nixos-rebuild --rollback switch";
      mode = "show";
    }
    {
      section = "NixOS";
      label = "時刻同期状態";
      run = "timedatectl status";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "NTP 有効化（時計ずれ時）";
      run = "sudo timedatectl set-ntp true";
      mode = "show";
    }
    {
      section = "NixOS";
      label = "前回ブートの err ログ";
      run = "journalctl -b -1 -p err..alert --no-pager";
      mode = "term";
    }
    {
      section = "NixOS";
      label = "前回ブートの coredump";
      run = "coredumpctl -b -1 list";
      mode = "term";
    }
    # 開発
    {
      section = "開発";
      label = "OpenCode";
      run = "opencode";
      mode = "term";
    }
    {
      section = "開発";
      label = "Claude Code";
      run = "claude";
      mode = "term";
    }
    {
      section = "開発";
      label = "T3 Code（サーバ + Web）";
      run = "t3";
      mode = "term";
    }
    {
      section = "開発";
      label = "T3 Code Desktop";
      run = "t3code-desktop";
      mode = "exec";
    }
    {
      section = "開発";
      label = "Hermes";
      run = "hermes";
      mode = "term";
    }
    {
      section = "開発";
      label = "Hermes 初回セットアップ";
      run = "hermes setup";
      mode = "term";
    }
    {
      section = "開発";
      label = "Hermes ACP 確認";
      run = "hermes acp --check";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity（思考日本語訳: 現在設定に従う）";
      run = "agy";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity（今回だけ思考日本語訳 ON）";
      run = "agy --translate";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity（全許可）";
      run = "agy --dangerously-skip-permissions";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity（今回だけ翻訳なし）";
      run = "agy --no-translate";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity 思考翻訳 ON/OFF 切替";
      run = "agy-ja toggle";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity 思考翻訳 状態確認";
      run = "agy-ja status";
      mode = "term";
    }
    {
      section = "開発";
      label = "PLaMo 翻訳サーバー停止（RAM解放）";
      run = "plamo-translate stop";
      mode = "term";
    }
    {
      section = "開発";
      label = "Local LLM WebUI（Qwen3.5-4B）";
      run = "local-llm web";
      mode = "exec";
    }
    {
      section = "開発";
      label = "Local LLM 対話チャット（Qwen3.5-4B）";
      run = "local-llm chat";
      mode = "term";
    }
    {
      section = "開発";
      label = "Local LLM 状態確認（API URL・RSS）";
      run = "local-llm status";
      mode = "term";
    }
    {
      section = "開発";
      label = "Local LLM サーバー停止（RAM解放）";
      run = "local-llm stop";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity（Remote Control 有効で起動）";
      run = "agy --remote-control";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity Remote Control 状態確認";
      run = "agy remote-control status";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity Remote Control デーモン再起動";
      run = "systemctl --user restart antigravity-cli-daemon";
      mode = "term";
    }
    {
      section = "開発";
      label = "Antigravity Remote Control ログ確認";
      run = "journalctl --user -u antigravity-cli-daemon -n 50 --no-pager";
      mode = "term";
    }
    {
      section = "開発";
      label = "注: agy 起動中は F9 / Ctrl+b t / ステータスバークリックで翻訳ペインを即 ON/OFF";
    }
    {
      section = "開発";
      label = "注: 対話中は /remote-control でも接続可 / 別端末は https://antigravity.google.com を開く";
    }
    {
      section = "開発";
      label = "dsh-TUI";
      run = "dsh-tui";
      mode = "term";
    }
    {
      section = "開発";
      label = "dsh-TUI 更新";
      run = "npm i -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui";
      mode = "term";
    }
    {
      section = "開発";
      label = "pnpm / node";
      run = "pnpm --version; node --version";
      mode = "term";
    }
    {
      section = "開発";
      label = "Typst コンパイル（PDF）";
      run = "typst compile main.typ";
      mode = "term";
    }
    {
      section = "開発";
      label = "Typst 監視コンパイル";
      run = "typst watch main.typ";
      mode = "term";
    }
    {
      section = "開発";
      label = "Cursor: Tinymist プレビュー";
      keys = "コマンドパレット → Typst Preview";
    }
    {
      section = "開発";
      label = "一時停止 → バックグラウンド";
      keys = "Ctrl+Z → bg";
    }
    {
      section = "開発";
      label = "ジョブ一覧 / 前面復帰";
      run = "jobs; fg  # または fg %1";
      mode = "show";
    }
    {
      section = "開発";
      label = "ジョブ kill";
      run = "kill %1  # 強制: kill -9 %1";
      mode = "show";
    }
    # ディスク容量
    {
      section = "ディスク容量";
      label = "df / lsblk";
      run = "df -hT /; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "disktui（パーティション管理 TUI）";
      run = "disktui";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "du home top";
      run = "du -xh --max-depth=1 ~ | sort -hr | head";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "ユーザーGC（sudo不要・死んだパス）";
      run = "nix-collect-garbage";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "旧世代削除＋GC（危険）";
      run = "sudo nix-collect-garbage -d";
      mode = "show";
    }
    {
      section = "ディスク容量";
      label = "ストア重複をハードリンク最適化";
      run = "sudo nix store optimise";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "ログ使用量（上限1G）";
      run = "journalctl --disk-usage";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "journal を 200M に真空";
      run = "sudo journalctl --vacuum-size=200M";
      mode = "show";
    }
    {
      section = "ディスク容量";
      label = "/tmp remotion 残骸削除";
      run = "rm -rf /tmp/remotion-* /tmp/react-motion-render* && df -h /";
      mode = "show";
    }
    {
      section = "ディスク容量";
      label = "Downloads .tmp 残骸確認";
      run = "du -sh ~/Downloads/.tmp_* 2>/dev/null; ls -la ~/Downloads/.tmp_* 2>/dev/null";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "restic-bak 残骸確認（復元済みなら削除可）";
      run = "du -sh ~/restic-bak; du -xh --max-depth=2 ~/restic-bak | sort -hr | head";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "ゴミ箱を空にする";
      run = "find ~/.local/share/Trash/files ~/.local/share/Trash/info -mindepth 1 -delete; rm -rf ~/.local/share/Trash/info && mkdir -p ~/.local/share/Trash/files ~/.local/share/Trash/info; du -sh ~/.local/share/Trash";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "PIO download cache 削除";
      run = "rm -rf ~/.platformio/.cache && du -sh ~/.platformio";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "npm npx キャッシュ削除";
      run = "rm -rf ~/.npm/_npx && du -sh ~/.npm";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "PIO 版付き toolchain 重複削除";
      run = "rm -rf ~/.platformio/packages/toolchain-*@* && ls -d ~/.platformio/packages/toolchain-*";
      mode = "show";
    }
    {
      section = "ディスク容量";
      label = "Cursor agent 旧 versions 削除（最新以外）";
      run = "d=~/.config/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions; keep=$(ls -1 \"$d\" | sort | tail -1); for x in \"$d\"/*; do [ \"$(basename \"$x\")\" = \"$keep\" ] || rm -rf \"$x\"; done; rm -rf ~/.local/share/cursor-agent/versions/*; ls \"$d\"";
      mode = "show";
    }
    (lib.optionals isChromebook [
      {
        section = "ディスク容量";
        label = "注: ChromeOS残骸(p1/p3/p5)は root の前。拡大は LiveUSB";
      }
    ])
    # ネット・BT・WARP
    {
      section = "ネット・BT・WARP";
      label = "Wi-Fi 設定（nmtui）";
      run = nmtuiBin;
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "SSID一覧";
      run = "nmcli device wifi list";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "SSID接続（保存済み）";
      run = "nmcli connection up id 'SSID'";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "SSID接続（新規・PSK）";
      run = "nmcli device wifi connect 'SSID' password 'PASSWORD'";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "隠しSSID接続（PSK）";
      run = "nmcli connection add type wifi con-name 'SSID' ssid 'SSID' wifi.hidden yes wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'PASSWORD' && nmcli connection up 'SSID'";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "注: 隠しSSIDは nmtui → Edit → Add → Wi-Fi → SSID手入力 → Hidden: Yes";
    }
    {
      section = "ネット・BT・WARP";
      label = "学校Wi-Fi: Hazamaru AP-{E,tr,U,Ryo} / eduroam（PEAP・同一PW）";
    }
    {
      section = "ネット・BT・WARP";
      label = "学校Wi-Fi 再作成（AP-EのPW流用）";
      run = "PASS=$(nmcli -s -g 802-1x.password connection show 'Hazamaru AP-E'); for n in 'Hazamaru AP-tr' 'Hazamaru AP-U' 'Hazamaru AP-Ryo'; do nmcli connection add type wifi con-name \"$n\" ifname '*' ssid \"$n\" wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 802-1x.identity s24184 802-1x.password \"$PASS\" || true; done; nmcli connection add type wifi con-name eduroam ifname '*' ssid eduroam wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 802-1x.identity s24184@tokyo-ct.ac.jp 802-1x.password \"$PASS\" || true; unset PASS";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "PC を起動（Wake-on-LAN）";
      run = "wake-pc";
      mode = "exec";
    }
    {
      section = "ネット・BT・WARP";
      label = "全 IF の IP";
      run = "ip -br addr";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "warp-cli connect";
      run = "warp-cli --accept-tos connect";
      mode = "exec";
    }
    {
      section = "ネット・BT・WARP";
      label = "warp-cli disconnect";
      run = "warp-cli --accept-tos disconnect";
      mode = "exec";
    }
    {
      section = "ネット・BT・WARP";
      label = "warp-cli status";
      run = "warp-cli --accept-tos status";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "bluetoothctl";
      run = "bluetoothctl";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "注: BT 音声は接続後 出力シンク選択が要ることあり";
    }
    {
      section = "ネット・BT・WARP";
      label = "Parsec（通常）";
      run = "parsec";
      mode = "exec";
    }
    {
      section = "ネット・BT・WARP";
      label = "Parsec via Tailscale（WARP 切＋ping）";
      run = "parsec-ts";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "ts-home-routes on（外出時だけ）";
      run = "ts-home-routes on";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "ts-home-routes off（帰宅後）";
      run = "ts-home-routes off";
      mode = "term";
    }
    {
      section = "ネット・BT・WARP";
      label = "注: Parsec -6023 → ホスト config に app_custom_address=100.102.102.53。自宅では accept-routes 禁止";
    }
    {
      section = "ネット・BT・WARP";
      label = "RTSP 再生（mpv・低遅延+TCP）";
      run = "mpv --profile=low-latency --demuxer-lavf-o=rtsp_transport=tcp 'rtsp://user:pass@host:554/path'";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "RTSP 診断（ffplay・TCP）";
      run = "ffplay -rtsp_transport tcp 'rtsp://user:pass@host:554/path'";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "RTSP 録画 TCP（ffmpeg・copy）";
      run = "ffmpeg -rtsp_transport tcp -i 'rtsp://user:pass@host:554/path' -c copy ~/Videos/rtsp-$(date +%Y%m%d-%H%M%S).mkv";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "IP Webcam 録画 UDP（genpts・copy）";
      run = "ffmpeg -rtsp_transport udp -fflags +genpts -i 'rtsp://172.29.33.7:8080/h264_ulaw.sdp' -c copy -avoid_negative_ts make_zero ~/Videos/ipcam-$(date +%Y%m%d-%H%M%S).mkv";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "IP Webcam 録画 UDP（バッファ大・遅延OK）";
      run = "ffmpeg -rtsp_transport udp -fflags +genpts -max_delay 5000000 -reorder_queue_size 10000 -buffer_size 16M -i 'rtsp://172.29.33.7:8080/h264_ulaw.sdp' -c copy -avoid_negative_ts make_zero ~/Videos/ipcam-$(date +%Y%m%d-%H%M%S).mkv";
      mode = "show";
    }
    {
      section = "ネット・BT・WARP";
      label = "注: バッファは遅延・並べ替え向け。本当に落ちた RTP は復元不可 → 解像度↓/同一LAN/TCP";
    }
    # 3D印刷
    {
      section = "3D印刷";
      label = "Orca Slicer";
      run = "orca-slicer";
      mode = "exec";
    }
    # Windows / Chromebook 連携
    {
      section = "端末連携";
      label = "lan-mouse GUI（先に stop daemon）";
      run = "lan-mouse";
      mode = "exec";
    }
    {
      section = "端末連携";
      label = "lan-mouse クライアント一覧";
      run = "lan-mouse cli list";
      mode = "term";
    }
    {
      section = "端末連携";
      label = "stop lan-mouse";
      run = "systemctl --user stop lan-mouse";
      mode = "exec";
    }
    {
      section = "端末連携";
      label = "start lan-mouse";
      run = "systemctl --user start lan-mouse";
      mode = "exec";
    }
    {
      section = "端末連携";
      label = "uniclipboard GUI";
      run = "uniclipboard";
      mode = "exec";
    }
    {
      section = "端末連携";
      label = "restart uniclipd";
      run = "systemctl --user restart uniclipd";
      mode = "exec";
    }
    {
      section = "端末連携";
      label = "注: vaio 左端 → chromebook (ReGreet ログイン画面も可・解除 Ctrl+Shift+Super+Alt)";
    }
    {
      section = "端末連携";
      label = "注: uniclip は --user。再起動後は GUI も開き直す";
    }
    {
      section = "端末連携";
      label = "注: 起動失敗(1223)→ seahorse で鍵環解錠。版上げは flake";
    }
    # バックアップ
    {
      section = "バックアップ";
      label = "backup（使い方）";
      run = "backup";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup run";
      run = "backup run";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup log";
      run = "backup log";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup status";
      run = "backup status";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup snapshots";
      run = "backup snapshots";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup restore … --target /tmp/restore（必須・危険）";
      run = "backup restore … --target /tmp/restore";
      mode = "show";
    }
    {
      section = "バックアップ";
      label = "全体復元（home+システム・上書き・要注意）";
      run = "cd ~/MySettings && ./scripts/restore-on-nixos.sh";
      mode = "show";
    }
    {
      section = "バックアップ";
      label = "別端末から新端末復元（--from --new-device）";
      run = "cd ~/MySettings && ./scripts/restore-on-nixos.sh --from vaio --new-device";
      mode = "show";
    }
    {
      section = "バックアップ";
      label = "backup reconnect";
      run = "backup reconnect";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup about";
      run = "backup about";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "注: --target なしは /home/mitac を上書き（危険）";
    }
    {
      section = "バックアップ";
      label = "注: リポジトリは端末別 (<host>-home)。他参照は RESTIC_REPOSITORY=…";
    }
    {
      section = "バックアップ";
      label = "注: --new-device は既存 ~/MySettings 保持＆端末ID/認証を再サインイン化";
    }
    {
      section = "バックアップ";
      label = "注: rclone / restic / Wi-Fi / Tailscale は agenix 一元管理（backup / rebuild とも rbw 解錠不要）";
    }
    # シークレット（Bitwarden × agenix）
    {
      section = "シークレット";
      label = "secrets status（鍵・/run/agenix 状態）";
      run = "secrets status";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "secrets check --decrypt（暗号・復号検証）";
      run = "secrets check --decrypt";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "secrets edit user-env（API キー・環境変数）";
      run = "secrets edit user-env";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "secrets import（既存認証を一括暗号化）";
      run = "secrets import";
      mode = "show";
    }
    {
      section = "シークレット";
      label = "更新: rclone 手動再取込（通常は backup reconnect が自動反映）";
      run = "secrets import-rclone && rebuild";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "更新: Wi-Fi / gh / SSH 再取込";
      run = "secrets import-wifi";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "Wi-Fi を agenix へマージ同期（nmcli 後など）";
      run = "secrets sync-wifi";
      mode = "term";
    }
    {
      section = "シークレット";
      label = "secrets bootstrap（新端末へ Bitwarden 鍵導入）";
      run = "secrets bootstrap";
      mode = "show";
    }
    {
      section = "シークレット";
      label = "注: 日常は nmcli/nmtui の Wi-Fi 変更も自動同期。その他変更時のみ import-* → git add → rebuild";
    }
    {
      section = "シークレット";
      label = "注: 共通鍵は Bitwarden (agenix-master-key) + /etc/agenix/master.key";
    }
    # 電源（Chromebook: 電源・Type-C / VAIO: 電源・省電力）
    {
      section = powerSection;
      label = "Capsomnia（Caps Lock で蓋閉じスリープ抑止・メニュー）";
      keys = "CapsLock / Super+Alt+c / Waybar ●";
      run = "${capsomniaPkg}/bin/capsomnia-menu";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "Capsomnia 設定画面（画面維持・自動オフタイマー・詳細）";
      run = "${capsomniaPkg}/bin/capsomnia-settings";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "輝度 40%（消費の主因を下げる）";
      run = "${brightnessctl} set 40%";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "バッテリー状態（電圧・健康度・W・残り）";
      run = "for b in /sys/class/power_supply/BAT*; do [ -d \"$b\" ] || continue; st=$(cat \"$b/status\"); cap=$(cat \"$b/capacity\"); vn=$(cat \"$b/voltage_now\"); if [ -r \"$b/energy_now\" ]; then en=$(cat \"$b/energy_now\"); ef=$(cat \"$b/energy_full\"); ed=$(cat \"$b/energy_full_design\"); pw=$(cat \"$b/power_now\"); awk -v nm=\"$(basename \"$b\")\" -v st=\"$st\" -v cap=\"$cap\" -v vn=\"$vn\" -v en=\"$en\" -v ef=\"$ef\" -v ed=\"$ed\" -v pw=\"$pw\" 'BEGIN{printf \"%s %s %s%%  V=%.2fV  now=%.2fWh full=%.2fWh design=%.2fWh health=%.0f%%  %.2fW  ETA=%.1fh\\n\", nm,st,cap,vn/1e6,en/1e6,ef/1e6,ed/1e6,(ed>0?100*ef/ed:0),pw/1e6,(pw>0?en/pw:0)}'; elif [ -r \"$b/charge_now\" ]; then cn=$(cat \"$b/charge_now\"); cf=$(cat \"$b/charge_full\"); cd=$(cat \"$b/charge_full_design\"); cw=$(cat \"$b/current_now\"); awk -v nm=\"$(basename \"$b\")\" -v st=\"$st\" -v cap=\"$cap\" -v vn=\"$vn\" -v cn=\"$cn\" -v cf=\"$cf\" -v cd=\"$cd\" -v cw=\"$cw\" 'BEGIN{if(cw<0)cw=-cw; pw=(vn/1e6)*(cw/1e6); en=(vn/1e6)*(cn/1e6); printf \"%s %s %s%%  V=%.2fV  now=%.2fAh full=%.2fAh design=%.2fAh health=%.0f%%  %.2fW  ETA=%.1fh\\n\", nm,st,cap,vn/1e6,cn/1e6,cf/1e6,cd/1e6,(cd>0?100*cf/cd:0),pw,(pw>0?en/pw:0)}'; fi; done";
      mode = "term";
    }
    {
      section = powerSection;
      label = "CPU消費プロセス上位";
      run = "ps -eo pcpu,pmem,rss,comm --sort=-pcpu | head -25";
      mode = "term";
    }
    {
      section = powerSection;
      label = "iowait / 負荷（vmstat）";
      run = "vmstat 1 5";
      mode = "term";
    }
    {
      section = powerSection;
      label = "iowait を CPU 別に見る";
      run = "nix run nixpkgs#sysstat -- mpstat -P ALL 1 5";
      mode = "term";
    }
    {
      section = powerSection;
      label = "NVMe/zram の待ち（iostat）";
      run = "nix run nixpkgs#sysstat -- iostat -xz -p ALL 1 5";
      mode = "term";
    }
    {
      section = powerSection;
      label = "注: 偽 iowait → i915_flip 張り付き。boot: i915.enable_psr=0 enable_dc=0";
    }
    {
      section = powerSection;
      label = "注: BAT capacity=0 なのに稼働＝ゲージ異常。満充電→空→満充電で較正";
    }
    {
      section = powerSection;
      label = "warp disconnect";
      run = "warp-cli --accept-tos disconnect";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "bt power off";
      run = "bluetoothctl power off";
      mode = "exec";
    }
    (lib.optionals isChromebook [
      {
        section = powerSection;
        label = "受電優先を再適用";
        run = "sudo chromebook-typec-prefer-sink";
        mode = "show";
      }
      {
        section = powerSection;
        label = "充電不可時: 抜く→mask→FORCE_SINK→挿す";
      }
    ])
    # 周辺
    {
      section = "周辺";
      label = "QtScrcpy";
      run = "QtScrcpy";
      mode = "exec";
    }
    {
      section = "周辺";
      label = "adb devices";
      run = "adb devices";
      mode = "term";
    }
    {
      section = "周辺";
      label = "ESP32 /dev/ttyUSB0（CH340・dialout 要）";
      keys = "/dev/ttyUSB0";
    }
    {
      section = "周辺";
      label = "arduino-cli compile|upload";
      run = "arduino-cli compile -b esp32:esp32:esp32";
      mode = "show";
    }
    {
      section = "周辺";
      label = "JQuake 表示（左バー クリックでも可）";
      run = "${lib.getExe waybarJquakeOpen}";
      mode = "exec";
    }
    {
      section = "周辺";
      label = "JQuake 状態（systemd）";
      run = "systemctl --user status jquake stalonetray-jquake jquake-hypr-alert";
      mode = "term";
    }
    {
      section = "周辺";
      label = "警報時は hyprlock 解除→前面化/全画面（緊急）";
    }
  ];

  cheatsheetDisplay =
    e:
    let
      body = if e ? keys then "${e.keys}  →  ${e.label}" else e.label;
      suffix = if e ? run then if (e.mode or "") == "show" then "  [確認]" else "  [実行]" else "";
    in
    "${e.section} │ ${body}${suffix}";

  cheatsheetJson = pkgs.writeText "hyprland-cheatsheet.json" (
    builtins.toJSON (
      map (e: {
        display = cheatsheetDisplay e;
        run = e.run or null;
        mode = e.mode or null;
        keys = e.keys or null;
        label = e.label;
      }) cheatsheetEntries
    )
  );

  # ghostty -e takes a single argv; command text arrives via CHEAT_RUN.
  cheatsheetTerm = pkgs.writeShellScript "hyprland-cheatsheet-term" ''
    set -eu
    exec ${pkgs.bash}/bin/bash -ic \
      "$CHEAT_RUN; printf '\n[Enter で閉じる] '; read -r _"
  '';
  cheatsheetShow = pkgs.writeShellScript "hyprland-cheatsheet-show" ''
    set -eu
    exec ${pkgs.bash}/bin/bash -ic \
      "printf '実行しません（手で入力してください）:\n  %s\n\n' \"$CHEAT_RUN\"; read -r _"
  '';

  showCheatsheet = pkgs.writeShellScript "hyprland-cheatsheet" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
        pkgs.libnotify
        pkgs.rofi
        pkgs.ghostty
        pkgs.bash
        hyprExec
      ]
    }:$PATH"
    data="${cheatsheetJson}"
    choice=$(
      jq -r '.[].display' "$data" \
        | ${rofiBin} -dmenu -i -p 'チートシート' -no-custom
    ) || exit 0
    [ -n "$choice" ] || exit 0

    entry=$(jq -c --arg c "$choice" '.[] | select(.display == $c)' "$data")
    [ -n "$entry" ] || exit 0

    run=$(jq -r '.run // empty' <<<"$entry")
    mode=$(jq -r '.mode // empty' <<<"$entry")
    keys=$(jq -r '.keys // empty' <<<"$entry")
    label=$(jq -r '.label' <<<"$entry")

    if [ -z "$run" ]; then
      if [ -n "$keys" ]; then
        notify-send -a cheatsheet "$keys" "$label"
      else
        notify-send -a cheatsheet "チートシート" "$label"
      fi
      exit 0
    fi

    case "$mode" in
      exec)
        exec ${hyprExecBin} "${pkgs.bash}/bin/bash" -c "$run"
        ;;
      show)
        export CHEAT_RUN="$run"
        exec ${ghosttyBin} -e ${cheatsheetShow}
        ;;
      term|*)
        export CHEAT_RUN="$run"
        exec ${ghosttyBin} -e ${cheatsheetTerm}
        ;;
    esac
  '';
in
{
  home.packages = [
    pkgs.hyprpaper
    pkgs.hypridle
    pkgs.hyprlock
    pkgs.hyprpicker
    pkgs.hyprshot
    pkgs.satty
    pkgs.brightnessctl
    pkgs.jq
    hyprExec
    screenshotBin
  ];

  # Unified Rofi Polkit authentication agent managed under UWSM graphical-session.target.
  systemd.user.services.rofi-polkit-agent = {
    Unit = {
      Description = "Rofi Polkit Authentication Agent (cmd-polkit)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.cmd-polkit} -s -c ${lib.getExe' pkgs.rofi-prompt "rofi-polkit"}";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  wayland.windowManager.hyprland = {
    enable = true;
    package = null; # Provided by NixOS programs.hyprland
    portalPackage = null; # Provided by NixOS xdg.portal
    systemd.enable = false; # UWSM manages graphical-session.target
    xwayland.enable = true;

    settings = {
      monitor = {
        output = "";
        mode = "preferred";
        position = "auto";
        scale = "auto";
      };

      config = {
        general = {
          gaps_in = 5;
          gaps_out = 10;
          border_size = 2;
          resize_on_border = true;
          allow_tearing = false;
          layout = "dwindle";
          col = {
            active_border = {
              colors = [
                "rgba(${p.accentHex}ee)"
                "rgba(${p.accentAltHex}ee)"
              ];
              angle = 45;
            };
            inactive_border = "rgba(${p.borderHex}aa)";
            nogroup_border = "rgba(${p.borderHex}aa)";
            nogroup_border_active = "rgba(${p.warningHex}ee)";
          };
        };

        decoration = {
          rounding = theme.radius.window;
          rounding_power = 2;
          active_opacity = 1.0;
          inactive_opacity = 0.96;
          shadow = {
            enabled = true;
            range = 18;
            render_power = 3;
            offset = [
              0
              4
            ];
            color = "rgba(05080d66)";
          };
          blur = {
            enabled = true;
            size = 6;
            passes = 2;
            new_optimizations = true;
            vibrancy = 0.16;
          };
        };

        animations = {
          enabled = true;
        };

        dwindle = {
          preserve_split = true;
          smart_resizing = true;
        };

        group = {
          col = {
            border_active = "rgba(${p.accentHex}ee)";
            border_inactive = "rgba(${p.borderHex}aa)";
            border_locked_active = "rgba(${p.warningHex}ee)";
            border_locked_inactive = "rgba(${p.borderHex}aa)";
          };
          groupbar = {
            enabled = true;
            font_family = theme.font.mono;
            font_size = 11;
            height = 22;
            indicator_height = 2;
            rounding = 6;
            gaps_in = 4;
            gaps_out = 4;
            col = {
              active = "rgba(${p.accentSoftHex}ee)";
              inactive = "rgba(${p.surfaceHex}dd)";
              locked_active = "rgba(${p.warningHex}44)";
              locked_inactive = "rgba(${p.surfaceHex}dd)";
            };
            text_color = "rgb(${p.fgHex})";
            text_color_inactive = "rgb(${p.fgMutedHex})";
          };
        };

        input = {
          kb_layout = "jp";
          numlock_by_default = true;
          follow_mouse = 1;
          sensitivity = 0;
          touchpad = {
            natural_scroll = false;
            tap_to_click = true;
            clickfinger_behavior = true;
            disable_while_typing = false;
          }
          // lib.optionalAttrs (!isChromebook) {
            scroll_factor = 0.6;
          };
        };

        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
          background_color = "rgb(${p.bgHex})";
          focus_on_activate = true;
          mouse_move_enables_dpms = true;
          key_press_enables_dpms = true;
          animate_manual_resizes = true;
          animate_mouse_windowdragging = true;
        };

        binds = {
          movefocus_cycles_fullscreen = true;
          movefocus_cycles_groupfirst = true;
        };

        layers = {
          allow_new_top_layers_over_existing_fullscreen = true;
        };

        xwayland = {
          force_zero_scaling = true;
        };
      };

      gesture = [
        {
          fingers = 3;
          direction = "horizontal";
          action = "workspace";
        }
      ];

      window_rule = [
        # Standard Hyprland rules: ignore unsolicited maximize events and XWayland ghost drags.
        {
          name = "suppress-maximize-events";
          match = {
            class = ".*";
          };
          suppress_event = "maximize";
        }
        {
          name = "fix-xwayland-drags";
          match = {
            class = "^$";
            title = "^$";
            xwayland = true;
            float = true;
            fullscreen = false;
            pin = false;
          };
          no_focus = true;
        }
        {
          name = "showmethekey-gtk";
          match = {
            class = "^(showmethekey-gtk)$";
          };
          float = true;
          pin = true;
          border_size = 0;
        }
        {
          name = "showmethekey-alynx";
          match = {
            class = "^(one\\.alynx\\.showmethekey)$";
          };
          float = true;
          pin = true;
        }
        {
          name = "satty-float";
          match = {
            class = "^(com\\.gabm\\.satty)$";
          };
          float = true;
        }
        {
          name = "portal-dialogs";
          match = {
            class = "^(xdg-desktop-portal-gtk)$";
          };
          float = true;
        }
      ];

      layer_rule = [
        {
          name = "waybar-frosted";
          match = {
            namespace = "^waybar$";
          };
          blur = true;
          ignore_alpha = 0.25;
        }
        {
          name = "rofi-frosted";
          match = {
            namespace = "^rofi$";
          };
          blur = true;
          ignore_alpha = 0.2;
          animation = "popin 92%";
        }
        {
          name = "mako-notifications";
          match = {
            namespace = "^notifications$";
          };
          blur = true;
          ignore_alpha = 0.2;
          animation = "slide right";
        }
      ];
    };

    extraConfig = ''
      -- Cursor size
      hl.env("XCURSOR_SIZE", "24")
      hl.env("HYPRCURSOR_SIZE", "24")

      -- Curves & fluid motion (Hyprland 0.57+ Lua animation spec)
      hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
      hl.curve("smoothOut",    { type = "bezier", points = { { 0.16, 1 }, { 0.30, 1 } } })
      hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } })
      hl.curve("quick",        { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })
      hl.curve("snappy",       { type = "spring", mass = 1, stiffness = 260, damping = 26 })

      hl.animation({ leaf = "global",           enabled = true, speed = 8,    bezier = "easeOutQuint" })
      hl.animation({ leaf = "border",           enabled = true, speed = 4.5,  bezier = "easeOutQuint" })
      hl.animation({ leaf = "windows",          enabled = true, speed = 4.5,  spring = "snappy" })
      hl.animation({ leaf = "windowsIn",        enabled = true, speed = 4.0,  spring = "snappy", style = "popin 88%" })
      hl.animation({ leaf = "windowsOut",       enabled = true, speed = 1.6,  bezier = "quick",  style = "popin 88%" })
      hl.animation({ leaf = "fadeIn",           enabled = true, speed = 1.8,  bezier = "almostLinear" })
      hl.animation({ leaf = "fadeOut",          enabled = true, speed = 1.5,  bezier = "almostLinear" })
      hl.animation({ leaf = "fade",             enabled = true, speed = 2.8,  bezier = "quick" })
      hl.animation({ leaf = "layers",           enabled = true, speed = 3.6,  bezier = "smoothOut" })
      hl.animation({ leaf = "layersIn",         enabled = true, speed = 3.6,  bezier = "smoothOut", style = "fade" })
      hl.animation({ leaf = "layersOut",        enabled = true, speed = 1.6,  bezier = "quick",     style = "fade" })
      hl.animation({ leaf = "fadeLayersIn",     enabled = true, speed = 1.8,  bezier = "almostLinear" })
      hl.animation({ leaf = "fadeLayersOut",    enabled = true, speed = 1.4,  bezier = "almostLinear" })
      hl.animation({ leaf = "workspaces",       enabled = true, speed = 3.2,  bezier = "smoothOut", style = "slide" })
      hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3.4,  bezier = "smoothOut", style = "slidevert" })

      -- Session startup hooks (Polkit, Waybar, Hyprpaper, Hypridle, Cliphist run via systemd user units)
      hl.on("hyprland.start", function()
        hl.exec_cmd("fcitx5 -d --replace")
      end)

      -- External http(s) opens mark existing Vivaldi urgent; jump straight to it.
      hl.on("window.urgent", function(win)
        if win and win.class == "vivaldi-stable" then
          pcall(hl.dispatch, hl.dsp.focus({ window = "class:^vivaldi-stable$" }))
        end
      end)

      local mod = "SUPER"

      -- Core applications & launcher
      hl.bind(mod .. " + Return", hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind("CTRL + ALT + T",   hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind(mod .. " + D",      hl.dsp.exec_cmd(${builtins.toJSON rofiLauncher}), { dont_inhibit = true })
      hl.bind("ALT + Space",      hl.dsp.exec_cmd(${builtins.toJSON rofiLauncher}), { dont_inhibit = true })
      hl.bind(mod .. " + P",      hl.dsp.exec_cmd(${builtins.toJSON "${rofiRunner}"}), { dont_inhibit = true })
      hl.bind(mod .. " + N",      hl.dsp.exec_cmd(${builtins.toJSON (lib.getExe newWorkspace)}), { dont_inhibit = true })
      hl.bind(mod .. " + E",      hl.dsp.exec_cmd(${builtins.toJSON openYazi}))
      hl.bind(mod .. " + V",      hl.dsp.exec_cmd("clipboard-history"))
      hl.bind(mod .. " + L",      hl.dsp.exec_cmd(${builtins.toJSON "${lockOnceCmd}"}))
      hl.bind(mod .. " + slash",    hl.dsp.exec_cmd(${builtins.toJSON "${showCheatsheet}"}), { dont_inhibit = true })
      hl.bind(mod .. " + question", hl.dsp.exec_cmd(${builtins.toJSON "${showCheatsheet}"}), { dont_inhibit = true })

      -- Window management
      hl.bind(mod .. " + Q",           hl.dsp.window.close(), { dont_inhibit = true })
      hl.bind(mod .. " + SHIFT + Q",   hl.dsp.window.close(), { dont_inhibit = true })
      hl.bind(mod .. " + F",           hl.dsp.window.fullscreen({ mode = 0 }))
      hl.bind(mod .. " + SHIFT + F",   hl.dsp.window.fullscreen({ mode = 1 }))
      hl.bind(mod .. " + SHIFT + Space", hl.dsp.window.float({ action = "toggle" }))
      hl.bind(mod .. " + C",           hl.dsp.window.center())
      hl.bind(mod .. " + B",           hl.dsp.layout("togglesplit"))
      hl.bind(mod .. " + ALT + P",     hl.dsp.window.pseudo())
      hl.bind(mod .. " + R",           hl.dsp.submap("resize"))

      -- Window groups (tabbed containers)
      hl.bind(mod .. " + G",         hl.dsp.group.toggle())
      hl.bind(mod .. " + Tab",       hl.dsp.group.next())
      hl.bind(mod .. " + SHIFT + Tab", hl.dsp.group.prev())
      hl.bind(mod .. " + ALT + G",   hl.dsp.group.lock())

      -- Special workspace (scratchpad)
      hl.bind(mod .. " + S",       hl.dsp.workspace.toggle_special("magic"))
      hl.bind(mod .. " + ALT + S", hl.dsp.window.move({ workspace = "special:magic" }))

      -- Screenshots & color picker
      hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} region"}), { dont_inhibit = true })
      hl.bind(mod .. " + Print",     hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} window"}), { dont_inhibit = true })
      hl.bind("Print",               hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} full"}),   { dont_inhibit = true })
      hl.bind("SHIFT + Print",       hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} region"}), { dont_inhibit = true })
      hl.bind(mod .. " + SHIFT + P", hl.dsp.exec_cmd(${builtins.toJSON "${hyprpickerBin} -a"}))

      -- Focus navigation (Super+L is reserved exclusively for hyprlock; use Super+Right for right focus)
      hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
      hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "up" }))
      hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "down" }))
      hl.bind(mod .. " + H",     hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + J",     hl.dsp.focus({ direction = "down" }))
      hl.bind(mod .. " + K",     hl.dsp.focus({ direction = "up" }))

      -- Move windows
      hl.bind(mod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + SHIFT + H",     hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + SHIFT + J",     hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + SHIFT + K",     hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + SHIFT + L",     hl.dsp.window.move({ direction = "right" }))

      -- Workspaces 1..10 (key 0 maps to workspace 10)
      for i = 1, 10 do
        local key = tostring(i % 10)
        hl.bind(mod .. " + " .. key,           hl.dsp.focus({ workspace = i }))
        hl.bind(mod .. " + SHIFT + " .. key,   hl.dsp.window.move({ workspace = i }))
      end

      -- Mouse window drag/resize and workspace scroll (standard Hyprland UX)
      hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
      hl.bind(mod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
      hl.bind(mod .. " + mouse:272",  hl.dsp.window.drag(),   { mouse = true })
      hl.bind(mod .. " + mouse:273",  hl.dsp.window.resize(), { mouse = true })

      -- Volume & display brightness (repeat while held, active even on lock screen)
      hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd(${builtins.toJSON "${volumeUp}"}), { locked = true, repeating = true })
      hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-sink-volume @DEFAULT_SINK@ -5%"}), { locked = true, repeating = true })
      hl.bind("XF86AudioMute",         hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-sink-mute @DEFAULT_SINK@ toggle"}), { locked = true })
      hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-source-mute @DEFAULT_SOURCE@ toggle"}), { locked = true })
      hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(${builtins.toJSON "${brightnessctl} set +5%"}), { locked = true, repeating = true })
      hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(${builtins.toJSON "${brightnessctl} set 5%-"}), { locked = true, repeating = true })

      -- Interactive resize submap
      hl.define_submap("resize", "escape", function()
        hl.bind("right",  hl.dsp.window.resize({ x = 24,  y = 0 }),   { repeating = true })
        hl.bind("left",   hl.dsp.window.resize({ x = -24, y = 0 }),   { repeating = true })
        hl.bind("up",     hl.dsp.window.resize({ x = 0,   y = -24 }), { repeating = true })
        hl.bind("down",   hl.dsp.window.resize({ x = 0,   y = 24 }),  { repeating = true })
        hl.bind("l",      hl.dsp.window.resize({ x = 24,  y = 0 }),   { repeating = true })
        hl.bind("h",      hl.dsp.window.resize({ x = -24, y = 0 }),   { repeating = true })
        hl.bind("k",      hl.dsp.window.resize({ x = 0,   y = -24 }), { repeating = true })
        hl.bind("j",      hl.dsp.window.resize({ x = 0,   y = 24 }),  { repeating = true })
        hl.bind("Return", hl.dsp.submap("reset"))
      end)
    '';
  };

  # Because wayland.windowManager.hyprland.package = null, provide our own
  # onChange hook so live Hyprland sessions reload immediately on HM switch.
  xdg.configFile."hypr/hyprland.lua".onChange = ''
    runtimeDir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -d "$runtimeDir/hypr" ]; then
      for inst in $(${hyprctlBin} instances -j 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[].instance' 2>/dev/null || true); do
        ${hyprctlBin} -i "$inst" reload config-only >/dev/null 2>&1 || true
      done
    fi
  '';

  # Hyprpaper 0.8+ block syntax with procedural Nocturne Slate wallpaper.
  services.hyprpaper = {
    enable = true;
    settings = {
      splash = false;
      ipc = true;
      wallpaper = [
        {
          monitor = "";
          path = "${wallpaperPng}";
          fit_mode = "cover";
        }
      ];
    };
  };

  # Hyprlock: live desktop screenshot blur + clean typography + status feedback.
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        hide_cursor = true;
        grace = 0;
        no_fade_in = false;
      };
      background = [
        {
          monitor = "";
          path = "screenshot";
          color = "rgb(${p.bgRgb})";
          blur_passes = 3;
          blur_size = 7;
          noise = 0.015;
          contrast = 0.92;
          brightness = 0.62;
          vibrancy = 0.18;
        }
      ];
      label = [
        {
          monitor = "";
          text = "$TIME";
          color = "rgb(${p.fgRgb})";
          font_size = 76;
          font_family = theme.font.monoBold;
          position = "0, 140";
          halign = "center";
          valign = "center";
          shadow_passes = 2;
          shadow_size = 4;
          shadow_color = "rgba(0, 0, 0, 0.55)";
        }
        {
          monitor = "";
          text = "cmd[update:60000] TZ=Asia/Tokyo date '+%Y年%m月%d日 (%a)'";
          color = "rgb(${p.fgSecondaryRgb})";
          font_size = 18;
          font_family = theme.font.mono;
          position = "0, 62";
          halign = "center";
          valign = "center";
        }
        {
          monitor = "";
          text = "󰌾  $USER @ $HOSTNAME";
          color = "rgb(${p.accentRgb})";
          font_size = 13;
          font_family = theme.font.mono;
          position = "0, -110";
          halign = "center";
          valign = "center";
        }
      ];
      input-field = [
        {
          monitor = "";
          size = "320, 48";
          outline_thickness = 2;
          rounding = theme.radius.popup;
          dots_size = 0.24;
          dots_spacing = 0.28;
          dots_center = true;
          outer_color = "rgba(${p.accentRgb}, 0.85)";
          inner_color = "rgba(${p.surfaceRgb}, 0.85)";
          font_color = "rgb(${p.fgRgb})";
          check_color = "rgba(${p.accentAltRgb}, 0.95)";
          fail_color = "rgba(${p.dangerRgb}, 0.95)";
          capslock_color = "rgb(242, 184, 102)";
          fade_on_empty = false;
          # Avoid raw '#' in hyprlang values (treated as comment); use Pango tags only.
          placeholder_text = "<i>パスワードを入力…</i>";
          fail_text = "<i>認証失敗 ($ATTEMPTS)</i>";
          position = "0, -32";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  # Hypridle: 5m dim -> 10m lock -> 15m DPMS off (all respect keep-screen-on).
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${lockOnceCmd}";
        before_sleep_cmd = "${lockOnceCmd}";
        after_sleep_cmd = "${idleDpmsOnCmd}";
        ignore_dbus_inhibit = false;
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "${idleDimCmd}";
          on-resume = "${idleUndimCmd}";
        }
        {
          timeout = 600;
          on-timeout = "${idleLockCmd}";
        }
        {
          timeout = 900;
          on-timeout = "${idleDpmsOffCmd}";
          on-resume = "${idleDpmsOnCmd}";
        }
      ];
    };
  };

  systemd.user.services.waybar = {
    Unit = {
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      MemoryMax = "256M";
      MemoryHigh = "192M";
      Restart = "on-failure";
      RestartSec = "2";
    };
  };

  systemd.user.services.flake-update-check = {
    Unit = {
      Description = "Check MySettings flake / pinned .deb updates for waybar";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Service = {
      Type = "oneshot";
      ExecStart = flakeUpdateCheck;
    };
  };
  systemd.user.timers.flake-update-check = {
    Unit = {
      Description = "Periodic flake update check for waybar";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # Waybar: floating frosted top bar + floating slim left dock.
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = {
      mainBar = {
        name = "main";
        layer = "top";
        position = "top";
        height = 34;
        margin-top = 8;
        margin-left = 10;
        margin-right = 10;
        spacing = 4;

        modules-left = [
          "custom/cheatsheet"
          "hyprland/workspaces"
          "hyprland/submap"
          "custom/restic"
          "hyprland/window"
        ];
        modules-center = [ "custom/clock" ];
        modules-right = [
          "cpu"
          "memory"
          "custom/capsomnia"
          "custom/keep-screen-on"
          "network"
          "backlight"
          "pulseaudio"
          "custom/battery"
        ];

        "custom/cheatsheet" = {
          format = "󰋖";
          tooltip = true;
          tooltip-format = "チートシート (Super+/)";
          on-click = "${showCheatsheet}";
        };
        "hyprland/workspaces" = {
          all-outputs = true;
          active-only = false;
          format = "{id}";
          on-click = "activate";
          on-scroll-up = "${hyprctlBin} dispatch 'hl.dsp.focus({ workspace = \"e+1\" })'";
          on-scroll-down = "${hyprctlBin} dispatch 'hl.dsp.focus({ workspace = \"e-1\" })'";
        };
        "hyprland/submap" = {
          format = "󰩨 {}";
          tooltip = false;
        };
        "hyprland/window" = {
          max-length = 38;
          separate-outputs = true;
        };
        "custom/restic" = {
          exec = pkgs.writeShellScript "waybar-restic" ''
            f="''${XDG_RUNTIME_DIR}/restic-home-status"
            if [ -s "$f" ]; then cat "$f"; else printf '%s\n' '{"text":"","class":"idle"}'; fi
          '';
          return-type = "json";
          interval = 2;
          signal = 8;
          hide-empty-text = true;
          tooltip = true;
        };
        # Capsomnia status dot + optional countdown (signal 15 from capsomniad).
        "custom/capsomnia" = {
          exec = "${capsomniaPkg}/bin/cpsm waybar";
          return-type = "json";
          interval = 5;
          signal = 15;
          tooltip = true;
          hide-empty-text = true;
          on-click = "${capsomniaPkg}/bin/capsomnia-menu";
          on-click-right = "${capsomniaPkg}/bin/cpsm toggle --no-sleep";
          on-click-middle = "${capsomniaPkg}/bin/capsomnia-settings";
        };
        "custom/clock" = {
          exec = "${waybarClock}";
          return-type = "json";
          interval = 1;
          signal = 11;
          tooltip = true;
          on-click = lib.getExe ntpSync;
        };
        "custom/keep-screen-on" = {
          exec = "${waybarKeepScreenOn}";
          return-type = "json";
          interval = 5;
          signal = 14;
          on-click = "${toggleKeepScreenOn}";
        };
        cpu = {
          format = " {usage}%";
          interval = 5;
          on-click = openBtop;
        };
        memory = {
          format = " {percentage}%";
          interval = 5;
          on-click = openBtop;
        };
        network = {
          interval = 2;
          format-wifi = " {essid}";
          format-ethernet = "󰈀 {ifname}";
          format-disconnected = "󰤮 offline";
          max-length = 18;
          tooltip-format = "↓{bandwidthDownBytes} ↑{bandwidthUpBytes}\n{ifname} {ipaddr}";
          on-click = openNmtui;
        };
        backlight = {
          format = "{icon} {percent}%";
          format-icons = [
            "󰃞"
            "󰃟"
            "󰃠"
          ];
        };
        pulseaudio = {
          format = "{icon} {volume}%";
          format-muted = "󰖁 mute";
          format-icons = {
            default = [
              "󰕿"
              "󰖀"
              "󰕾"
            ];
          };
          max-volume = 100;
          on-click = "${pactl} set-sink-mute @DEFAULT_SINK@ toggle";
        };
        "custom/battery" = {
          exec =
            "${lib.getExe waybarBattery} "
            + (if isChromebook then "--adapter AC" else "--bat BAT1 --adapter ACAD");
          return-type = "json";
          interval = 5;
          signal = 16;
          tooltip = true;
          escape = true;
          hide-empty-text = true;
        };
      };

      sideBar = {
        name = "side";
        layer = "top";
        position = "left";
        width = 40;
        margin-top = 6;
        margin-bottom = 10;
        margin-left = 10;

        modules-left = [ "custom/updates" ];
        modules-right = [
          "custom/startup-sound"
          "custom/jquake"
          "custom/services"
          "tray"
        ];

        "custom/updates" = {
          exec = pkgs.writeShellScript "waybar-flake-updates" ''
            f="''${XDG_RUNTIME_DIR}/flake-update-status"
            if [ -s "$f" ]; then cat "$f"; else printf '%s\n' '{"text":"","class":"idle","tooltip":"更新チェック待ち\nクリックで flake-update"}'; fi
          '';
          return-type = "json";
          interval = 30;
          signal = 9;
          tooltip = true;
          on-click = openFlakeUpdate;
        };
        "custom/startup-sound" = {
          exec = "${startupSoundBin} --waybar";
          return-type = "json";
          interval = 10;
          signal = 13;
          tooltip = true;
          on-click = "${startupSoundBin} --menu";
          on-click-right = "${startupSoundBin} --toggle-and-notify";
          on-click-middle = "${startupSoundBin} --play-bg";
        };
        "custom/jquake" = {
          exec = lib.getExe waybarJquake;
          return-type = "json";
          interval = 5;
          signal = 12;
          tooltip = true;
          on-click = lib.getExe waybarJquakeOpen;
          on-click-right = lib.getExe waybarJquakeMenu;
        };
        "custom/services" = {
          exec = lib.getExe waybarServices;
          return-type = "json";
          interval = 15;
          signal = 10;
          tooltip = true;
          on-click = lib.getExe waybarServicesMenu;
        };
        tray = {
          icon-size = 16;
          spacing = 6;
        };
      };
    };

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "${waybarFont}", sans-serif;
        font-size: 11.5px;
        min-height: 0;
        min-width: 0;
      }

      window#waybar {
        background: rgba(${p.surfaceRgb}, 0.82);
        color: ${p.fg};
        border: 1px solid rgba(148, 174, 204, 0.16);
        border-radius: ${toString theme.radius.bar}px;
      }

      window.side#waybar {
        background: rgba(${p.surfaceRgb}, 0.82);
        color: ${p.fg};
        border: 1px solid rgba(148, 174, 204, 0.16);
        border-radius: ${toString theme.radius.bar}px;
      }

      tooltip {
        background: rgba(${p.surfaceRgb}, 0.96);
        color: ${p.fg};
        border: 1px solid ${p.border};
        border-radius: ${toString theme.radius.control}px;
      }

      tooltip label {
        color: ${p.fg};
        padding: 4px 6px;
      }

      /* Top bar modules */
      #custom-cheatsheet {
        color: ${p.accent};
        font-size: 14px;
        padding: 0 10px 0 12px;
        margin: 3px 2px 3px 4px;
        border-radius: ${toString theme.radius.pill}px;
        background: transparent;
        transition: background-color 140ms ease;
      }
      #custom-cheatsheet:hover {
        background: rgba(${p.accentRgb}, 0.16);
      }

      #workspaces {
        margin: 4px 4px;
        padding: 0 4px;
        background: rgba(${p.surfaceAltRgb}, 0.72);
        border-radius: ${toString theme.radius.pill}px;
      }
      #workspaces button {
        padding: 0 7px;
        margin: 2px 1px;
        color: ${p.fgMuted};
        background: transparent;
        border-radius: 5px;
        transition: all 140ms ease;
      }
      #workspaces button:hover {
        color: ${p.fg};
        background: rgba(255, 255, 255, 0.06);
      }
      #workspaces button.active {
        color: ${p.bg};
        background: linear-gradient(135deg, ${p.accent}, ${p.accentAlt});
        font-weight: 700;
        padding: 0 11px;
      }
      #workspaces button.urgent {
        color: ${p.fg};
        background: ${p.danger};
      }
      #submap {
        color: ${p.bg};
        background: ${p.danger};
        font-weight: 700;
        padding: 0 10px;
        margin: 4px 2px;
        border-radius: ${toString theme.radius.pill}px;
      }

      #custom-restic {
        padding: 0 10px;
        margin: 4px 2px;
        color: ${p.fg};
        background: ${p.accentSoft};
        border: 1px solid rgba(${p.accentRgb}, 0.45);
        border-radius: ${toString theme.radius.pill}px;
      }
      #custom-restic.running {
        color: ${p.accent};
      }
      #custom-restic.done {
        color: ${p.success};
        border-color: rgba(110, 231, 183, 0.45);
      }
      #custom-restic.failed {
        color: ${p.danger};
        background: ${p.dangerSoft};
        border-color: ${p.danger};
      }

      #window {
        color: ${p.fgSecondary};
        padding: 0 10px;
      }

      #custom-clock {
        color: ${p.fg};
        font-weight: 600;
        padding: 0 14px;
        margin: 4px 0;
        border-radius: ${toString theme.radius.pill}px;
        background: rgba(${p.surfaceAltRgb}, 0.65);
        transition: background-color 140ms ease;
      }
      #custom-clock:hover {
        background: rgba(${p.accentRgb}, 0.16);
        color: ${p.accent};
      }

      #cpu,
      #memory,
      #custom-capsomnia,
      #custom-keep-screen-on,
      #network,
      #backlight,
      #pulseaudio,
      #custom-battery {
        padding: 0 9px;
        margin: 4px 1px;
        color: ${p.fgSecondary};
        background: transparent;
        border-radius: ${toString theme.radius.pill}px;
        transition: background-color 140ms ease, color 140ms ease;
      }

      #cpu:hover,
      #memory:hover,
      #custom-capsomnia:hover,
      #custom-keep-screen-on:hover,
      #network:hover,
      #pulseaudio:hover {
        background: rgba(${p.surfaceAltRgb}, 0.90);
        color: ${p.fg};
      }

      #custom-capsomnia.on {
        color: ${p.fg};
        background: rgba(110, 231, 183, 0.14);
        border: 1px solid rgba(110, 231, 183, 0.45);
        font-weight: 600;
      }
      #custom-capsomnia.off {
        color: ${p.fgMuted};
      }
      #custom-capsomnia.error {
        color: ${p.danger};
        background: ${p.dangerSoft};
        border: 1px solid ${p.danger};
      }

      #custom-battery {
        margin-right: 6px;
        color: ${p.fg};
      }
      #custom-battery.charging,
      #custom-battery.plugged,
      #custom-battery.full,
      #custom-battery.discharging,
      #custom-battery.warning,
      #custom-battery.critical {
        background: transparent;
        animation: none;
      }
      #custom-battery.charging,
      #custom-battery.plugged {
        color: ${p.success};
      }
      #custom-battery.warning {
        color: ${p.warning};
      }
      #custom-battery.critical {
        color: ${p.danger};
        background: ${p.dangerSoft};
      }

      #custom-keep-screen-on.activated {
        color: ${p.accent};
        background: ${p.accentSoft};
        border: 1px solid rgba(${p.accentRgb}, 0.50);
        font-weight: 600;
      }
      #custom-keep-screen-on.deactivated {
        color: ${p.fgMuted};
      }

      #network.disconnected {
        color: ${p.fgMuted};
      }
      #pulseaudio {
        color: ${p.fg};
      }
      #pulseaudio.muted {
        color: ${p.fgMuted};
      }

      /* Left dock modules */
      window.side #custom-updates,
      window.side #custom-startup-sound,
      window.side #custom-jquake,
      window.side #custom-services,
      window.side #tray {
        color: ${p.fgSecondary};
        background: transparent;
        margin: 2px 4px;
        border-radius: ${toString theme.radius.pill}px;
      }

      window.side #custom-updates,
      window.side #custom-startup-sound,
      window.side #custom-jquake,
      window.side #custom-services {
        font-size: 13px;
        padding: 7px 0;
      }

      window.side #custom-updates {
        margin-top: 6px;
      }
      window.side #custom-updates.idle {
        color: ${p.fgMuted};
      }
      window.side #custom-updates.available {
        color: ${p.accent};
        background: ${p.accentSoft};
        border: 1px solid rgba(${p.accentRgb}, 0.55);
      }

      window.side #custom-startup-sound {
        border-top: 1px solid rgba(148, 174, 204, 0.12);
        border-radius: ${toString theme.radius.pill}px;
      }
      window.side #custom-startup-sound.enabled {
        color: ${p.accent};
      }
      window.side #custom-startup-sound.disabled {
        color: ${p.fgMuted};
      }
      window.side #custom-startup-sound.empty {
        color: ${p.warning};
      }

      window.side #custom-jquake.active {
        color: ${p.fgSecondary};
      }
      window.side #custom-jquake.open {
        color: ${p.accent};
        background: ${p.accentSoft};
        border: 1px solid rgba(${p.accentRgb}, 0.55);
      }
      window.side #custom-jquake.degraded {
        color: ${p.warning};
      }
      window.side #custom-jquake.failed {
        color: ${p.danger};
        background: ${p.dangerSoft};
      }

      window.side #custom-services {
        padding: 6px 0;
      }
      window.side #custom-services.degraded {
        background: rgba(242, 184, 102, 0.14);
      }
      window.side #custom-services.failed {
        background: ${p.dangerSoft};
      }

      window.side #tray {
        padding: 6px 0 8px 0;
        margin-bottom: 4px;
      }
    '';
  };

  xdg.configFile."satty/config.toml".text = ''
    [general]
    early-exit = ["copy", "save"]
    corner-roundness = ${toString theme.radius.window}
    initial-tool = "arrow"
    copy-command = "wl-copy"
    output-filename = "~/Pictures/Screenshots/screenshot-%Y%m%d-%H%M%S.png"
    actions-on-enter = ["save-to-clipboard", "exit"]
    actions-on-escape = ["exit"]
    annotation-size-factor = 1.0

    [font]
    family = "sans-serif"

    [color-palette]
    palette = [
      "${p.accent}",
      "${p.danger}",
      "${p.warning}",
      "${p.success}",
      "${p.accentAlt}",
      "#ffffff",
    ]
  '';

  # Mako notifications: Nocturne Slate frosted card + progress indicator.
  services.mako = {
    enable = true;
    settings = {
      font = "${theme.font.mono} 11";
      background-color = "${p.surface}e6";
      text-color = p.fg;
      border-color = p.border;
      progress-color = "over ${p.accentSoft}";
      border-size = 1;
      border-radius = theme.radius.window;
      padding = "12,14";
      margin = "12,12,0,0";
      width = 360;
      default-timeout = 7000;
      max-visible = 4;
      layer = "overlay";
      anchor = "top-right";
      "urgency=low" = {
        border-color = p.border;
        default-timeout = 4000;
      };
      "urgency=normal" = {
        border-color = p.accent;
      };
      "urgency=high" = {
        border-color = p.danger;
        background-color = "${p.dangerSoft}f0";
        default-timeout = 0;
      };
    };
  };
}
