# Hyprland Home Manager: primary desktop (UWSM) — waybar / mako / hypridle / hyprlock.
# Visual language stays terminal/greeter-adjacent (dark + cyan).
# Launcher: rofi (drun). Keyboard layout: jp. Lock/idle: hyprlock/hypridle. Wallpaper: hyprpaper.
{
  config,
  pkgs,
  lib,
  flakeTarget ? "chromebook",
  ...
}:

let
  isChromebook = flakeTarget == "chromebook";
  inputSection = if isChromebook then "入力・Chromebook" else "入力・VAIO";
  powerSection = if isChromebook then "電源・Type-C" else "電源・省電力";
  # Checkout for the waybar timer's ConditionPathExists. Scripts are store paths.
  repoPath = config.mitac.repoPath;
  flakeUpdateCheck = lib.getExe config.mitac.scripts.flakeUpdateCheck;
  flakeUpdate = lib.getExe config.mitac.scripts.flakeUpdate;
  startupSoundBin = lib.getExe config.mitac.scripts.startupSound;
  # Family string from nerd-fonts.jetbrains-mono (same as Ghostty).
  # CSS does not name a CJK face. Missing glyphs go through fontconfig's
  # defaultFonts (Hiragino, then Noto Sans CJK JP).
  waybarFont = "JetBrainsMono Nerd Font";
  ghosttyBin = "${pkgs.ghostty}/bin/ghostty";
  flakeUpdateRunner = pkgs.writeShellScript "open-flake-update" ''
    rc=0
    ${flakeUpdate} || rc=$?
    printf '\n終了コード: %d [Enter で閉じる] ' "$rc"
    IFS= read -r _ || true
  '';
  openFlakeUpdate = "${ghosttyBin} -e ${flakeUpdateRunner}";
  rofiBin = lib.getExe config.programs.rofi.package;
  yaziBin = "${pkgs.yazi}/bin/yazi";
  hyprlockBin = "${pkgs.hyprlock}/bin/hyprlock";
  hypridleBin = "${pkgs.hypridle}/bin/hypridle";
  hyprshotBin = "${pkgs.hyprshot}/bin/hyprshot";
  hyprpickerBin = "${pkgs.hyprpicker}/bin/hyprpicker";
  hyprctlBin = "${pkgs.hyprland}/bin/hyprctl";
  polkitAgent = lib.getExe pkgs.hyprpolkitagent;
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  # pactl +N% has no ceiling; PulseAudio happily goes past 100% (soft boost).
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
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  btopBin = "${pkgs.btop}/bin/btop";
  nmtuiBin = "${pkgs.networkmanager}/bin/nmtui";
  grim = "${pkgs.grim}/bin/grim";
  slurp = "${pkgs.slurp}/bin/slurp";
  wlCopy = "${pkgs.wl-clipboard}/bin/wl-copy";


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
          --corner-roundness 8
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

  # Presentation marker toggled with waybar scr / scr ON. XDG_RUNTIME_DIR is
  # session-scoped, so it clears on logout. Idle auto-lock / DPMS no-op while set.
  lockCmd = "${pkgs.hyprlock}/bin/hyprlock";
  idleLockCmd = pkgs.writeShellScript "hypr-idle-lock" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ]; then
      exit 0
    fi
    exec ${pkgs.hyprlock}/bin/hyprlock
  '';
  idleDpmsOffCmd = pkgs.writeShellScript "hypr-idle-dpms-off" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ]; then
      exit 0
    fi
    exec ${pkgs.hyprland}/bin/hyprctl dispatch dpms off
  '';
  idleDpmsOnCmd = pkgs.writeShellScript "hypr-idle-dpms-on" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch dpms on
  '';
  toggleKeepScreenOn = pkgs.writeShellScript "hypr-toggle-keep-screen-on" ''
    marker="''${XDG_RUNTIME_DIR}/hypr-keep-screen-on"
    if [ -e "$marker" ]; then
      rm -f "$marker"
    else
      touch "$marker"
    fi
  '';
  waybarKeepScreenOn = pkgs.writeShellScript "waybar-keep-screen-on" ''
    marker="''${XDG_RUNTIME_DIR}/hypr-keep-screen-on"
    if [ -e "$marker" ]; then
      printf '%s\n' '{"text":"scr ON","class":"activated","tooltip":"画面常時オン（ロック・消灯なし／クリックで解除）"}'
    else
      printf '%s\n' '{"text":"scr","class":"deactivated","tooltip":"画面を常時オンにする（ロック・消灯を抑制）"}'
    fi
  '';
  # Route launches through hyprctl dispatch exec so new windows land on the
  # active workspace at selection time.
  rofiLauncher = "${rofiBin} -show drun -run-command \"${pkgs.hyprland}/bin/hyprctl dispatch exec -- {cmd}\" -run-shell-command \"${pkgs.hyprland}/bin/hyprctl dispatch exec -- {terminal} -e {cmd}\"";
  # waybar cpu / mem → Ghostty + btop; network → Ghostty + nmtui; clock → NTP sync
  openBtop = "${ghosttyBin} -e ${btopBin}";
  openNmtui = "${ghosttyBin} -e ${nmtuiBin}";
  openYazi = "${ghosttyBin} -e ${yaziBin}";

  waybarClock = pkgs.writeShellScript "waybar-clock" ''
    export LC_ALL=C
    export TZDIR="${pkgs.tzdata}/share/zoneinfo"
    printf -v now '%(%s)T' -1
    TZ="Asia/Tokyo" printf -v bar '%(%a %m-%d %H:%M:%S)T' "$now"
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

  # Dedicated left-bar JQuake slot: status indicator + click-to-open + right-click menu.
  waybarJquake = pkgs.writeShellApplication {
    name = "waybar-jquake";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
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
      if ${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null | ${pkgs.jq}/bin/jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
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
      pkgs.jq
      pkgs.libnotify
      pkgs.stalonetray
      pkgs.hyprland
      pkgs.jq
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

      if ${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null | ${pkgs.jq}/bin/jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
        ${pkgs.hyprland}/bin/hyprctl dispatch focuswindow class:^net-jquake-app-Main$ >/dev/null 2>&1 || true
        refresh_jquake_bar
        exit 0
      fi

      disp="''${DISPLAY:-:0}"
      clicked=0
      for _ in $(seq 1 40); do
        # Target AWT's child canvas directly: stalonetray's x11_find_subwindow_at
        # exits immediately (`old = None` checked as `old != None`), so clicking
        # JavaEmbeddedFrame stops at the wrapper frame and misses XTrayIconPeer.
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
        if ${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null | ${pkgs.jq}/bin/jq -e '
          [.[] | select(.class == "net-jquake-app-Main")] | length > 0
        ' >/dev/null; then
          ${pkgs.hyprland}/bin/hyprctl dispatch focuswindow class:^net-jquake-app-Main$ >/dev/null 2>&1 || true
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
            lines+=("<span color='#9fe7e7'>''${glyph}</span>")
            ;;
          running)
            lines+=("<span color='#33c5c5'>''${glyph}</span>")
            ;;
          failed)
            mark_level failed
            lines+=("<span color='#e06c75'>''${glyph}</span>")
            ;;
          *)
            mark_level warn
            lines+=("<span color='#e5c07b'>''${glyph}</span>")
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
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
      pkgs.yazi
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
                exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- uniclipboard
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
                exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- lan-mouse
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
                exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- "${ghosttyBin} -e ${yaziBin} \"$HOME/Downloads\""
                ;;
              *"Cliphist"*"再起動")
                systemctl --user restart cliphist-text.service cliphist-image.service
                refresh_bar
                ;;
              *"Cliphist"*"履歴メニューを開く")
                exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- clipboard-history
                ;;
              *"Tailscale"*"Trayscale"*)
                exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- trayscale
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
  # - run + mode=exec → hyprctl dispatch exec (one-shot)
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
      label = "rofi（選択中 WS に起動）";
      keys = "Super+D / Alt+Space";
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
      keys = "Super+q";
    }
    {
      section = "起動・終了";
      label = "画面ロック (hyprlock)";
      keys = "Super+L";
    }
    {
      section = "起動・終了";
      label = "設定反映 / Hyprland 終了";
      keys = "hyprctl reload / Super+M なし (UWSM/再ログイン運用)";
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
      label = "注: ELECOM は Win+Shift 同時押しが欠けること有 → Super+q 等";
    }
    # ウィンドウ・WS
    {
      section = "ウィンドウ・WS";
      label = "フォーカス（右は Right）";
      keys = "Super+hjkl / 矢印";
    }
    {
      section = "ウィンドウ・WS";
      label = "ウィンドウ移動";
      keys = "Super+Shift+hjkl";
    }
    {
      section = "ウィンドウ・WS";
      label = "フルスクリーン / リサイズ";
      keys = "Super+f / r";
    }
    {
      section = "ウィンドウ・WS";
      label = "フローティング切替";
      keys = "Super+Shift+Space";
    }
    {
      section = "ウィンドウ・WS";
      label = "水平 / 垂直分割";
      keys = "Super+b / v";
    }
    {
      section = "ウィンドウ・WS";
      label = "スタック / タブ";
      keys = "Super+s / w";
    }
    {
      section = "ウィンドウ・WS";
      label = "WS 切替 / ウィンドウを移動";
      keys = "Super+1…9 / Shift+1…9";
    }
    {
      section = "ウィンドウ・WS";
      label = "外部リンク → Vivaldi へフォーカス（必要に応じ windowrule で調整）";
    }
    {
      section = "ウィンドウ・WS";
      label = "注: Super+e は Yazi、Super+b で分割方向トグル (Hyprland)";
    }
    # スクショ・音量・輝度・履歴
    {
      section = "スクショ・音量・輝度";
      label = "範囲選択 → Satty 編集・コピー (hyprshot)";
      keys = "Super+Shift+s / Shift+Print";
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
      keys = "Super+e";
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
      keys = "? / scr";
    }
    {
      section = "Waybar・日常";
      label = "btop";
      keys = "cpu·mem クリック";
      run = btopBin;
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "nmtui";
      keys = "net クリック";
      run = nmtuiBin;
      mode = "term";
    }
    {
      section = "Waybar・日常";
      label = "NTP 時刻同期";
      keys = "時計クリック";
      run = lib.getExe ntpSync;
      mode = "exec";
    }
    {
      section = "Waybar・日常";
      label = "バックアップ進捗";
      keys = "[restic]（WS の右）";
    }
    {
      section = "Waybar・日常";
      label = "10分ロック / 15分画面オフ (hypridle)";
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
      label = "更新チェック（waybar upd）";
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
      label = "輝度 40%（消費の主因を下げる）";
      run = "${brightnessctl} set 40%";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "バッテリー状態（健康度・W・残り）";
      run = "awk -v en=$(cat /sys/class/power_supply/BAT1/energy_now) -v ef=$(cat /sys/class/power_supply/BAT1/energy_full) -v ed=$(cat /sys/class/power_supply/BAT1/energy_full_design) -v pw=$(cat /sys/class/power_supply/BAT1/power_now) -v cap=$(cat /sys/class/power_supply/BAT1/capacity) -v st=$(cat /sys/class/power_supply/BAT1/status) 'BEGIN{printf \"%s %s%%  now=%.2fWh full=%.2fWh design=%.2fWh health=%.0f%%  %.2fW  ETA=%.1fh\\n\", st,cap,en/1e6,ef/1e6,ed/1e6,100*ef/ed,pw/1e6,(pw>0?en/pw:0)}'";
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
      label = "JQuake 表示（左 waybar クリックでも可）";
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
        pkgs.hyprland
        pkgs.ghostty
        pkgs.bash
      ]
    }:$PATH"
    data="${cheatsheetJson}"
    choice=$(
      jq -r '.[].display' "$data" \
        | ${rofiBin} -dmenu -i -p '?' -no-custom
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
        exec ${pkgs.hyprland}/bin/hyprctl dispatch exec -- ${pkgs.bash}/bin/bash -c "$run"
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
  # On PATH once. Linked for convenience in the Hyprland session.
  # Binds still call the store paths above, which are the same packages.
  home.packages = [
    pkgs.hyprpaper
    pkgs.hypridle
    pkgs.hyprlock
    pkgs.hyprpicker
    pkgs.hyprshot
    pkgs.satty
    screenshotBin
    pkgs.brightnessctl
    pkgs.jq
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    package = null; # system programs.hyprland
    portalPackage = null;
    systemd.enable = false; # UWSM manages the session
    xwayland.enable = true;
    settings = {
      monitor = {
        output = "";
        mode = "preferred";
        position = "auto";
        scale = 1;
      };
      config = {
        input = {
          kb_layout = "jp";
          numlock_by_default = true;
          follow_mouse = 1;
          touchpad = {
            natural_scroll = false;
            tap_to_click = true;
            clickfinger_behavior = true;
            disable_while_typing = false;
          };
        };
        general = {
          gaps_in = 4;
          gaps_out = 4;
          border_size = 2;
          col = {
            active_border = "rgb(33c5c5)";
            inactive_border = "rgb(1c2430)";
          };
          layout = "dwindle";
        };
        decoration = {
          rounding = 0;
          shadow = {
            enabled = false;
          };
          blur = {
            enabled = false;
          };
        };
        animations = {
          enabled = true;
        };
        misc = {
          disable_hyprland_logo = true;
          disable_splash_rendering = true;
          force_default_wallpaper = 0;
          background_color = "rgb(0b0f14)";
          focus_on_activate = true;
        };
        dwindle = {
          preserve_split = true;
        };
      };
      window_rule = [
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
      ];
    };
    extraConfig = ''
      local mod = "SUPER"

      hl.on("hyprland.start", function()
        hl.exec_cmd(${builtins.toJSON "${polkitAgent}"})
        hl.exec_cmd("fcitx5 -d --replace")
      end)

      hl.bind(mod .. " + Return", hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind("CTRL + ALT + T", hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind(mod .. " + D", hl.dsp.exec_cmd(${builtins.toJSON rofiLauncher}))
      hl.bind("ALT + Space", hl.dsp.exec_cmd(${builtins.toJSON rofiLauncher}))
      hl.bind(mod .. " + Q", hl.dsp.window.close())
      hl.bind(mod .. " + SHIFT + Q", hl.dsp.window.close())
      hl.bind(mod .. " + L", hl.dsp.exec_cmd(${builtins.toJSON lockCmd}))
      hl.bind(mod .. " + E", hl.dsp.exec_cmd(${builtins.toJSON openYazi}))
      hl.bind(mod .. " + V", hl.dsp.exec_cmd("clipboard-history"))
      hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = 0 }))
      hl.bind(mod .. " + R", hl.dsp.submap("resize"))
      hl.bind(mod .. " + SHIFT + Space", hl.dsp.window.float({ action = "toggle" }))
      hl.bind(mod .. " + B", hl.dsp.layout("togglesplit"))
      hl.bind(mod .. " + slash", hl.dsp.exec_cmd(${builtins.toJSON "${showCheatsheet}"}))
      hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} region"}))
      hl.bind(mod .. " + Print", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} window"}))
      hl.bind("Print", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} full"}))
      hl.bind("SHIFT + Print", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} region"}))
      hl.bind(mod .. " + P", hl.dsp.exec_cmd(${builtins.toJSON "${hyprpickerBin} -a"}))

      hl.bind(mod .. " + left", hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
      hl.bind(mod .. " + up", hl.dsp.focus({ direction = "up" }))
      hl.bind(mod .. " + down", hl.dsp.focus({ direction = "down" }))
      hl.bind(mod .. " + H", hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + L", hl.dsp.focus({ direction = "right" }))
      hl.bind(mod .. " + K", hl.dsp.focus({ direction = "up" }))
      hl.bind(mod .. " + J", hl.dsp.focus({ direction = "down" }))

      hl.bind(mod .. " + SHIFT + left", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + SHIFT + up", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + SHIFT + down", hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + SHIFT + H", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + SHIFT + L", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + SHIFT + K", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + SHIFT + J", hl.dsp.window.move({ direction = "down" }))

      for i = 1, 9 do
        hl.bind(mod .. " + " .. i, hl.dsp.focus({ workspace = i }))
        hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
      end

      hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd(${builtins.toJSON "${volumeUp}"}), { locked = true })
      hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-sink-volume @DEFAULT_SINK@ -5%"}), { locked = true })
      hl.bind("XF86AudioMute", hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-sink-mute @DEFAULT_SINK@ toggle"}), { locked = true })
      hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd(${builtins.toJSON "${pactl} set-source-mute @DEFAULT_SOURCE@ toggle"}), { locked = true })
      hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(${builtins.toJSON "${brightnessctl} set +5%"}), { locked = true })
      hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(${builtins.toJSON "${brightnessctl} set 5%-"}), { locked = true })

      hl.define_submap("resize", "escape", function()
        hl.bind("right", hl.dsp.window.resize({ x = 20, y = 0 }), { repeating = true })
        hl.bind("left", hl.dsp.window.resize({ x = -20, y = 0 }), { repeating = true })
        hl.bind("up", hl.dsp.window.resize({ x = 0, y = -20 }), { repeating = true })
        hl.bind("down", hl.dsp.window.resize({ x = 0, y = 20 }), { repeating = true })
        hl.bind("l", hl.dsp.window.resize({ x = 20, y = 0 }), { repeating = true })
        hl.bind("h", hl.dsp.window.resize({ x = -20, y = 0 }), { repeating = true })
        hl.bind("k", hl.dsp.window.resize({ x = 0, y = -20 }), { repeating = true })
        hl.bind("j", hl.dsp.window.resize({ x = 0, y = 20 }), { repeating = true })
        hl.bind("Return", hl.dsp.submap("reset"))
      end)
    '';
  };

  services.hyprpaper = {
    enable = true;
    settings = {
      splash = false;
      ipc = "on";
      wallpaper = [ ", color:0xff0b0f14" ];
    };
  };

  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        disable_loading_bar = true;
        hide_cursor = true;
        grace = 0;
      };
      background = [ { monitor = ""; color = "rgb(0b0f14)"; } ];
      label = [
        {
          monitor = "";
          text = "$TIME";
          color = "rgb(230, 237, 243)";
          font_size = 64;
          font_family = "JetBrainsMono Nerd Font";
          position = "0, 120";
          halign = "center";
          valign = "center";
        }
        {
          monitor = "";
          text = "Enter でロック解除";
          color = "rgb(159, 231, 231)";
          font_size = 16;
          font_family = "JetBrainsMono Nerd Font";
          position = "0, 40";
          halign = "center";
          valign = "center";
        }
      ];
      input-field = [
        {
          monitor = "";
          size = "320, 48";
          outline_thickness = 2;
          dots_size = 0.2;
          dots_spacing = 0.2;
          outer_color = "rgb(51, 197, 197)";
          inner_color = "rgb(11, 15, 20)";
          font_color = "rgb(230, 237, 243)";
          fade_on_empty = false;
          placeholder_text = "<span foreground=\"#6b7785\">Password</span>";
          position = "0, -40";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${idleLockCmd}";
        before_sleep_cmd = "${lockCmd}";
        after_sleep_cmd = "${idleDpmsOnCmd}";
      };
      listener = [
        { timeout = 600; on-timeout = "${idleLockCmd}"; }
        { timeout = 900; on-timeout = "${idleDpmsOffCmd}"; on-resume = "${idleDpmsOnCmd}"; }
      ];
    };
  };

  systemd.user.services.waybar = {
    Unit = { StartLimitIntervalSec = 30; StartLimitBurst = 3; };
    Service = { MemoryMax = "256M"; MemoryHigh = "192M"; Restart = "on-failure"; RestartSec = "2"; };
  };

  systemd.user.services.flake-update-check = {
    Unit = {
      Description = "Check MySettings flake / pinned .deb updates for waybar";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Service = { Type = "oneshot"; ExecStart = flakeUpdateCheck; };
  };
  systemd.user.timers.flake-update-check = {
    Unit = {
      Description = "Periodic flake update check for waybar";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Timer = { OnBootSec = "5min"; OnUnitActiveSec = "6h"; Persistent = true; };
    Install = { WantedBy = [ "timers.target" ]; };
  };

  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = {
      mainBar = {
        name = "main"; layer = "top"; position = "bottom"; height = 30;
        modules-left = [ "custom/cheatsheet" "hyprland/workspaces" "custom/restic" "hyprland/submap" ];
        modules-center = [ "hyprland/window" ];
        modules-right = [ "cpu" "memory" "custom/keep-screen-on" "battery" "network" "backlight" "pulseaudio" "custom/clock" ];
        "custom/cheatsheet" = { format = "?"; tooltip = "チートシート"; on-click = "${showCheatsheet}"; };
        "hyprland/workspaces" = { all-outputs = true; };
        "hyprland/window" = { max-length = 48; };
        "hyprland/submap" = { format = "{}"; tooltip = false; };
        "custom/restic" = {
          exec = pkgs.writeShellScript "waybar-restic" ''
            f="''${XDG_RUNTIME_DIR}/restic-home-status"
            if [ -s "$f" ]; then cat "$f"; else printf '%s\n' '{"text":"","class":"idle"}'; fi
          '';
          return-type = "json"; interval = 2; signal = 8; hide-empty-text = true; tooltip = true;
        };
        "custom/keep-screen-on" = { exec = "${waybarKeepScreenOn}"; return-type = "json"; interval = 1; on-click = "${toggleKeepScreenOn}"; };
        cpu = { format = "cpu {usage}%"; interval = 5; on-click = openBtop; };
        memory = { format = "mem {percentage}%"; interval = 5; on-click = openBtop; };
        battery = { format = "{capacity}% {icon}"; format-icons = [ "batt" "batt" "batt" "batt" "batt" ]; format-charging = "{capacity}% chg"; states = { warning = 30; critical = 15; }; };
        network = { interval = 2; format-wifi = "{essid}"; format-ethernet = "{ifname}"; format-disconnected = "offline"; tooltip-format = "↓{bandwidthDownBytes} ↑{bandwidthUpBytes}\n{ifname} {ipaddr}"; on-click = openNmtui; };
        backlight = { format = "bri {percent}%"; };
        pulseaudio = { format = "vol {volume}%"; format-muted = "mute"; max-volume = 100; on-click = "${pactl} set-sink-mute @DEFAULT_SINK@ toggle"; };
        "custom/clock" = { exec = "${waybarClock}"; return-type = "json"; interval = 1; signal = 11; tooltip = true; on-click = lib.getExe ntpSync; };
      };
      sideBar = {
        name = "side"; layer = "top"; position = "left"; width = 34; margin-top = 8; margin-bottom = 8;
        modules-left = [ "custom/updates" ];
        modules-right = [ "custom/startup-sound" "custom/jquake" "custom/services" "tray" ];
        "custom/startup-sound" = { exec = "${startupSoundBin} --waybar"; return-type = "json"; interval = 10; signal = 13; tooltip = true; on-click = "${startupSoundBin} --menu"; on-click-right = "${startupSoundBin} --toggle-and-notify"; on-click-middle = "${startupSoundBin} --play-bg"; };
        "custom/updates" = {
          exec = pkgs.writeShellScript "waybar-flake-updates" ''
            f="''${XDG_RUNTIME_DIR}/flake-update-status"
            if [ -s "$f" ]; then cat "$f"; else printf '%s\n' '{"text":"","class":"idle","tooltip":"更新チェック待ち\nクリックで flake-update"}'; fi
          '';
          return-type = "json"; interval = 30; signal = 9; tooltip = true; on-click = openFlakeUpdate;
        };
        "custom/jquake" = { exec = lib.getExe waybarJquake; return-type = "json"; interval = 5; signal = 12; tooltip = true; on-click = lib.getExe waybarJquakeOpen; on-click-right = lib.getExe waybarJquakeMenu; };
        "custom/services" = { exec = lib.getExe waybarServices; return-type = "json"; interval = 15; signal = 10; tooltip = true; on-click = lib.getExe waybarServicesMenu; };
        tray = { icon-size = 16; spacing = 4; };
      };
    };
    style = ''
      * { border: none; border-radius: 0; font-family: "${waybarFont}", sans-serif; font-size: 11px; min-height: 0; }
      window#waybar { background: #0b0f14; color: #9fe7e7; }
      window.side#waybar { background: #0b0f14; color: #9fe7e7; }
      tooltip { background: #0b0f14; color: #9fe7e7; border: 1px solid #33c5c5; }
      tooltip label { color: #9fe7e7; }
      #workspaces button { padding: 0 6px; color: #6b7785; background: transparent; }
      #workspaces button.active { color: #e6edf3; background: #15383a; border-bottom: 2px solid #33c5c5; }
      #workspaces button.urgent { color: #e6edf3; background: #3a1a1e; }
      #submap { color: #e06c75; padding: 0 8px; }
      #window { color: #9aa7b5; padding: 0 8px; }
      #custom-cheatsheet, #cpu, #memory, #custom-keep-screen-on, #battery, #network, #backlight, #pulseaudio, #custom-clock { padding: 0 8px; color: #9fe7e7; background: transparent; }
      #custom-cheatsheet { color: #33c5c5; }
      #custom-keep-screen-on.activated { color: #e6edf3; background: #15383a; border-left: 2px solid #33c5c5; }
      #custom-keep-screen-on.deactivated { color: #6b7785; }
      #custom-restic { padding: 0 8px; color: #e6edf3; background: #15383a; }
      #custom-restic.running { color: #9fe7e7; border-left: 2px solid #33c5c5; }
      #custom-restic.done { color: #98c379; }
      #custom-restic.failed { color: #e06c75; background: #3a1a1e; }
      window.side #custom-updates, window.side #custom-startup-sound, window.side #custom-jquake, window.side #custom-services, window.side #tray { padding: 4px 0; color: #9fe7e7; background: transparent; }
      window.side #custom-updates, window.side #custom-startup-sound, window.side #custom-jquake, window.side #custom-services { font-family: "${waybarFont}", sans-serif; font-size: 13px; min-width: 34px; padding: 8px 0; }
      window.side #custom-updates.idle { color: #6b7785; }
      window.side #custom-updates.available { color: #9fe7e7; background: #15383a; border-top: 2px solid #33c5c5; }
      window.side #custom-startup-sound { padding: 6px 0; border-top: 1px solid #15383a; }
      window.side #custom-startup-sound.disabled { color: #6b7785; }
      window.side #custom-startup-sound.empty { color: #e5c07b; border-left: 2px solid #e5c07b; }
      window.side #custom-jquake { padding: 7px 0; border-top: 1px solid #15383a; }
      window.side #custom-jquake.open { color: #e6edf3; background: #15383a; border-left: 2px solid #33c5c5; }
      window.side #custom-jquake.degraded { color: #e5c07b; border-left: 2px solid #e5c07b; }
      window.side #custom-jquake.failed { color: #e06c75; background: #3a1a1e; border-left: 2px solid #e06c75; }
      window.side #custom-services { padding: 6px 0 3px 0; border-top: 1px solid #15383a; }
      window.side #custom-services.degraded { border-left: 2px solid #e5c07b; }
      window.side #custom-services.failed { background: #3a1a1e; border-left: 2px solid #e06c75; }
      window.side #tray { padding: 3px 0 6px 0; }
      #battery.charging, #battery.plugged, #battery.full, #battery.discharging, #battery.warning, #battery.critical { background: transparent; animation: none; }
      #battery.warning { color: #e5c07b; }
      #battery.critical { color: #e06c75; }
      #network.disconnected { color: #6b7785; }
      #pulseaudio.muted { color: #6b7785; }
    '';
  };

  xdg.configFile."satty/config.toml".text = ''
    [general]
    early-exit = ["copy", "save"]
    corner-roundness = 8
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
      "#33c5c5",
      "#e06c75",
      "#e5c07b",
      "#98c379",
      "#61afef",
      "#ffffff",
    ]
  '';

  services.mako = {
    enable = true;
    settings = {
      font = "JetBrainsMono Nerd Font 11";
      background-color = "#0b0f14dd";
      text-color = "#e6edf3";
      border-color = "#33c5c5";
      border-size = 2;
      border-radius = 0;
      padding = 10;
      margin = 8;
      default-timeout = 8000;
      max-visible = 4;
      layer = "overlay";
    };
  };
}
