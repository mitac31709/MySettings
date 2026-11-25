# Niri user configuration (KDL + Niri-scoped Waybar & Mako in the Nocturne Slate palette).
# Launched only from Niri's spawn-at-startup so Hyprland + Colorshell remain untouched.
{
  config,
  lib,
  pkgs,
  flakeTarget ? "chromebook",
  ...
}:

let
  theme = import ../lib/theme.nix;
  p = theme.palette;
  isChromebook = flakeTarget == "chromebook";

  waybarConfig = pkgs.writeText "niri-waybar-config.jsonc" (
    builtins.toJSON {
      layer = "top";
      position = "top";
      height = 32;
      spacing = 6;
      margin-top = 6;
      margin-left = 10;
      margin-right = 10;

      modules-left = [
        "niri/workspaces"
        "niri/window"
      ];
      modules-center = [ "clock" ];
      modules-right = [
        "pulseaudio"
        "network"
        "battery"
        "tray"
      ];

      "niri/workspaces" = {
        format = "{index}";
      };
      "niri/window" = {
        max-length = 48;
      };
      clock = {
        format = "{:%Y-%m-%d (%a)  %H:%M}";
        tooltip-format = "<tt>{calendar}</tt>";
      };
      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "󰖁 muted";
        format-icons = {
          default = [
            "󰕿"
            "󰖀"
            "󰕾"
          ];
        };
      };
      network = {
        format-wifi = "󰖩 {essid}";
        format-ethernet = "󰈀 {ipaddr}";
        format-disconnected = "󰖪 offline";
      };
      battery = {
        states = {
          warning = 30;
          critical = 15;
        };
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-icons = [
          "󰁺"
          "󰁼"
          "󰁾"
          "󰂀"
          "󰁹"
        ];
      };
      tray = {
        spacing = 8;
      };
    }
  );

  waybarStyle = pkgs.writeText "niri-waybar-style.css" ''
    * {
      font-family: "${theme.font.mono}", "Adwaita Sans", sans-serif;
      font-size: 12px;
      border: none;
      border-radius: 0;
      min-height: 0;
    }

    window#waybar {
      background: rgba(${p.surfaceRgb}, 0.88);
      color: ${p.fg};
      border: 1px solid ${p.border};
      border-radius: ${toString theme.radius.bar}px;
    }

    #workspaces button {
      padding: 0 8px;
      margin: 3px 2px;
      color: ${p.fgMuted};
      background: transparent;
      border-radius: ${toString theme.radius.pill}px;
    }

    #workspaces button.active {
      color: ${p.bg};
      background: ${p.accent};
      font-weight: bold;
    }

    #window {
      padding: 0 10px;
      color: ${p.fgSecondary};
    }

    #clock,
    #pulseaudio,
    #network,
    #battery,
    #tray {
      padding: 0 10px;
      color: ${p.fg};
    }

    #battery.warning {
      color: ${p.warning};
    }

    #battery.critical {
      color: ${p.danger};
    }
  '';

  makoConfig = pkgs.writeText "niri-mako.conf" ''
    font=${theme.font.mono} 11
    background-color=${p.surface}ee
    text-color=${p.fg}
    border-color=${p.accent}
    border-size=1
    border-radius=${toString theme.radius.popup}
    padding=12
    margin=12
    default-timeout=5000
  '';
