# greetd + tuigreet (inside fullscreen foot on minimal Hyprland) with receive-only
# Lan Mouse for remote login across vaio / chromebook.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  lanMouse = import ../../lib/lan-mouse.nix;
  theme = import ../../lib/theme.nix;
  # Local-only cursor themes (theme.cursor.package = null) live under the
  # user's home, which the greeter user cannot read; fall back to Adwaita.
  greeterCursorName = if theme.cursor.package == null then "Adwaita" else theme.cursor.name;
  cursorSizeStr = toString theme.cursor.size;

  greeterLanMouseConfig = (pkgs.formats.toml { }).generate "greeter-lan-mouse.toml" {
    port = lanMouse.port;
    release_bind = lanMouse.releaseBind;
    authorized_fingerprints = lanMouse.authorizedFingerprints;
  };

  greeterCertPath =
    config.age.secrets."lan-mouse-greeter-pem".path or "/run/agenix/lan-mouse-greeter-pem";

  # Fullscreen Wayland-native terminal hosting tuigreet in classic TTY-style black/white.
  greeterFootConfig = pkgs.writeText "greeter-foot.ini" ''
    [main]
    font=${theme.font.mono}:size=13
    pad=0x0 center
    bold-text-in-bright=yes

    [bell]
    urgent=no
    notify=no

    [scrollback]
    lines=0

    [colors]
    background=000000
    foreground=ffffff
  '';

  # Power-save on the login screen: turn off display after 3 minutes of inactivity.
  greeterHypridleConfig = pkgs.writeText "greeter-hypridle.conf" ''
    listener {
      timeout = 180
      on-timeout = ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = "off" })'
      on-resume = ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
    }
  '';

  greeterRunner = pkgs.writeShellScript "tuigreet-with-lan-mouse" ''
    set -u

    cert_path=${lib.escapeShellArg greeterCertPath}
    if [ ! -r "$cert_path" ]; then
      cert_path="/var/lib/tuigreet/lan-mouse.pem"
    fi

    # Receive-only in greeter: skip portal capture so lan-mouse never spawns xdg-desktop-portal.
    ${lib.getExe pkgs.lan-mouse} \
      --capture-backend dummy \
      --emulation-backend wlroots \
      --config ${greeterLanMouseConfig} \
      --cert-path "$cert_path" \
      daemon &
    lm_pid=$!

    ${lib.getExe pkgs.hypridle} --config ${greeterHypridleConfig} >/dev/null 2>&1 &
    idle_pid=$!

    cleanup() {
      # Stop hypridle and wait for lan-mouse to exit so UDP port 4242 is free before the user session starts.
      if kill -0 "$idle_pid" 2>/dev/null; then
        kill "$idle_pid" 2>/dev/null || true
        wait "$idle_pid" 2>/dev/null || true
      fi
      if kill -0 "$lm_pid" 2>/dev/null; then
        kill "$lm_pid" 2>/dev/null || true
        wait "$lm_pid" 2>/dev/null || true
      fi
      ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 || true
    }
    trap cleanup EXIT INT TERM

    ${lib.getExe pkgs.foot} \
      --fullscreen \
      --config=${greeterFootConfig} \
      ${lib.getExe pkgs.tuigreet} \
      --time \
      --time-format '%Y-%m-%d %H:%M:%S' \
      --asterisks \
      --remember \
      --remember-session \
      --user-menu \
      --sessions "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions" \
      --cmd "${pkgs.uwsm}/bin/uwsm start -e -D Hyprland hyprland.desktop"
  '';

  greeterHyprlandConfig = pkgs.writeText "greeter-hyprland.lua" ''
    hl.env("XCURSOR_THEME", ${builtins.toJSON greeterCursorName})
    hl.env("XCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
    hl.env("HYPRCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
    ${lib.optionalString (
      theme.cursor.package != null && theme.cursor.hyprcursor
    ) ''hl.env("HYPRCURSOR_THEME", ${builtins.toJSON theme.cursor.name})''}

    hl.monitor({
      output = "",
      mode = "preferred",
      position = "auto",
      scale = 1,
    })

    hl.on("hyprland.start", function()
      hl.exec_cmd(${builtins.toJSON "${greeterRunner}"})
    end)

    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe pkgs.brightnessctl} set +5%"}), { repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(${builtins.toJSON "${lib.getExe pkgs.brightnessctl} set 5%-"}), { repeating = true })

    hl.config({
      misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        background_color = "rgb(000000)",
        mouse_move_enables_dpms = true,
        key_press_enables_dpms = true,
      },
      input = {
        kb_layout = "jp",
        kb_options = "caps:none",
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
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # Keep the greeter's Hyprland isolated from user@<greeter>.service so it does not
  # start hyprland-session.target / graphical-session.target or D-Bus portals / AT-SPI
  # under the read-only /var/empty greeter user.
  services.greetd = {
    enable = true;
    settings.default_session = {
      user = "greeter";
      command = "${pkgs.coreutils}/bin/env -u DBUS_SESSION_BUS_ADDRESS HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_TARGET=1 GDK_DEBUG=no-portals GTK_A11Y=none NO_AT_BRIDGE=1 ${pkgs.hyprland}/bin/Hyprland --config ${greeterHyprlandConfig}";
    };
  };

  # Persistent cache for tuigreet (--remember / --remember-user-session) and
  # fallback cert directory for lan-mouse.
  systemd.tmpfiles.rules = [
    "d /var/cache/tuigreet 0750 greeter greeter -"
    "d /var/lib/tuigreet 0750 greeter greeter -"
  ];

  # UniClipboard (and other libsecret apps) need an unlocked Secret Service.
  # KWallet's ksecretd rejects UniClipboard's binary probe; use gnome-keyring.
  services.gnome.gnome-keyring.enable = true;
  # Disable gcr-ssh-agent so OpenSSH ssh-agent + Rofi SSH_ASKPASS prompts for keys
  # instead of gcr4-ssh-askpass (GTK4).
  services.gnome.gcr-ssh-agent.enable = false;
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;
  security.pam.services.greetd.fprintAuth = false;
  security.pam.services.login.fprintAuth = false;

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
