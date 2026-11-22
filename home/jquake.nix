# JQuake: login autostart, offscreen XEmbed tray host, alert maximize over hyprlock.
#
# - Patches a few Settings.properties keys on each start without rewriting the whole file.
# - Hyprland/XWayland: AWT SystemTray needs an XEmbed tray host. Offscreen stalonetray
#   hosts JQuake's icon and `jquake-open` / `jquake-menu` open it via stalonetray
#   remote click.
# - On alert we wake DPMS, dismiss hyprlock, and maximize/pin the map window while
#   keeping the top bar visible using Hyprland 0.57+ Lua dispatchers.
{
  pkgs,
  lib,
  config,
  ...
}:

let
  theme = import ../lib/theme.nix;
  p = theme.palette;

  confDir = "${config.home.homeDirectory}/Library/Application Support/JQuake";
  propsFile = "${confDir}/Settings.properties";

  jquakeClass = "net-jquake-app-Main";
  hyprctl = "${pkgs.hyprland}/bin/hyprctl";
  jq = "${pkgs.jq}/bin/jq";

  stalonetrayBin = "${pkgs.stalonetray}/bin/stalonetray";

  # Clear X11 ShapeInput so the invisible offscreen stalonetray window can never
  # intercept pointer clicks under XWayland.
  clearStalonetrayInput =
    pkgs.writers.writePython3 "stalonetray-clear-input"
      {
        libraries = [ pkgs.python3Packages.xlib ];
        doCheck = false;
      }
      ''
        import os
        from Xlib import X, display
        from Xlib.ext import shape

        dpy = display.Display(os.environ.get("DISPLAY") or ":0")
        root = dpy.screen().root

        def walk(win):
            yield win
            try:
                for child in win.query_tree().children:
                    yield from walk(child)
            except Exception:
                return

        for win in walk(root):
            try:
                cls = win.get_wm_class() or ()
            except Exception:
                cls = ()
            if "stalonetray" in cls:
                win.shape_rectangles(shape.SO.Set, shape.SK.Input, X.Unsorted, 0, 0, [])
        dpy.sync()
      '';

  hideStalonetray = pkgs.writeShellScript "stalonetray-jquake-hide" ''
    set -euo pipefail
    for _ in $(seq 1 40); do
      if ${hyprctl} clients -j 2>/dev/null | ${jq} -e '[.[] | select(.class == "stalonetray")] | length > 0' >/dev/null; then
        ${clearStalonetrayInput} >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 0.25
    done
    exit 0
  '';

  jquakeAutostart = pkgs.writeShellApplication {
    name = "jquake-autostart";
    runtimeInputs = [
      pkgs.jquake
      pkgs.gnused
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      mkdir -p ${lib.escapeShellArg confDir}
      props=${lib.escapeShellArg propsFile}

      set_prop() {
        local key="$1" val="$2"
        if [[ -f "$props" ]] && grep -q "^''${key}=" "$props"; then
          sed -i "s|^''${key}=.*|''${key}=''${val}|" "$props"
        else
          printf '%s=%s\n' "$key" "$val" >>"$props"
        fi
      }

      # Defaults for user preferences (only set when missing so GUI tweaks stick).
      set_default_prop() {
        local key="$1" val="$2"
        if [[ ! -f "$props" ]] || ! grep -q "^''${key}=" "$props"; then
          printf '%s=%s\n' "$key" "$val" >>"$props"
        fi
      }

      # Location / initial map view (Tokyo) & UI layout.
      set_default_prop firstOpen false
      set_default_prop userLatitude 35.68952
      set_default_prop userLongitude 139.74409
      set_default_prop userVisible true
      set_default_prop includeUserInZoom false
      set_default_prop homeViewNW "45.62207;126.89925"
      set_default_prop homeViewSE "29.92448;146.10139"
      set_default_prop fixedMode false
      set_default_prop resetViewAfterEvent true
      set_default_prop displayPrefList true
      set_default_prop displayCityNames true
      set_default_prop displayEQScrollBar true
      set_default_prop displayMiniMap true
      set_default_prop roundRectangles true
      set_default_prop intensityIcon true
      set_default_prop useSmallIcons false
      set_default_prop useShindoColor true
      set_default_prop showClosestSation true
      set_default_prop langChoice 0
      set_default_prop serverChoice 0
      set_default_prop displayChoice 2
      set_default_prop displayChoiceSub 3
      set_default_prop interfaceDisplayChoice 0
      set_default_prop interfaceDisplayChoiceSub 0
      set_default_prop interfaceScale 1.00000
      set_default_prop mapScale 1.00000
      set_default_prop useSystemProxy true

      # Dark theme colors.
      set_default_prop bg "51;52;57"
      set_default_prop mapBg "31;32;37"
      set_default_prop polyColor "63;64;69"
      set_default_prop fontColor "255;255;255"

      # Audio.
      set_default_prop mute false
      set_default_prop volume -15.00000
      set_default_prop soundPeripheral 0
      set_default_prop eqSpeakerChoice 0
      set_default_prop soundEEW1 true
      set_default_prop soundEEW2 true
      set_default_prop soundEQInfo true
      set_default_prop soundTsunami true
      set_default_prop teleseismicSound true
      set_default_prop soundShindo0 true
      set_default_prop soundShindo1 true
      set_default_prop soundShindo2 true
      set_default_prop soundPGA1 true
      set_default_prop soundPGA2 true

      # Alerts, tsunami, local thresholds & radii.
      set_default_prop advancedEEW false
      set_default_prop forceForecastOnDeep false
      set_default_prop EQInfoIntensity 5
      set_default_prop EEW1ShindoMin 0
      set_default_prop EEW1ShindoMinLoc 1
      set_default_prop EEW2ShindoMinLoc 0
      set_default_prop EEW2ShindoMinNat 0
      set_default_prop tsunamiChoice 0
      set_default_prop showTsunami true
      set_default_prop tsunamiBrowser true
      set_default_prop popEEW1 true
      set_default_prop popEEW2 true
      set_default_prop popShindo0 true
      set_default_prop popShindo1 true
      set_default_prop popShindo2 true
      set_default_prop popPGA1 true
      set_default_prop popPGA2 true
      set_default_prop localEEW1 true
      set_default_prop localEEW2 false
      set_default_prop localShindo0 true
      set_default_prop localShindo1 true
      set_default_prop localShindo2 false
      set_default_prop localPGA1 true
      set_default_prop localPGA2 false
      set_default_prop localShindo0Radius 45.00000
      set_default_prop localShindo1Radius 60.00000
      set_default_prop localShindo2Radius 115.00000
      set_default_prop localPGA1Radius 75.00000
      set_default_prop localPGA2Radius 120.00000
      set_default_prop level0ShindoIndex 4
      set_default_prop level1ShindoIndex 2
      set_default_prop level2ShindoIndex 2
      set_default_prop level1PGAIndex 2
      set_default_prop level2PGAIndex 5
      set_default_prop zoomEEW1 6
      set_default_prop zoomEEW2 6
      set_default_prop zoomShindo0 6
      set_default_prop zoomShindo1 6
      set_default_prop zoomShindo2 6
      set_default_prop zoomPGA1 6
      set_default_prop zoomPGA2 6

      # Tray/window: icon + minimize-on-close (stay resident in background).
      set_prop winChoice 2
      # Alerts: raise above other windows; wake DPMS; do not suppress pops.
      set_prop alwaysOnTop true
      set_prop wakeUpScreen true
      set_prop gameMode false
      set_prop persistentMode true
      # Start in tray; popEEW / popShindo / … open the window on events.
      set_prop openOnStartup false

      # Hyprland/XWayland: wait for stalonetray so AWT SystemTray.isSupported() is true.
      for _ in $(seq 1 40); do
        if pgrep -x stalonetray >/dev/null 2>&1; then
          break
        fi
        sleep 0.25
      done

      exec JQuake "$@"
    '';
  };

  jquakeHyprAlert = pkgs.writeShellApplication {
    name = "jquake-hypr-alert";
    runtimeInputs = [
      pkgs.socat
      pkgs.jq
      pkgs.procps
      pkgs.coreutils
      pkgs.hyprland
      pkgs.xdotool
    ];
    text = ''
      is_jquake_addr() {
        local raw="$1"
        local addr="0x''${raw#0x}"
        ${hyprctl} -j clients 2>/dev/null \
          | jq -e --arg addr "$addr" --arg cls ${lib.escapeShellArg jquakeClass} '
              any(.[]; (.address | ascii_downcase) == ($addr | ascii_downcase) and .class == $cls)
            ' >/dev/null 2>&1
      }

      raise_alert() {
        # Wake outputs (pairs with JQuake wakeUpScreen).
        ${hyprctl} dispatch 'hl.dsp.dpms("on")' >/dev/null 2>&1 || true
        # Session lock sits above all app surfaces; dismiss so the map is visible.
        if pgrep -x hyprlock >/dev/null 2>&1; then
          pkill -x hyprlock || true
        fi

        local info floating pinned
        info="$(
          ${hyprctl} -j clients 2>/dev/null \
            | jq -c --arg cls ${lib.escapeShellArg jquakeClass} '
                first(.[] | select(.class == $cls)) // empty
              '
        )"

        ${hyprctl} dispatch 'hl.dsp.focus({ window = "class:^${jquakeClass}$" })' >/dev/null 2>&1 || true

        if [ -n "$info" ]; then
          floating="$(printf '%s\n' "$info" | jq -r '.floating // false')"
          pinned="$(printf '%s\n' "$info" | jq -r '.pinned // false')"
          if [ "$floating" != "true" ]; then
            ${hyprctl} dispatch 'hl.dsp.window.float({ action = "toggle" })' >/dev/null 2>&1 || true
          fi
          if [ "$pinned" != "true" ]; then
            ${hyprctl} dispatch 'hl.dsp.window.pin()' >/dev/null 2>&1 || true
          fi
        fi

        ${hyprctl} dispatch 'hl.dsp.window.bring_to_top()' >/dev/null 2>&1 || true
        # The jquake-main window rule already maximizes the map (float + pin +
        # maximize), which keeps the top bar visible. Do NOT force fullscreen
        # here: internal fullscreen hides the bar and darkens the whole screen.

        # Forcing focus between the XWayland JQuake window and Wayland surfaces
        # (and dismissing hyprlock) can leave a modifier logically held. Release
        # them all so Ctrl/Alt don't stay "stuck" after the alert.
        xdotool keyup Control_L Control_R Alt_L Alt_R Shift_L Shift_R Super_L Super_R >/dev/null 2>&1 || true
      }

      sock="''${XDG_RUNTIME_DIR}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
      if [ ! -S "$sock" ]; then
        exit 0
      fi

      socat -u UNIX-CONNECT:"$sock" - | while IFS= read -r line; do
        case "$line" in
          openwindow\>\>*,*,"${jquakeClass}",*)
            raise_alert
            ;;
          urgent\>\>*)
            addr="''${line#urgent>>}"
            if is_jquake_addr "$addr"; then
              raise_alert
            fi
            ;;
        esac
      done
    '';
  };