in
{
  xdg.configFile."niri/config.kdl".text = ''
    // Niri configuration — Nocturne Slate theme & keybinds aligned with Hyprland.

    input {
        keyboard {
            xkb {
                layout "jp"
                options "caps:none"
            }
            numlock
        }

        touchpad {
            tap
            ${lib.optionalString (!isChromebook) "scroll-factor 0.6"}
        }

        focus-follows-mouse max-scroll-amount="0%"
    }

    cursor {
        xcursor-theme "${theme.cursor.name}"
        xcursor-size ${toString theme.cursor.size}
    }

    prefer-no-csd

    screenshot-path "~/Pictures/Screenshots/screenshot-%Y%m%d-%H%M%S.png"

    layout {
        gaps 10
        center-focused-column "never"

        preset-column-widths {
            proportion 0.33333
            proportion 0.5
            proportion 0.66667
            proportion 1.0
        }

        default-column-width { proportion 0.5; }

        focus-ring {
            width 2
            active-gradient from="${p.accent}" to="${p.accentAlt}" angle=45
            inactive-color "${p.border}"
        }

        border {
            off
        }

        shadow {
            on
            softness 24
            spread 4
            offset x=0 y=4
            color "#05080d66"
        }

        background-color "${p.bg}"
    }

    window-rule {
        geometry-corner-radius ${toString theme.radius.window}
        clip-to-geometry true
    }

    // Niri-only session helpers (do not auto-start in Hyprland).
    spawn-at-startup "${lib.getExe pkgs.swaybg}" "-i" "${config.home.homeDirectory}/wallpapers/nocturne-slate.png" "-m" "fill"
    spawn-at-startup "${lib.getExe pkgs.waybar}" "-c" "${waybarConfig}" "-s" "${waybarStyle}"
    spawn-at-startup "${lib.getExe pkgs.mako}" "-c" "${makoConfig}"

    hotkey-overlay {
        skip-at-startup
    }

    binds {
        // Help & Overview
        Mod+Shift+Slash { show-hotkey-overlay; }
        Alt+Tab repeat=false { toggle-overview; }
        Mod+O repeat=false { toggle-overview; }

        // Apps & Launcher (aligned with Hyprland)
        Mod+Return { spawn "${lib.getExe pkgs.ghostty}"; }
        Ctrl+Alt+T { spawn "${lib.getExe pkgs.ghostty}"; }
        Mod+D { spawn "${lib.getExe pkgs.rofi}" "-show" "drun"; }
        Mod+Space { spawn "${lib.getExe pkgs.rofi}" "-show" "drun"; }
        Alt+Space { spawn "${lib.getExe pkgs.rofi}" "-show" "drun"; }
        Mod+E { spawn "${lib.getExe' pkgs.nemo-with-extensions "nemo"}"; }

        // Window & Session control
        Mod+Q { close-window; }
        Mod+L { spawn "${lib.getExe pkgs.hyprlock}"; }
        Mod+Shift+E { quit; }

        // Focus navigation (columns horizontally, windows/workspaces vertically)
        Mod+Left  { focus-column-left; }
        Mod+Right { focus-column-right; }
        Mod+Up    { focus-window-or-workspace-up; }
        Mod+Down  { focus-window-or-workspace-down; }
        Mod+H     { focus-column-left; }
        Mod+J     { focus-window-or-workspace-down; }
        Mod+K     { focus-window-or-workspace-up; }

        // Move windows / columns
        Mod+Shift+Left  { move-column-left; }
        Mod+Shift+Right { move-column-right; }
        Mod+Shift+Up    { move-window-up-or-to-workspace-up; }
        Mod+Shift+Down  { move-window-down-or-to-workspace-down; }

        // Column sizing & layout
        Mod+R { switch-preset-column-width; }
        Mod+F { maximize-column; }
        Mod+Shift+F { fullscreen-window; }
        Mod+C { center-column; }
        Mod+V { toggle-window-floating; }
        Mod+Minus { set-column-width "-10%"; }
        Mod+Equal { set-column-width "+10%"; }
        Mod+BracketLeft  { consume-or-expel-window-left; }
        Mod+BracketRight { consume-or-expel-window-right; }

        // Workspaces
        Mod+1 { focus-workspace 1; }
        Mod+2 { focus-workspace 2; }
        Mod+3 { focus-workspace 3; }
        Mod+4 { focus-workspace 4; }
        Mod+5 { focus-workspace 5; }
        Mod+6 { focus-workspace 6; }
        Mod+7 { focus-workspace 7; }
        Mod+8 { focus-workspace 8; }
        Mod+9 { focus-workspace 9; }
        Mod+Shift+1 { move-column-to-workspace 1; }
        Mod+Shift+2 { move-column-to-workspace 2; }
        Mod+Shift+3 { move-column-to-workspace 3; }
        Mod+Shift+4 { move-column-to-workspace 4; }
        Mod+Shift+5 { move-column-to-workspace 5; }
        Mod+Shift+6 { move-column-to-workspace 6; }
        Mod+Shift+7 { move-column-to-workspace 7; }
        Mod+Shift+8 { move-column-to-workspace 8; }
        Mod+Shift+9 { move-column-to-workspace 9; }

        // Mouse wheel scrolling
        Mod+WheelScrollDown cooldown-ms=150 { focus-workspace-down; }
        Mod+WheelScrollUp   cooldown-ms=150 { focus-workspace-up; }
        Mod+Shift+WheelScrollDown { focus-column-right; }
        Mod+Shift+WheelScrollUp   { focus-column-left; }

        // Screenshots (Niri built-in interactive UI)
        Print { screenshot; }
        Mod+Shift+S { screenshot; }
        Ctrl+Print { screenshot-screen; }
        Alt+Print { screenshot-window; }

        // Audio & Brightness (active even while locked)
        XF86AudioRaiseVolume allow-when-locked=true { spawn "${pkgs.pulseaudio}/bin/pactl" "set-sink-volume" "@DEFAULT_SINK@" "+5%"; }
        XF86AudioLowerVolume allow-when-locked=true { spawn "${pkgs.pulseaudio}/bin/pactl" "set-sink-volume" "@DEFAULT_SINK@" "-5%"; }
        XF86AudioMute        allow-when-locked=true { spawn "${pkgs.pulseaudio}/bin/pactl" "set-sink-mute" "@DEFAULT_SINK@" "toggle"; }
        XF86AudioMicMute     allow-when-locked=true { spawn "${pkgs.pulseaudio}/bin/pactl" "set-source-mute" "@DEFAULT_SOURCE@" "toggle"; }
        XF86MonBrightnessUp   allow-when-locked=true { spawn "${lib.getExe pkgs.brightnessctl}" "set" "+5%"; }
        XF86MonBrightnessDown allow-when-locked=true { spawn "${lib.getExe pkgs.brightnessctl}" "set" "5%-"; }
    }
  '';
}
