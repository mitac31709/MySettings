# Hyprland Home Manager: standard Hyprland 0.57+ Lua desktop (UWSM) + Colorshell.
# Visual system: Colorshell (GTK4 + Astal) with pywal16 dynamic color engine from wallpaper
# (border color sync enabled), seeded with Nocturne Slate wallpaper (lib/theme.nix).
# Ecosystem: colorshell, hyprpaper, hyprsunset, hyprlock, hypridle, hyprshot, hyprpicker, satty, rofi.
{
  inputs,
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
  cursorSizeStr = toString theme.cursor.size;

  wallpaperExtensions = [
    "png"
    "jpg"
    "jpeg"
    "webp"
    "avif"
    "bmp"
    "gif"
  ];
  isWallpaperFile =
    name: lib.any (ext: lib.hasSuffix ".${ext}" (lib.toLower name)) wallpaperExtensions;
  repoWallpapersDir = ./wallpapers;
  repoWallpaperFiles =
    if builtins.pathExists repoWallpapersDir then
      lib.mapAttrs'
        (name: _: lib.nameValuePair "wallpapers/${name}" { source = repoWallpapersDir + "/${name}"; })
        (
          lib.filterAttrs (name: type: (type == "regular" || type == "symlink") && isWallpaperFile name) (
            builtins.readDir repoWallpapersDir
          )
        )
    else
      { };

  isChromebook = flakeTarget == "chromebook";
  inputSection = if isChromebook then "入力・Chromebook" else "入力・VAIO";
  powerSection = if isChromebook then "電源・Type-C" else "電源・省電力";
  repoPath = config.mitac.repoPath;
  flakeUpdateCheck = lib.getExe config.mitac.scripts.flakeUpdateCheck;
  flakeUpdate = lib.getExe config.mitac.scripts.flakeUpdate;

  colorshellPkg = pkgs.callPackage ../pkgs/colorshell {
    baseColorshell = inputs.colorshell.packages.${pkgs.stdenv.hostPlatform.system}.colorshell;
  };
  # pkgs/agent-run-status speaks the t3code 0.1.11 orchestration v2 RPC. A version
  # bump that moves t3code fails evaluation here instead of shipping a silent mismatch.
  agentRunStatus =
    if pkgs.t3code.version != "0.1.11" then
      throw "agent-run-status expects t3code 0.1.11, but pkgs.t3code is ${pkgs.t3code.version}. Update pkgs/agent-run-status before bumping t3code."
    else
      pkgs.callPackage ../pkgs/agent-run-status { };
  agentRunBin = lib.getExe agentRunStatus;
  t3Bin = "${pkgs.t3code}/bin/t3";
  t3DesktopBin = "${pkgs.t3code}/bin/t3code-desktop";
  xdgOpenBin = lib.getExe' pkgs.xdg-utils "xdg-open";
  colorshellBin = lib.getExe config.programs.colorshell.package;
  ghosttyBin = "${pkgs.ghostty}/bin/ghostty";
  flakeUpdateRunner = pkgs.writeShellScript "run-flake-update" ''
    rc=0
    ${flakeUpdate} || rc=$?
    printf '\n終了コード: %d [Enter で閉じる] ' "$rc"
    IFS= read -r _ || true
  '';
  openFlakeUpdate = pkgs.writeShellScriptBin "open-flake-update" ''
    exec ${ghosttyBin} -e ${flakeUpdateRunner}
  '';
  rofiBin = lib.getExe config.programs.rofi.package;
  yaziBin = "${pkgs.yazi}/bin/yazi";
  nemoBin = "${pkgs.nemo-with-extensions}/bin/nemo";
  hyprlockBin = "${pkgs.hyprlock}/bin/hyprlock";
  hyprpickerBin = "${pkgs.hyprpicker}/bin/hyprpicker";
  hyprctlBin = "${pkgs.hyprland}/bin/hyprctl";
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  btopBin = "${pkgs.btop}/bin/btop";
  nmtuiBin = "${pkgs.networkmanager}/bin/nmtui";
  openBtop = pkgs.writeShellScript "colorshell-open-btop" ''
    exec ${ghosttyBin} -e ${btopBin}
  '';
  openNmtui = pkgs.writeShellScript "colorshell-open-nmtui" ''
    exec ${ghosttyBin} -e ${nmtuiBin}
  '';

  # Initial writable hyprpaper.conf seeded for Colorshell (hyprpaper 0.8+ block syntax).
  initialHyprpaperConf = pkgs.writeText "hyprpaper-initial.conf" ''
    # Initial hyprpaper config seeded for Colorshell (writable so wallpaper changes persist).
    splash = false
    ipc = true

    wallpaper {
        monitor =
        path = ${config.home.homeDirectory}/wallpapers/nocturne-slate.png
        fit_mode = cover
    }
  '';

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
  # nixpkgs' hyprtasking pin (2026-09-20) predates Hyprland 0.57 CHLWorkspace API
  # changes; track upstream PR #140 (Hyprland 0.57 support, 2026-11-10).
  hyprtaskingPkg = pkgs.hyprlandPlugins.hyprtasking.overrideAttrs (_old: {
    version = "0-unstable-2026-11-10";
    src = pkgs.fetchFromGitHub {
      owner = "raybbian";
      repo = "hyprtasking";
      rev = "04d2365d37f032af537b8d5c55efbfe15f01adc7";
      hash = "sha256-KzxmA0lqTvZKq/AHdSu2juugkfXwLC6ywR4BeAfiIIg=";
    };
  });

  # Presentation marker toggled with `toggle-keep-screen-on` or Capsomnia Keep Display Awake.
  # XDG_RUNTIME_DIR is session-scoped so it clears automatically on logout.
  lockOnceCmd = pkgs.writeShellScript "hypr-lock-once" ''
    if ${pkgs.procps}/bin/pgrep -x hyprlock >/dev/null 2>&1; then
      exit 0
    fi
    exec ${hyprlockBin} "$@"
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
    exec ${lockOnceCmd} --grace 5
  '';
  idleLockDpmsOffCmd = pkgs.writeShellScript "hypr-idle-lock-dpms-off" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ] || [ -e "''${XDG_RUNTIME_DIR}/capsomnia/keep-display-awake" ]; then
      exit 0
    fi
    if ${pkgs.procps}/bin/pgrep -x hyprlock >/dev/null 2>&1; then
      exec ${hyprctlBin} dispatch 'hl.dsp.dpms({ action = "off" })'
    fi
  '';
  idleDpmsOffCmd = pkgs.writeShellScript "hypr-idle-dpms-off" ''
    if [ -e "''${XDG_RUNTIME_DIR}/hypr-keep-screen-on" ] || [ -e "''${XDG_RUNTIME_DIR}/capsomnia/keep-display-awake" ]; then
      exit 0
    fi
    exec ${hyprctlBin} dispatch 'hl.dsp.dpms({ action = "off" })'
  '';
  idleDpmsOnCmd = pkgs.writeShellScript "hypr-idle-dpms-on" ''
    ${hyprctlBin} dispatch 'hl.dsp.dpms({ action = "on" })' >/dev/null 2>&1 || true
    ${brightnessctl} -r >/dev/null 2>&1 || true
  '';
  lockBatteryCmd = pkgs.writeShellScript "hyprlock-battery" ''
    bat=""
    for b in /sys/class/power_supply/BAT*; do
      if [ -r "$b/capacity" ]; then
        bat="$b"
        break
      fi
    done
    [ -n "$bat" ] || exit 0
    cap="$(cat "$bat/capacity" 2>/dev/null || true)"
    stat="$(cat "$bat/status" 2>/dev/null || true)"
    [ -n "$cap" ] || exit 0
    case "$stat" in
      Charging) icon="󰂄" ;;
      Full|"Not charging") icon="󰁹" ;;
      *)
        if [ "$cap" -ge 80 ]; then icon="󰂁"
        elif [ "$cap" -ge 50 ]; then icon="󰁾"
        elif [ "$cap" -ge 20 ]; then icon="󰁻"
        else icon="󰂃"
        fi
        ;;
    esac
    printf '%s %s%%' "$icon" "$cap"
  '';
  lockMediaCmd = pkgs.writeShellScript "hyprlock-media" ''
    status="$(${pkgs.playerctl}/bin/playerctl status 2>/dev/null || true)"
    case "$status" in
      Playing) icon="󰎈" ;;
      Paused) icon="󰏤" ;;
      *) exit 0 ;;
    esac
    meta="$(${pkgs.playerctl}/bin/playerctl metadata --format '{{artist}} - {{title}}' 2>/dev/null || true)"
    meta="''${meta# - }"
    meta="''${meta% - }"
    [ -n "$meta" ] || exit 0
    if [ "''${#meta}" -gt 52 ]; then
      meta="''${meta:0:51}…"
    fi
    printf '%s %s' "$icon" "$meta"
  '';
  lockStatusCmd = pkgs.writeShellScript "hyprlock-status" ''
    ssid="$(${pkgs.networkmanager}/bin/nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | ${pkgs.gnugrep}/bin/grep '^yes:' | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d: -f2- || true)"
    if [ -n "$ssid" ]; then
      printf '%s · %s  󰖩 %s' "${config.home.username}" "${flakeTarget}" "$ssid"
    else
      printf '%s · %s' "${config.home.username}" "${flakeTarget}"
    fi
  '';
  toggleKeepScreenOn = pkgs.writeShellApplication {
    name = "toggle-keep-screen-on";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.libnotify
    ];
    text = ''
      marker="''${XDG_RUNTIME_DIR}/hypr-keep-screen-on"
      if out="$(${capsomniaPkg}/bin/cpsm --json toggle --no-sleep 2>/dev/null)" \
        && printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
        rm -f "$marker"
        awake="$(printf '%s\n' "$out" | jq -r '.result.awake_on // false')"
        timer_active="$(printf '%s\n' "$out" | jq -r '.result.timer.active // false')"
        rem_sec="$(printf '%s\n' "$out" | jq -r '.result.timer.remaining_seconds // empty')"
        if [ "$awake" = "true" ]; then
          if [ "$timer_active" = "true" ] && [ -n "$rem_sec" ]; then
            mins=$(( (rem_sec + 59) / 60 ))
            notify-send "画面常時オン: ON" "自動減光・ロック・消灯・蓋閉じスリープを抑止中（自動オフ: 約 ''${mins}分）" >/dev/null 2>&1 || true
          else
            notify-send "画面常時オン: ON" "自動減光・ロック・消灯・蓋閉じスリープを抑止しています" >/dev/null 2>&1 || true
          fi
        else
          notify-send "画面常時オン: OFF" "通常の自動減光・ロック・消灯・蓋閉じスリープに戻しました" >/dev/null 2>&1 || true
        fi
        exit 0
      fi

      if [ -e "$marker" ]; then
        rm -f "$marker"
        notify-send "画面常時オン: OFF" "通常の自動減光・ロック・消灯に戻しました" >/dev/null 2>&1 || true
      else
        touch "$marker"
        notify-send "画面常時オン: ON" "自動減光・ロック・消灯を抑止しています" >/dev/null 2>&1 || true
      fi
    '';
  };

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
  openYazi = "${ghosttyBin} -e ${yaziBin}";

  ntpSync = pkgs.writeShellApplication {
    name = "ntp-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
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

  jquakeOpen = pkgs.writeShellApplication {
    name = "jquake-open";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.libnotify
      pkgs.stalonetray
      pkgs.systemd
    ];
    text = ''
      # Raise the map without taking keyboard focus: forcing focus onto the
      # Java/AWT XWayland window can leave Ctrl/Alt logically held when a
      # modifier is released during the grab.
      raise_map() {
        ${hyprctlBin} dispatch 'hl.dsp.window.alter_zorder({ mode = "top", window = "class:^net-jquake-app-Main$" })' >/dev/null 2>&1 || true
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
      fi

      if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
        raise_map
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
        exit 1
      fi

      for _ in $(seq 1 20); do
        if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
          raise_map
          break
        fi
        sleep 0.1
      done
    '';
  };

  # Bar-button action: toggle the JQuake window. The service stays resident in
  # the tray (persistentMode + winChoice=2), so a WM_DELETE hides the window
  # back to the icon instead of quitting it.
  jquakeToggle = pkgs.writeShellApplication {
    name = "jquake-toggle";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      if ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
        ${hyprctlBin} dispatch 'hl.dsp.window.close({ window = "class:^net-jquake-app-Main$" })' >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
          if ! ${hyprctlBin} clients -j 2>/dev/null | jq -e '[.[] | select(.class == "net-jquake-app-Main")] | length > 0' >/dev/null; then
            break
          fi
          sleep 0.05
        done
        exit 0
      fi

      exec ${lib.getExe jquakeOpen}
    '';
  };

  jquakeMenu = pkgs.writeShellApplication {
    name = "jquake-menu";
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

            case "$choice" in
              *"ウィンドウを開く")
                exec ${lib.getExe jquakeOpen}
                ;;
              *"再起動"*)
                systemctl --user reset-failed stalonetray-jquake.service jquake.service jquake-hypr-alert.service >/dev/null 2>&1 || true
                systemctl --user restart stalonetray-jquake.service jquake.service jquake-hypr-alert.service
                ;;
              *"停止")
                systemctl --user stop jquake.service jquake-hypr-alert.service stalonetray-jquake.service
                ;;
              *"開始")
                systemctl --user reset-failed stalonetray-jquake.service jquake.service jquake-hypr-alert.service >/dev/null 2>&1 || true
                systemctl --user start stalonetray-jquake.service jquake.service jquake-hypr-alert.service
                ;;
              *"状態・ログ表示")
                exec ${ghosttyBin} -e ${pkgs.bash}/bin/bash -lc "systemctl --user status jquake stalonetray-jquake jquake-hypr-alert --no-pager; echo; journalctl --user -u jquake -u stalonetray-jquake -u jquake-hypr-alert -n 30 --no-pager; printf '\n[Enter で閉じる] '; IFS= read -r _ || true"
                ;;
            esac
    '';
  };

  servicesMenu = pkgs.writeShellApplication {
    name = "services-menu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.ghostty
      pkgs.rofi
      pkgs.systemd
      pkgs.nemo-with-extensions
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

            uc_s="$(u_state uniclipd.service)"
            lm_s="$(u_state lan-mouse.service)"
            td_s="$(u_state taildrop-receive.service)"
            ct_s="$(u_state cliphist-text.service)"
            ci_s="$(u_state cliphist-image.service)"
            ts_s="$(s_state tailscaled.service)"
            if [ "$ts_s" = "active" ]; then
              ts_b="$(${pkgs.tailscale}/bin/tailscale status --json --peers=false 2>/dev/null | ${pkgs.jq}/bin/jq -r '.BackendState // empty' 2>/dev/null || true)"
              [ -n "$ts_b" ] && ts_s="$ts_s / $ts_b"
            fi
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
      Taildrop │ ~/Downloads を Nemo で開く
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
                ;;
              *"UniClipboard"*"開始")
                systemctl --user start uniclipd.service
                ;;
              *"UniClipboard"*"停止")
                systemctl --user stop uniclipd.service
                ;;
              *"UniClipboard"*"GUI を開く")
                exec ${hyprExecBin} uniclipboard
                ;;
              *"LAN Mouse"*"再起動")
                systemctl --user restart lan-mouse.service
                ;;
              *"LAN Mouse"*"開始")
                systemctl --user start lan-mouse.service
                ;;
              *"LAN Mouse"*"停止")
                systemctl --user stop lan-mouse.service
                ;;
              *"LAN Mouse"*"GUI を開く")
                exec ${hyprExecBin} lan-mouse
                ;;
              *"Taildrop Receive"*"再起動")
                systemctl --user restart taildrop-receive.service
                ;;
              *"Taildrop Receive"*"開始")
                systemctl --user start taildrop-receive.service
                ;;
              *"Taildrop Receive"*"停止")
                systemctl --user stop taildrop-receive.service
                ;;
              *"Taildrop"*"Nemo"*)
                exec ${hyprExecBin} "${nemoBin}" "$HOME/Downloads"
                ;;
              *"Cliphist"*"再起動")
                systemctl --user restart cliphist-text.service cliphist-image.service
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
                ;;
              *"Restic"*"backup status"*)
                run_term "backup status"
                ;;
              *"Restic"*"backup log"*)
                run_term "backup log"
                ;;
              *"Restic"*"sudo backup run"*)
                run_term "sudo backup run"
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
      label = "Colorshell ランナー（アプリ / >履歴 / #壁紙 / 計算 / コマンド）";
      keys = "Super+D / Super+Space / Alt+Space";
      run = "${colorshellBin} runner";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell アプリ一覧（Apps Drawer）";
      keys = "Win+Shift / Super+Shift+D";
      run = "${colorshellBin} toggle -w apps-drawer";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell 壁紙切替・動的配色（pywal16）";
      keys = "Super+W";
      run = "${colorshellBin} runner -t '#'";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell コントロールセンター（Wi-Fi / BT / 音量 / バッテリー詳細）";
      keys = "Super+I";
      run = "${colorshellBin} toggle -w control-center";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell カレンダー・世界時計・GPST・NTP・メディア";
      keys = "Super+M";
      run = "${colorshellBin} toggle -w center-window";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell 電源・ログアウトメニュー";
      keys = "Super+X";
      run = "${colorshellBin} toggle -w logout-menu";
      mode = "exec";
    }
    {
      section = "起動・終了";
      label = "Colorshell リロード";
      run = "${colorshellBin} reload";
      mode = "exec";
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
      label = "ワークスペース俯瞰 (Hyprtasking: 左ドラッグ移動 / 右クリック選択 / 1-9ジャンプ / Esc終了)";
      keys = "Alt+Tab / Alt+Shift+Tab / 4本指上スワイプ";
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
      label = "このシート";
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
      keys = "Super+G / Super+(Alt|Shift)+Tab / Super+Alt+G";
    }
    {
      section = "ウィンドウ・WS";
      label = "HyprEndfield HUD 開閉";
      keys = "Super+Tab";
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
      label = "注: Super+E は Yazi、Super+Shift+E は Nemo、外部リンクは Vivaldi へ自動フォーカス";
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
      label = "クリップボード履歴（rofi / ランナー `>` でも可）";
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
      keys = "Ctrl+Super+Space";
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
    (lib.optionals (!isChromebook) [
      {
        section = inputSection;
        label = "指紋を登録（fprintd-enroll・数回タッチ／スワイプ）";
        run = "fprintd-enroll";
        mode = "term";
      }
      {
        section = inputSection;
        label = "登録済み指紋を確認 (fprintd-list)";
        run = "fprintd-list \"$USER\"";
        mode = "term";
      }
      {
        section = inputSection;
        label = "指紋認証テスト (fprintd-verify)";
        run = "fprintd-verify";
        mode = "term";
      }
      {
        section = inputSection;
        label = "登録済み指紋を全削除 (fprintd-delete)";
        run = "fprintd-delete \"$USER\"";
        mode = "show";
      }
    ])
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
      label = "Nemo（GUI ファイラー）";
      keys = "Super+Shift+E";
      run = nemoBin;
      mode = "exec";
    }
    {
      section = "Yazi / Neovim";
      label = "隠し表示 / spot / 開く";
      keys = ". / Tab / Enter";
    }
    {
      section = "Yazi / Neovim";
      label = "移動(カット) / コピー / 貼付 / 解除 / 選択";
      keys = "x / y / p(上書P) / X / Space";
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
      label = "パス指定移動（外部ドライブ: /run/media/$USER）";
      keys = "g Space";
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
    # Colorshell・日常
    {
      section = "Colorshell・日常";
      label = "サービス管理メニュー（UniClipboard / LAN Mouse / Taildrop / Cliphist / Tailscale / Restic）";
      run = lib.getExe servicesMenu;
      mode = "exec";
    }
    {
      section = "Colorshell・日常";
      label = "画面常時オン切替（Caps Lock・蓋閉じ処理継続・自動オフタイマー統合）";
      keys = "CapsLock / バークリック";
      run = lib.getExe toggleKeepScreenOn;
      mode = "exec";
    }
    {
      section = "Colorshell・日常";
      label = "btop";
      run = btopBin;
      mode = "term";
    }
    {
      section = "Colorshell・日常";
      label = "nmtui";
      run = nmtuiBin;
      mode = "term";
    }
    {
      section = "Colorshell・日常";
      label = "Chawan（端末ブラウザ: cha / mancha）";
      run = "cha";
      mode = "term";
    }
    {
      section = "Colorshell・日常";
      label = "日本語 TTY (kmscon) 切替 / GUI へ戻る";
      keys = "Ctrl+Alt+F2-F6 / Ctrl+Alt+F1";
    }
    {
      section = "Colorshell・日常";
      label = "NTP 時刻同期 (ntp-sync)";
      keys = "時計右クリック / Super+M";
      run = lib.getExe ntpSync;
      mode = "exec";
    }
    {
      section = "Colorshell・日常";
      label = "5分暗転 / 10分ロック(5秒猶予) / 15分消灯・ロック中45秒消灯 (hypridle)";
      keys = "無操作 / ロック中 Super+Esc で即消灯";
    }
    {
      section = "Colorshell・日常";
      label = "壁紙追加（即反映 / 同期）→ Super+W 切替";
      keys = "~/wallpapers/ / home/wallpapers/";
    }
    {
      section = "Colorshell・日常";
      label = "カーソル追加・変更（仮テスト: hyprctl setcursor）";
      keys = "home/cursors/ + lib/theme.nix";
    }
    {
      section = "Colorshell・日常";
      label = "カーソル未反映 → 実体と hyprcursors/ を確認";
      keys = "hyprctl reload config-only + setcursor";
    }
    {
      section = "Colorshell・日常";
      label = "LAN 送受信 / キー表示";
      keys = "LocalSend / showmethekey";
    }
    {
      section = "Colorshell・日常";
      label = "AI（ランナーから起動）";
      keys = "ChatGPT / Grok";
    }
    {
      section = "Colorshell・日常";
      label = "Teams 等 PWA が開かない";
      keys = "古い /nix/store の Exec → vivaldi-pwa-desktop-fix";
    }
    {
      section = "Colorshell・日常";
      label = "Vivaldi PWA ショートカット修復";
      run = "vivaldi-pwa-desktop-fix";
      mode = "term";
    }
    {
      section = "Colorshell・日常";
      label = "Vivaldi 拡張が全部壊れている";
      keys = "Extensions 欠落 → Vivaldi終了後に vivaldi-extensions-repair";
    }
    {
      section = "Colorshell・日常";
      label = "Vivaldi 拡張を CRX キャッシュから復旧";
      run = "vivaldi-extensions-repair";
      mode = "term";
    }
    # Cursor 進捗（他アプリ使用中）
    {
      section = "Cursor 進捗";
      label = "完了・入力待ち → Colorshell 通知";
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
      label = "更新チェック（Colorshell バー更新アイコン右クリック／6h 自動）";
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
      label = "T3 Code LAN: http://<LAN-IP>:3773（192.168.0.0/18 のみ許可）";
    }
    {
      section = "開発";
      label = "エージェントカード（実行中の模擬）";
      run = "agent-run-status mock running";
      mode = "exec";
    }
    {
      section = "開発";
      label = "エージェントカード（承認待ちの模擬）";
      run = "agent-run-status mock approval";
      mode = "exec";
    }
    {
      section = "開発";
      label = "エージェントカード（完了の模擬）";
      run = "agent-run-status mock done";
      mode = "exec";
    }
    {
      section = "開発";
      label = "エージェントカード（複数の模擬）";
      run = "agent-run-status mock multi";
      mode = "exec";
    }
    {
      section = "開発";
      label = "模擬カードを消す";
      run = "agent-run-status mock clear";
      mode = "exec";
    }
    {
      section = "開発";
      label = "模擬中に本接続が上書きするときは systemctl --user stop agent-run-status（戻すときは start）";
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
      label = "Antigravity";
      run = "agy";
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
    {
      section = "開発";
      label = "シェル履歴検索（Atuin・連打で絞込切替）";
      keys = "Ctrl+R";
    }
    {
      section = "開発";
      label = "シェル履歴統計（Atuin）";
      run = "atuin stats";
      mode = "term";
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
      label = "外部ドライブをマウント / 解除（udisksctl）";
      run = "udisksctl mount -b /dev/sdX1  # 解除: udisksctl unmount -b /dev/sdX1";
      mode = "show";
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
      run = "rm -rf ~/.local/share/platformio/.cache && du -sh ~/.local/share/platformio";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "npm npx キャッシュ削除";
      run = "rm -rf ~/.cache/npm/_npx && du -sh ~/.cache/npm";
      mode = "term";
    }
    {
      section = "ディスク容量";
      label = "PIO 版付き toolchain 重複削除";
      run = "rm -rf ~/.local/share/platformio/packages/toolchain-*@* && ls -d ~/.local/share/platformio/packages/toolchain-*";
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
      label = "注: vaio 左端 → chromebook (tuigreet ログイン画面も可・解除 Ctrl+Shift+Super+Alt)";
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
      label = "backup status（状態・容量・直近詳細）";
      run = "backup status";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup status --full（systemd 詳細・ログ）";
      run = "backup status --full";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup forget --prune --dry-run（削除対象の確認）";
      run = "backup forget --keep-last 3 --prune --dry-run";
      mode = "term";
    }
    {
      section = "バックアップ";
      label = "backup forget <ID> --prune（削除・危険）";
      run = "backup forget <ID> --prune";
      mode = "show";
    }
    {
      section = "バックアップ";
      label = "backup prune（未使用データの回収・危険）";
      run = "backup prune";
      mode = "show";
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
      label = "注: 削除はスナップショット単位。forget は --prune で容量回収";
    }
    {
      section = "バックアップ";
      label = "注: リポジトリは端末別 (<host>-home)。他参照は RESTIC_REPOSITORY=…";
    }
    {
      section = "バックアップ";
      label = "注: 素の rclone は設定未読。RCLONE_CONFIG に agenix の一時コピーが必要";
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
      label = "画面常時オン (Capsomnia) メニュー（Caps Lock 切替・蓋閉じ処理継続・タイマー）";
      keys = "CapsLock / Super+Alt+C";
      run = "${capsomniaPkg}/bin/capsomnia-menu";
      mode = "exec";
    }
    {
      section = powerSection;
      label = "画面常時オン (Capsomnia) 詳細設定（蓋閉じ維持・自動ロック・テザリング維持・自動オフ）";
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
      label = "JQuake 表示 (jquake-open)";
      run = "${lib.getExe jquakeOpen}";
      mode = "exec";
    }
    {
      section = "周辺";
      label = "JQuake 表示/非表示トグル (jquake-toggle)";
      run = "${lib.getExe jquakeToggle}";
      mode = "exec";
    }
    {
      section = "周辺";
      label = "JQuake 管理メニュー (jquake-menu)";
      run = "${lib.getExe jquakeMenu}";
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
      label = "警報時は hyprlock 解除→全WS追従(pin)で前面化・最大化（緊急）";
    }
    # コンテナ
    {
      section = "コンテナ";
      label = "Podman コンテナ一覧";
      run = "podman ps -a";
      mode = "term";
    }
    {
      section = "コンテナ";
      label = "Kali 使い捨てコンテナ起動（Podman）";
      run = "podman run --rm -it docker.io/kalilinux/kali-rolling bash";
      mode = "show";
    }
    {
      section = "コンテナ";
      label = "Distrobox 一覧";
      run = "distrobox list";
      mode = "term";
    }
    {
      section = "コンテナ";
      label = "Distrobox Kali 作成";
      run = "distrobox create --name kali --image docker.io/kalilinux/kali-rolling";
      mode = "show";
    }
    {
      section = "コンテナ";
      label = "Distrobox Kali に入る";
      run = "distrobox enter kali";
      mode = "term";
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
  imports = [
    inputs.colorshell.homeManagerModules.default
  ];

  home.packages = [
    pkgs.hypridle
    pkgs.hyprpicker
    pkgs.hyprshot
    pkgs.satty
    pkgs.brightnessctl
    pkgs.playerctl
    pkgs.jq
    hyprExec
    screenshotBin
    jquakeOpen
    jquakeToggle
    jquakeMenu
    servicesMenu
    ntpSync
    toggleKeepScreenOn
    openFlakeUpdate
    agentRunStatus
    pkgs.hyprendfield
  ];

  # HyprEndfield (Arknights: Endfield HUD overlay) background daemon.
  systemd.user.services.hyprendfield = {
    Unit = {
      Description = "HyprEndfield HUD Overlay Daemon";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.hyprendfield} --background";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

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
    plugins = [ hyprtaskingPkg ];

    settings = {
      monitor = {
        output = "";
        mode = "preferred";
        position = "auto";
        scale = 1;
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
          kb_options = "caps:none";
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
          allow_pin_fullscreen = true;
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
          name = "rofi-frosted";
          match = {
            namespace = "^rofi$";
          };
          blur = true;
          ignore_alpha = 0.2;
          animation = "popin 92%";
        }
        {
          name = "hyprendfield-frosted-background";
          match = {
            namespace = "^hyprendfield$";
          };
          blur = true;
          ignore_alpha = 0.1;
        }
      ];
    };

    extraConfig = ''
      -- Cursor theme/size (from lib/theme.nix) & Colorshell wallpaper directory
      hl.env("XCURSOR_THEME", ${builtins.toJSON theme.cursor.name})
      hl.env("XCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
      hl.env("HYPRCURSOR_THEME", ${builtins.toJSON theme.cursor.name})
      hl.env("HYPRCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
      ${lib.optionalString theme.cursor.hyprcursor ''hl.env("HYPRCURSOR_THEME", ${builtins.toJSON theme.cursor.name})''}
      hl.env("WALLPAPERS", os.getenv("HOME") .. "/wallpapers")

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

      -- Session startup hooks (Colorshell, Polkit, Hyprpaper, Hyprsunset, Hypridle, Cliphist run via systemd user units)
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

      -- Core applications, Colorshell launcher & panels
      hl.bind(mod .. " + Return",    hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind("CTRL + ALT + T",      hl.dsp.exec_cmd(${builtins.toJSON ghosttyBin}))
      hl.bind(mod .. " + D",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} runner"}), { dont_inhibit = true })
      hl.bind(mod .. " + Space",     hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} runner"}), { dont_inhibit = true })
      hl.bind("ALT + Space",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} runner"}), { dont_inhibit = true })
      hl.bind(mod .. " + SHIFT + D", hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w apps-drawer"}), { dont_inhibit = true })
      hl.bind(mod .. " + Shift_L",   hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w apps-drawer"}), { release = true, dont_inhibit = true })
      hl.bind(mod .. " + Shift_R",   hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w apps-drawer"}), { release = true, dont_inhibit = true })
      hl.bind("SHIFT + Super_L",     hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w apps-drawer"}), { release = true, dont_inhibit = true })
      hl.bind("SHIFT + Super_R",     hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w apps-drawer"}), { release = true, dont_inhibit = true })
      hl.bind(mod .. " + W",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} runner -t \"#\""}), { dont_inhibit = true })
      hl.bind(mod .. " + I",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w control-center"}), { dont_inhibit = true })
      hl.bind(mod .. " + M",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w center-window"}), { dont_inhibit = true })
      hl.bind(mod .. " + X",         hl.dsp.exec_cmd(${builtins.toJSON "${colorshellBin} toggle -w logout-menu"}), { dont_inhibit = true })
      hl.bind(mod .. " + P",         hl.dsp.exec_cmd(${builtins.toJSON "${rofiRunner}"}), { dont_inhibit = true })
      hl.bind(mod .. " + N",         hl.dsp.exec_cmd(${builtins.toJSON (lib.getExe newWorkspace)}), { dont_inhibit = true })
      hl.bind(mod .. " + E",         hl.dsp.exec_cmd(${builtins.toJSON openYazi}))
      hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd(${builtins.toJSON nemoBin}))
      hl.bind(mod .. " + V",         hl.dsp.exec_cmd("clipboard-history"))
      hl.bind(mod .. " + L",         hl.dsp.exec_cmd(${builtins.toJSON "${lockOnceCmd}"}))
      hl.bind(mod .. " + slash",     hl.dsp.exec_cmd(${builtins.toJSON "${showCheatsheet}"}), { dont_inhibit = true })
      hl.bind(mod .. " + question",  hl.dsp.exec_cmd(${builtins.toJSON "${showCheatsheet}"}), { dont_inhibit = true })

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
      hl.bind(mod .. " + G",           hl.dsp.group.toggle())
      hl.bind(mod .. " + ALT + Tab",   hl.dsp.group.next())
      hl.bind(mod .. " + SHIFT + Tab", hl.dsp.group.prev())
      hl.bind(mod .. " + ALT + G",     hl.dsp.group.lock())

      -- HyprEndfield HUD overlay
      local hyprEndfield = ${builtins.toJSON (lib.getExe pkgs.hyprendfield)}
      hl.bind(mod .. " + Tab", hl.dsp.exec_cmd(hyprEndfield .. " --toggle"))

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
      hl.bind(mod .. " + Escape",      hl.dsp.exec_cmd(${builtins.toJSON "${idleDpmsOffCmd}"}), { locked = true })

      -- Hyprtasking: workspace overview (Alt+Tab / Alt+Shift+Tab, Esc to close)
      hl.config({
        plugin = {
          hyprtasking = {
            layout = "grid",
            gap_size = 10,
            bg_color = 0xff${p.bgHex},
            border_size = 2,
            exit_on_hovered = false,
            warp_on_move_window = 1,
            close_overview_on_reload = true,
            drag_button = 0x110,
            select_button = 0x111,
            jump = {
              enabled = true,
              show_workspace_names = false,
              label_color = 0xff${p.fgHex},
              label_background = 0xcc${p.surfaceHex},
              label_size = 32,
            },
            gestures = {
              enabled = true,
              move_fingers = 3,
              move_distance = 300,
              open_fingers = 4,
              open_distance = 300,
              open_positive = true,
            },
            grid = {
              rows = 3,
              cols = 3,
              loop = false,
              layers = 1,
              loop_layers = true,
              gaps_use_aspect_ratio = true,
            },
          },
        },
      })
      hl.bind("ALT + TAB", function()
        if hl.plugin and hl.plugin.hyprtasking then
          hl.plugin.hyprtasking.toggle("cursor")
        end
      end)
      hl.bind("ALT + SHIFT + TAB", function()
        if hl.plugin and hl.plugin.hyprtasking then
          hl.plugin.hyprtasking.toggle("all")
        end
      end)
      hl.bind("escape", function()
        if hl.plugin and hl.plugin.hyprtasking and hl.plugin.hyprtasking.is_active() then
          hl.plugin.hyprtasking.toggle("all")
        end
      end, { non_consuming = true })

      -- Interactive resize submap
      hl.define_submap("resize", "escape", function()
        hl.bind("right",  hl.dsp.window.resize({ x = 24,  y = 0,   relative = true }), { repeating = true })
        hl.bind("left",   hl.dsp.window.resize({ x = -24, y = 0,   relative = true }), { repeating = true })
        hl.bind("up",     hl.dsp.window.resize({ x = 0,   y = -24, relative = true }), { repeating = true })
        hl.bind("down",   hl.dsp.window.resize({ x = 0,   y = 24,  relative = true }), { repeating = true })
        hl.bind("l",      hl.dsp.window.resize({ x = 24,  y = 0,   relative = true }), { repeating = true })
        hl.bind("h",      hl.dsp.window.resize({ x = -24, y = 0,   relative = true }), { repeating = true })
        hl.bind("k",      hl.dsp.window.resize({ x = 0,   y = -24, relative = true }), { repeating = true })
        hl.bind("j",      hl.dsp.window.resize({ x = 0,   y = 24,  relative = true }), { repeating = true })
        hl.bind("Return", hl.dsp.submap("reset"))
      end)

      -- HyprEndfield submap (activated while HUD is visible)
      hl.define_submap("hyprendfield", function()
        hl.bind(mod .. " + Tab", function()
          hl.dispatch(hl.dsp.submap("reset"))
          hl.dispatch(hl.dsp.exec_cmd(hyprEndfield .. " --toggle"))
        end)
        hl.bind("Print", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} full"}))
        hl.bind("CTRL + ALT + A", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe screenshotBin} region"}))
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
        ${hyprctlBin} -i "$inst" setcursor ${lib.escapeShellArg theme.cursor.name} ${cursorSizeStr} >/dev/null 2>&1 || true
      done
    fi
  '';

  # Colorshell (GTK4 + Astal): top bar, notifications, control center, runner,
  # logout menu, OSD, wallpaper switcher + pywal16 dynamic color engine.
  # Disable Colorshell's bundled hyprlock template (uses removed disable_loading_bar
  # and bare bash/playerctl/hostnamectl missing from hypridle's service PATH);
  # configure programs.hyprlock explicitly below.
  programs.colorshell = {
    enable = true;
    package = colorshellPkg;
    hyprpaper.enable = true;
    hyprsunset.enable = true;
    hyprlock.enable = false;
    settings = {
      color = {
        engine = "pywal16";
        backend = "default";
      };
      wallpaper = {
        dirs = [ "~/wallpapers" ];
        positioning = "cover";
        splash = false;
      };
      aliases = {
        terminal = "ghostty";
        file_manager = "nemo";
        media = "mpv";
      };
      clock = {
        date_format = "%a %m-%d %H:%M:%S";
      };
      notifications = {
        position_h = "right";
        position_v = "top";
        timeout_low = 4000;
        timeout_normal = 7000;
        timeout_critical = 0;
        hold_on_hover = true;
      };
      misc = {
        match_window_border_color = true;
      };
    };
  };

  # T3 Code (v0.1.11) orchestration RPC → $XDG_RUNTIME_DIR/agent-run-status.json.
  systemd.user.services.agent-run-status = {
    Unit = {
      Description = "T3 Code agent run status for Colorshell";
      After = [ "graphical-session.target" ];
      BindsTo = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 5;
    };
    Service = {
      ExecStart = "${agentRunBin} daemon";
      Restart = "on-failure";
      RestartSec = 2;
      Environment = [
        "T3CODE_HOME=${config.xdg.dataHome}/t3"
        "AGENT_RUN_T3=${t3Bin}"
        "AGENT_RUN_T3_DESKTOP=${t3DesktopBin}"
        "AGENT_RUN_XDG_OPEN=${xdgOpenBin}"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  systemd.user.services.colorshell = {
    Unit = {
      After = [ "hyprpaper.service" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 5;
    };
    Service = {
      RestartSec = 2;
      Environment = [
        "TZDIR=${pkgs.tzdata}/share/zoneinfo"
        "COLORSHELL_ADAPTER_DEV=${if isChromebook then "AC" else "ACAD"}"
        "COLORSHELL_FLAKE_UPDATE_CMD=${lib.getExe openFlakeUpdate}"
        "COLORSHELL_FLAKE_UPDATE_CHECK_CMD=${flakeUpdateCheck}"
        "COLORSHELL_NTP_SYNC_CMD=${lib.getExe ntpSync}"
        "COLORSHELL_CAPS_CMD=${capsomniaPkg}/bin/cpsm"
        "COLORSHELL_CAPS_SETTINGS_CMD=${capsomniaPkg}/bin/capsomnia-settings"
        "COLORSHELL_CAPS_MENU_CMD=${capsomniaPkg}/bin/capsomnia-menu"
        "COLORSHELL_JQUAKE_OPEN_CMD=${lib.getExe jquakeOpen}"
        "COLORSHELL_JQUAKE_TOGGLE_CMD=${lib.getExe jquakeToggle}"
        "COLORSHELL_JQUAKE_MENU_CMD=${lib.getExe jquakeMenu}"
        "COLORSHELL_SERVICES_MENU_CMD=${lib.getExe servicesMenu}"
        "COLORSHELL_STARTUP_SOUND_CMD=${lib.getExe config.mitac.scripts.startupSound}"
        "COLORSHELL_CHEATSHEET_CMD=${showCheatsheet}"
        "COLORSHELL_BTOP_CMD=${openBtop}"
        "COLORSHELL_NMTUI_CMD=${openNmtui}"
        "COLORSHELL_GHOSTTY_CMD=${ghosttyBin}"
        "COLORSHELL_NEMO_CMD=${nemoBin}"
        "COLORSHELL_TAILSCALE_CMD=${pkgs.tailscale}/bin/tailscale"
        "COLORSHELL_AGENT_RUN_CMD=${agentRunBin}"
        "AGENT_RUN_T3=${t3Bin}"
        "AGENT_RUN_T3_DESKTOP=${t3DesktopBin}"
        "AGENT_RUN_XDG_OPEN=${xdgOpenBin}"
      ]
      ++ lib.optionals (!isChromebook) [
        "COLORSHELL_BATTERY_DEV=BAT1"
      ];
    };
  };

  # Periodic flake / .deb update probe for the Colorshell top-bar Updates indicator & notifications.
  systemd.user.services.flake-update-check = {
    Unit = {
      Description = "Check MySettings flake / pinned .deb updates for Colorshell";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Service = {
      Type = "oneshot";
      ExecStart = flakeUpdateCheck;
    };
  };
  systemd.user.timers.flake-update-check = {
    Unit = {
      Description = "Periodic flake update check for Colorshell";
      ConditionPathExists = "${repoPath}/flake.nix";
    };
    Timer = {
      # Boot+3min often races Wi-Fi/WARP; fetches then fail spuriously.
      OnBootSec = "5min";
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # Seed default wallpaper plus any images committed under home/wallpapers/ into
  # ~/wallpapers so Colorshell (Super+W / # picker) can switch across both repo
  # presets and local images placed directly in ~/wallpapers/.
  home.file = {
    "wallpapers/nocturne-slate.png".source = wallpaperPng;
  }
  // repoWallpaperFiles;

  # Colorshell persists wallpaper switches by writing ~/.config/hypr/hyprpaper.conf.
  # Keep the file writable (do not set services.hyprpaper.settings, which creates a
  # read-only store symlink) and seed it when absent or replacing an old store symlink.
  home.activation.initHyprpaperConf = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    conf="${config.xdg.configHome}/hypr/hyprpaper.conf"
    if [ ! -e "$conf" ] || { [ -L "$conf" ] && [[ "$(readlink -f "$conf" 2>/dev/null || true)" == /nix/store/* ]]; }; then
      run rm -f "$conf"
      run mkdir -p "$(dirname "$conf")"
      run install -m 0644 "${initialHyprpaperConf}" "$conf"
    fi
  '';

  # Hyprlock (Hyprlock 0.9+ schema; replaces Colorshell's broken bundled template).
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        hide_cursor = true;
        ignore_empty_input = true;
        text_trim = false;
        fractional_scaling = 2;
      };
      animations = {
        enabled = true;
        bezier = [
          "smoothOut, 0.22, 1.0, 0.36, 1.0"
          "quick, 0.15, 0, 0.1, 1"
        ];
        animation = [
          "fadeIn, 1, 3.0, smoothOut"
          "fadeOut, 1, 2.2, smoothOut"
          "inputFieldDots, 1, 1.6, quick"
        ];
      };
      auth = {
        pam.enabled = true;
        fingerprint = {
          enabled = !isChromebook;
          ready_message = "󰈷 指紋認証でロック解除可能";
          present_message = "󰈷 指紋を読み取り中…";
          retry_delay = 250;
        };
      };
      background = [
        {
          monitor = "";
          path = "screenshot";
          blur_passes = 4;
          blur_size = 6;
          brightness = 0.65;
          contrast = 0.95;
          vibrancy = 0.15;
          color = "rgb(${p.bgHex})";
        }
      ];
      label = [
        {
          monitor = "";
          text = "cmd[update:15000] ${lockStatusCmd}";
          color = "rgb(${p.fgSecondaryHex})";
          font_size = 13;
          font_family = theme.font.mono;
          position = "28, -22";
          halign = "left";
          valign = "top";
          shadow_passes = 1;
          shadow_size = 2;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.35;
        }
        {
          monitor = "";
          text = "cmd[update:30000] ${lockBatteryCmd}";
          color = "rgb(${p.fgSecondaryHex})";
          font_size = 13;
          font_family = theme.font.mono;
          position = "-28, -22";
          halign = "right";
          valign = "top";
          shadow_passes = 1;
          shadow_size = 2;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.35;
        }
        {
          monitor = "";
          text = "$TIME";
          color = "rgb(${p.fgHex})";
          shadow_passes = 2;
          shadow_size = 4;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.45;
          font_size = 108;
          font_family = "Adwaita Sans";
          position = "0, -96";
          halign = "center";
          valign = "top";
        }
        {
          monitor = "";
          text = ''cmd[update:60000] ${pkgs.coreutils}/bin/date +"%Y年%-m月%-d日 (%a)"'';
          color = "rgb(${p.fgSecondaryHex})";
          shadow_passes = 1;
          shadow_size = 3;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.4;
          font_size = 20;
          font_family = "Adwaita Sans";
          position = "0, -248";
          halign = "center";
          valign = "top";
        }
        {
          monitor = "";
          text = "cmd[update:5000] ${lockMediaCmd}";
          color = "rgb(${p.fgSecondaryHex})";
          font_size = 13;
          font_family = "Adwaita Sans";
          position = "0, 56";
          halign = "center";
          valign = "bottom";
          shadow_passes = 1;
          shadow_size = 2;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.35;
        }
        {
          monitor = "";
          text = "Super+Esc で画面消灯";
          color = "rgb(${p.fgMutedHex})";
          font_size = 11;
          font_family = theme.font.mono;
          position = "0, 18";
          halign = "center";
          valign = "bottom";
        }
      ]
      ++ lib.optionals (!isChromebook) [
        {
          monitor = "";
          text = "$FPRINTPROMPT";
          color = "rgb(${p.accentHex})";
          font_size = 14;
          font_family = "Adwaita Sans";
          position = "0, -104";
          halign = "center";
          valign = "center";
          shadow_passes = 1;
          shadow_size = 2;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.35;
        }
      ];
      input-field = [
        {
          monitor = "";
          size = "320, 48";
          outline_thickness = 2;
          rounding = -1;
          dots_size = 0.24;
          dots_spacing = 0.36;
          dots_center = true;
          outer_color = "rgba(${p.accentHex}99) rgba(${p.accentAltHex}99) 45deg";
          inner_color = "rgba(${p.surfaceHex}cc)";
          font_color = "rgb(${p.fgHex})";
          fade_on_empty = false;
          placeholder_text = ''<span foreground="##${p.fgMutedHex}">パスワードを入力…</span>'';
          hide_input = false;
          check_color = "rgba(${p.accentHex}ee) rgba(${p.accentAltHex}ee) 120deg";
          fail_color = "rgb(${p.dangerHex})";
          fail_text = "<i>認証失敗 ($ATTEMPTS)</i>";
          capslock_color = "rgb(${p.warningHex})";
          bothlock_color = "rgb(${p.warningHex})";
          position = "0, -40";
          halign = "center";
          valign = "center";
          shadow_passes = 2;
          shadow_size = 6;
          shadow_color = "rgb(${p.bgHex})";
          shadow_boost = 0.35;
        }
      ];
    };
  };

  # Hypridle: 45s DPMS off while locked, 5m dim -> 10m lock (5s grace) -> 15m DPMS off.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${lockOnceCmd}";
        before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
        after_sleep_cmd = "${idleDpmsOnCmd}";
        inhibit_sleep = 3;
        ignore_dbus_inhibit = false;
      };
      listener = [
        {
          timeout = 45;
          on-timeout = "${idleLockDpmsOffCmd}";
          on-resume = "${idleDpmsOnCmd}";
        }
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
}