in
{
  home.packages = [
    jquakeAutostart
    jquakeHyprAlert
  ];

  # Graphical session autostart.
  systemd.user.services.jquake = {
    Unit = {
      Description = "JQuake earthquake monitor (background)";
      After = [
        "graphical-session.target"
        "stalonetray-jquake.service"
      ];
      Wants = [ "stalonetray-jquake.service" ];
      BindsTo = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "simple";
      ExecStart = "${jquakeAutostart}/bin/jquake-autostart";
      Restart = "on-failure";
      RestartSec = 5;
      Environment = [
        "_JAVA_AWT_WM_NONREPARENTING=1"
      ];
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # Offscreen XEmbed tray host for JQuake.
  systemd.user.services.stalonetray-jquake = {
    Unit = {
      Description = "Offscreen XEmbed tray for JQuake (Hyprland/XWayland)";
      After = [ "graphical-session.target" ];
      BindsTo = [ "graphical-session.target" ];
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=Hyprland";
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "simple";
      ExecStart = "${stalonetrayBin} --background '${p.bg}' --geometry 1x1+-2000+-2000 --max-geometry 1x1 --slot-size 16 --icon-size 16 --scrollbars none --sticky --window-type utility --window-strut none --kludges force_icons_size,fix_window_pos";
      ExecStartPost = "${hideStalonetray}";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # Hyprland: maximize (keeping top bar visible) + unlock on alert window events.
  systemd.user.services.jquake-hypr-alert = {
    Unit = {
      Description = "Raise JQuake maximized over hyprlock on alert";
      After = [
        "graphical-session.target"
        "jquake.service"
      ];
      BindsTo = [ "graphical-session.target" ];
      ConditionEnvironment = "XDG_CURRENT_DESKTOP=Hyprland";
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "simple";
      ExecStart = "${jquakeHyprAlert}/bin/jquake-hypr-alert";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
    -- JQuake main window (XWayland): sticky floating maximized (keep top bar visible).
    hl.window_rule({
      name = "jquake-main",
      match = { class = "^(${jquakeClass})$" },
      float = true,
      pin = true,
      border_size = 2,
      maximize = true,
    })
    -- JQuake / XEmbed tray host window rules (XWayland)
    hl.window_rule({
      name = "jquake-stalonetray",
      match = { class = "^(stalonetray)$" },
      float = true,
      border_size = 0,
      pin = true,
      no_focus = true,
      opacity = "0.0 override",
      move = "-2000 -2000",
    })
    hl.window_rule({
      name = "jquake-java-embedded-frame",
      match = { title = "^(JavaEmbeddedFrame)$" },
      float = true,
      border_size = 0,
      pin = true,
      no_focus = true,
      opacity = "0.0 override",
      move = "-2000 -2000",
    })
  '';
}
