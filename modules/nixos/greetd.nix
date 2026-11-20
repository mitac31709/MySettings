# greetd + Dux Greeter (Quickshell) on minimal Hyprland (Lua 0.57+ config),
# with receive-only Lan Mouse for remote login across vaio / chromebook.
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
  cursorSizeStr = toString theme.cursor.size;

  duxGreeterPkg = config.services.displayManager.dux-greeter.package;
  duxCacheDir = "/var/lib/dms-greeter";

  greeterLanMouseConfig = (pkgs.formats.toml { }).generate "greeter-lan-mouse.toml" {
    port = lanMouse.port;
    release_bind = lanMouse.releaseBind;
    authorized_fingerprints = lanMouse.authorizedFingerprints;
  };

  greeterCertPath =
    config.age.secrets."lan-mouse-greeter-pem".path or "/run/agenix/lan-mouse-greeter-pem";

  # Started from the greeter Hyprland config. Poll the parent (Hyprland) so the
  # daemon is gone before the user session binds UDP 4242.
  greeterLanMouse = pkgs.writeShellScript "greeter-lan-mouse" ''
    set -u

    cert_path=${lib.escapeShellArg greeterCertPath}
    if [ ! -r "$cert_path" ]; then
      cert_path="${duxCacheDir}/lan-mouse.pem"
    fi

    # Receive-only in greeter: skip portal capture so lan-mouse never spawns xdg-desktop-portal.
    ${lib.getExe pkgs.lan-mouse} \
      --capture-backend dummy \
      --emulation-backend wlroots \
      --config ${greeterLanMouseConfig} \
      --cert-path "$cert_path" \
      daemon &
    lm_pid=$!

    cleanup() {
      if kill -0 "$lm_pid" 2>/dev/null; then
        kill "$lm_pid" 2>/dev/null || true
        wait "$lm_pid" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT INT TERM

    while kill -0 "$PPID" 2>/dev/null; do
      sleep 0.2
    done
  '';

  greeterHyprlandConfig = pkgs.writeText "greeter-hyprland.lua" ''
    hl.env("XCURSOR_THEME", ${builtins.toJSON theme.cursor.name})
    hl.env("XCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
    hl.env("HYPRCURSOR_SIZE", ${builtins.toJSON cursorSizeStr})
    ${lib.optionalString theme.cursor.hyprcursor ''hl.env("HYPRCURSOR_THEME", ${builtins.toJSON theme.cursor.name})''}

    -- dms-greeter also sets this, but keep it explicit in the compositor config.
    hl.env("DMS_RUN_GREETER", "1")

    hl.monitor({
      output = "",
      mode = "preferred",
      position = "auto",
      scale = 1,
    })

    hl.on("hyprland.start", function()
      hl.exec_cmd(${builtins.toJSON "${greeterLanMouse}"})
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

  # dms-greeter prefers start-hyprland when it is in PATH; that watchdog starts
  # hyprland-session.target under the greeter user. Expose only the bare
  # compositor + hyprctl instead.
  greeterHyprlandBin = pkgs.runCommand "hyprland-greeter-bin" { } ''
    mkdir -p "$out/bin"
    ln -s ${lib.getExe' pkgs.hyprland "Hyprland"} "$out/bin/Hyprland"
    ln -s ${lib.getExe' pkgs.hyprland "hyprctl"} "$out/bin/hyprctl"
  '';

  # Dux custom theme: the "Nocturne Slate" palette shared with the desktop.
  greeterTheme = pkgs.writeText "dms-colors.json" (
    builtins.toJSON {
      name = "Nocturne Slate";
      primary = p.accent;
      primaryText = p.bg;
      primaryContainer = p.accentSoft;
      secondary = p.accentAlt;
      surfaceTint = p.accent;
      surface = p.surface;
      surfaceText = p.fg;
      surfaceVariant = p.surfaceAlt;
      surfaceVariantText = p.fgSecondary;
      surfaceContainerLowest = p.bg;
      surfaceContainerLow = p.surface;
      surfaceContainer = p.surface;
      surfaceContainerHigh = p.surfaceAlt;
      surfaceContainerHighest = p.surfaceHover;
      background = p.bg;
      backgroundText = p.fg;
      outline = p.border;
      error = p.danger;
      warning = p.warning;
      info = p.accentAlt;
      matugen_type = "scheme-tonal-spot";
    }
  );

  greeterSettings = pkgs.writeText "settings.json" (
    builtins.toJSON {
      currentThemeName = "custom";
      customThemeFile = "${greeterTheme}";
      fontFamily = "Inter";
      monoFontFamily = "Fira Code";
      fontScale = 1.0;
      radiusStrength = 50;
      animationDuration = 180;
      clockFormat = "auto";
      showSeconds = false;
      lockDateFormat = "yyyy-MM-dd (ddd)";
      # The greeter has no usable network; avoid weather lookups at login.
      weatherEnabled = false;
      lockScreenShowWeather = false;
      lockScreenShowPowerActions = true;
      greeterRememberLastSession = false;
      greeterRememberLastUser = false;
      greeterEnableFprint = false;
      greeterEnableU2f = false;
    }
  );

  greeterSession = pkgs.writeText "session.json" (
    builtins.toJSON {
      wallpaperPath = "${wallpaperPng}";
      wallpaperFillMode = "PreserveAspectCrop";
    }
  );

  greeterCommand = pkgs.writeShellScript "dux-greeter-session" ''
    set -eu

    export PATH=${
      lib.makeBinPath [
        greeterHyprlandBin
        pkgs.quickshell
        pkgs.glib
        pkgs.bash
        pkgs.coreutils
      ]
    }
    export XDG_DATA_DIRS="${config.services.displayManager.sessionData.desktops}/share:/run/current-system/sw/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

    # Keep the greeter's compositor isolated from user@<greeter>.service so it
    # does not start graphical-session.target, portals or AT-SPI.
    exec ${lib.getExe' pkgs.coreutils "env"} -u DBUS_SESSION_BUS_ADDRESS \
      HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_TARGET=1 \
      GDK_DEBUG=no-portals GTK_A11Y=none NO_AT_BRIDGE=1 \
      ${lib.getExe' duxGreeterPkg "dms-greeter"} \
      --cache-dir ${duxCacheDir} \
      --command hyprland \
      -C ${greeterHyprlandConfig}
  '';
in
{
  services.displayManager.regreet.enable = false;

  services.displayManager.dux-greeter = {
    enable = true;
    compositor.name = "hyprland";
    configFiles = [
      greeterSettings
      greeterSession
      greeterTheme
    ];
  };

  # The module creates the dms-greeter user, cache dir and config seeding; only
  # replace its command to add the greeter-only environment isolation.
  services.greetd.settings.default_session.command = lib.mkForce "${greeterCommand}";

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
      ExecStart = "${pkgs.kbd}/bin/setleds +num < /dev/console";
    };
  };
}
