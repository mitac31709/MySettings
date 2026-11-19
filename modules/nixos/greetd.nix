# greetd + ReGreet on minimal Hyprland (Lua 0.57+ config) with receive-only Lan Mouse
# for remote login across vaio / chromebook.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  lanMouse = import ../../lib/lan-mouse.nix;
  theme = import ../../lib/theme.nix;
  p = theme.palette;
  wallpaperPng = theme.mkWallpaper pkgs;

  greeterLanMouseConfig = (pkgs.formats.toml { }).generate "greeter-lan-mouse.toml" {
    port = lanMouse.port;
    release_bind = lanMouse.releaseBind;
    authorized_fingerprints = lanMouse.authorizedFingerprints;
  };

  greeterCertPath =
    config.age.secrets."lan-mouse-greeter-pem".path or "/run/agenix/lan-mouse-greeter-pem";

  greeterRunner = pkgs.writeShellScript "regreet-with-lan-mouse" ''
    set -u

    # Ensure ReGreet sees NixOS desktop sessions (Hyprland UWSM) and GTK themes/icons.
    export XDG_DATA_DIRS="${config.services.displayManager.sessionData.desktops}/share:/run/current-system/sw/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

    cert_path=${lib.escapeShellArg greeterCertPath}
    if [ ! -r "$cert_path" ]; then
      cert_path="/var/lib/regreet/lan-mouse.pem"
    fi

    ${lib.getExe pkgs.lan-mouse} \
      --config ${greeterLanMouseConfig} \
      --cert-path "$cert_path" \
      daemon &
    lm_pid=$!

    cleanup() {
      # Wait for the greeter daemon to exit so UDP port 4242 is free before the user session starts.
      if kill -0 "$lm_pid" 2>/dev/null; then
        kill "$lm_pid" 2>/dev/null || true
        wait "$lm_pid" 2>/dev/null || true
      fi
      ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
    }
    trap cleanup EXIT INT TERM

    ${lib.getExe config.services.displayManager.regreet.package}
  '';

  greeterHyprlandConfig = pkgs.writeText "greeter-hyprland.lua" ''
    hl.monitor({
      output = "",
      mode = "preferred",
      position = "auto",
      scale = "auto",
    })

    hl.on("hyprland.start", function()
      hl.exec_cmd(${builtins.toJSON "${greeterRunner}"})
    end)

    hl.config({
      misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        background_color = "rgb(${p.bgHex})",
      },
      input = {
        kb_layout = "jp",
        numlock_by_default = true,
        follow_mouse = 1,
        touchpad = {
          natural_scroll = false,
          tap_to_click = true,
          clickfinger_behavior = true,
          disable_while_typing = false,
        },
      },
      general = {
        border_size = 0,
        gaps_in = 0,
        gaps_out = 0,
      },
      decoration = {
        rounding = 0,
        shadow = {
          enabled = false,
        },
        blur = {
          enabled = false,
        },
      },
      animations = {
        enabled = false,
      },
    })
  '';
in
{
  services.displayManager.regreet = {
    enable = true;
    font = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = theme.font.mono;
      size = 12;
    };
    settings = {
      GTK = {
        application_prefer_dark_theme = true;
      };
      background = {
        path = "${wallpaperPng}";
        fit = "Cover";
      };
      appearance = {
        greeting_msg = "Welcome · ${config.networking.hostName}";
      };
      commands = {
        reboot = [
          "${pkgs.systemd}/bin/systemctl"
          "reboot"
        ];
        poweroff = [
          "${pkgs.systemd}/bin/systemctl"
          "poweroff"
        ];
      };
      widget.clock = {
        format = "%Y-%m-%d (%a)  %H:%M:%S";
        resolution = "1s";
        timezone = "Asia/Tokyo";
      };
    };
    extraCss = ''
      window {
        background-color: ${p.bg};
        color: ${p.fg};
        font-family: "${theme.font.mono}", sans-serif;
      }

      box, grid {
        color: ${p.fg};
      }

      frame, .background > box {
        border-radius: ${toString theme.radius.popup}px;
      }

      entry {
        background-color: rgba(${p.surfaceRgb}, 0.90);
        color: ${p.fg};
        border: 1px solid ${p.border};
        border-radius: ${toString theme.radius.control}px;
        padding: 8px 12px;
        caret-color: ${p.accent};
      }

      entry:focus {
        border-color: ${p.accent};
        box-shadow: 0 0 0 1px rgba(${p.accentRgb}, 0.35);
      }

      button {
        background-color: rgba(${p.surfaceAltRgb}, 0.92);
        color: ${p.fg};
        border: 1px solid ${p.border};
        border-radius: ${toString theme.radius.control}px;
        padding: 7px 14px;
        transition: background-color 140ms ease, border-color 140ms ease;
      }

      button:hover {
        background-color: ${p.surfaceHover};
        border-color: ${p.accent};
      }

      button.suggested-action {
        background-color: ${p.accentSoft};
        color: ${p.accent};
        border-color: ${p.accent};
      }

      button.destructive-action {
        background-color: ${p.dangerSoft};
        color: ${p.danger};
        border-color: ${p.danger};
      }

      combobox button {
        background-color: rgba(${p.surfaceRgb}, 0.90);
        border: 1px solid ${p.border};
        border-radius: ${toString theme.radius.control}px;
      }

      label {
        color: ${p.fg};
      }
    '';
  };

  # Keep the greeter's Hyprland isolated from user@<greeter>.service so it does not
  # start hyprland-session.target / graphical-session.target (hypridle, warp-taskbar,
  # portals, pipewire) under the read-only /var/empty greeter user.
  services.greetd.settings.default_session.command =
    "${pkgs.coreutils}/bin/env HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_TARGET=1 ${pkgs.dbus}/bin/dbus-run-session ${pkgs.hyprland}/bin/Hyprland --config ${greeterHyprlandConfig}";

  # UniClipboard (and other libsecret apps) need an unlocked Secret Service.
  # KWallet's ksecretd rejects UniClipboard's binary probe; use gnome-keyring.
  services.gnome.gnome-keyring.enable = true;
  # Disable gcr-ssh-agent so OpenSSH ssh-agent + Rofi SSH_ASKPASS prompts for keys
  # instead of gcr4-ssh-askpass (GTK4).
  services.gnome.gcr-ssh-agent.enable = false;
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # NumLock on before greetd (and as the default for new VTs).
  # Compositors that reset LED state still need their own session option.
  systemd.services.numLockOnTty = {
    description = "Enable NumLock on TTYs";
    wantedBy = [ "multi-user.target" ];
    before = [ "greetd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "numLockOnTty" ''
        for tty in /dev/tty{1..6}; do
          ${pkgs.kbd}/bin/setleds -D +num < "$tty" || true
        done
      '';
    };
  };
}
