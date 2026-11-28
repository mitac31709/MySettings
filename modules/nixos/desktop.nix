# Graphical desktop & workstation stack: Hyprland (UWSM) + greetd/ReGreet +
# console-gui + portals + Fcitx5/Meltype + fonts + NetworkManager + desktop apps/services.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  machine = import ../../lib/machine.nix;
  theme = import ../../lib/theme.nix;
  p = theme.palette;
  hiraginoDir = machine.hiraginoDir;
  # Pure eval cannot read an absolute path outside the flake: pathExists is
  # false, so `nix flake check` and machines without the fonts still evaluate.
  # rebuild adds --impure when the directory exists. pathExists is then real,
  # and builtins.path copies the OTFs into the store.
  hiraginoEnabled = builtins.pathExists hiraginoDir;

  # Dark candidate panel matching Nocturne Slate theme and Meltype vertical UI.
  meltypeFcitx5Theme = pkgs.runCommand "meltype-fcitx5-theme" { } ''
        dir="$out/share/fcitx5/themes/meltype-dark"
        mkdir -p "$dir"
        for svg in arrow.svg next.svg prev.svg radio.svg; do
          cp -L "${pkgs.fcitx5}/share/fcitx5/themes/default-dark/$svg" "$dir/$svg"
        done
        cat > "$dir/theme.conf" << 'EOF'
    [Metadata]
    Name=Meltype Nocturne
    Version=2
    Author=MySettings
    Description=Nocturne Slate dark vertical candidate & meaning pane theme for Meltype
    ScaleWithDPI=True

    [InputPanel]
    NormalColor=${p.fg}
    HighlightCandidateColor=${p.fg}
    HighlightColor=${p.fg}
    HighlightBackgroundColor=${p.accentSoft}
    CandidateLabelColor=${p.fgMuted}
    HighlightCandidateLabelColor=${p.accent}
    LabelTextSizeFactor=85
    CandidateCommentColor=${p.accentAlt}
    HighlightCandidateCommentColor=${p.accent}
    CommentTextSizeFactor=80
    FullWidthHighlight=True
    PageButtonAlignment=Bottom

    [InputPanel/TextMargin]
    Left=10
    Right=10
    Top=6
    Bottom=6

    [InputPanel/ContentMargin]
    Left=6
    Right=6
    Top=6
    Bottom=6

    [InputPanel/Background]
    Color=${p.surface}
    BorderColor=${p.border}
    BorderWidth=1

    [InputPanel/Background/Margin]
    Left=2
    Right=2
    Top=2
    Bottom=2

    [InputPanel/Highlight]
    Color=${p.accentSoft}

    [InputPanel/Highlight/Margin]
    Left=6
    Right=6
    Top=4
    Bottom=4

    [InputPanel/PrevPage]
    Image=prev.svg

    [InputPanel/PrevPage/ClickMargin]
    Left=5
    Right=5
    Top=5
    Bottom=5

    [InputPanel/NextPage]
    Image=next.svg

    [InputPanel/NextPage/ClickMargin]
    Left=5
    Right=5
    Top=5
    Bottom=5

    [Menu]
    NormalColor=${p.fg}
    HighlightCandidateColor=${p.accent}
    Spacing=2

    [Menu/Background]
    Color=${p.surface}
    BorderColor=${p.border}
    BorderWidth=1

    [Menu/Background/Margin]
    Left=2
    Right=2
    Top=2
    Bottom=2

    [Menu/ContentMargin]
    Left=4
    Right=4
    Top=4
    Bottom=4

    [Menu/CheckBox]
    Image=radio.svg

    [Menu/SubMenu]
    Image=arrow.svg

    [Menu/Highlight]
    Color=${p.accentSoft}

    [Menu/Highlight/Margin]
    Left=6
    Right=6
    Top=5
    Bottom=5

    [Menu/Separator]
    Color=${p.border}

    [Menu/TextMargin]
    Left=6
    Right=6
    Top=5
    Bottom=5
    EOF
  '';
in
{
  imports = [
    ./hyprland.nix
    ./niri.nix
    ./greetd.nix
    ./console-gui.nix
  ];

  networking.networkmanager = {
    enable = true;
    wifi.backend = "iwd";
  };

  # Avoid leaving networking down if activation stops NM then fails mid-switch
  # (seen with switch-to-configuration exit 101).
  systemd.services.NetworkManager = {
    wantedBy = [ "multi-user.target" ];
    stopIfChanged = false;
  };

  # Fcitx5 + Meltype only — Hyprland Wayland
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.waylandFrontend = true;
    fcitx5.addons = with pkgs; [
      meltype
      meltypeFcitx5Theme
      fcitx5-gtk
      kdePackages.fcitx5-qt
      kdePackages.fcitx5-configtool
    ];
    fcitx5.settings.addons = {
      classicui.globalSection = {
        "Vertical Candidate List" = true;
        Font = "Sans 11";
        Theme = "meltype-dark";
        DarkTheme = "meltype-dark";
        UseDarkTheme = true;
      };
      # Keep zwp_virtual_keyboard_v1 alive across deactivate/activate instead of
      # destroying it on every focus switch (avoids transient NULL virtual keyboard state).
      waylandim.globalSection = {
        PersistentVirtualKeyboard = true;
      };
    };
    fcitx5.settings.inputMethod = {
      GroupOrder."0" = "Default";
      "Groups/0" = {
        Name = "Default";
        "Default Layout" = "jp";
        DefaultIM = "meltype";
      };
      # Meltype only (no mozc / keyboard-jp). Electron (ChatGPT) often cannot
      # reactivate IME after switching to keyboard-only, so keep keyboard out.
      "Groups/0/Items/0".Name = "meltype";
    };
    # Avoid Super+Shift / lone-Shift hotkeys that steal compositor chords
    # (Win+Shift+q, etc.) on the same seat as Hyprland.
    fcitx5.settings.globalOptions = {
      # Electron + text-input-v3: per-IC active/inactive desyncs; share globally
      # so ChatGPT can leave "English" and return to Meltype.
      Behavior.ShareInputState = "All";
      Behavior.ActiveByDefault = true;
      # Ctrl+Super+Space = Fcitx Trigger (active ⇔ inactive; Super+Space is
      # bound to Colorshell runner in Hyprland). With only Meltype in the group,
      # both sides stay Meltype. Do NOT bind Zenkaku_Hankaku here — that key
      # belongs to Meltype's internal 英数⇔日本語 toggle.
      "Hotkey/TriggerKeys"."0" = "Control+Super+space";
      "Hotkey/AltTriggerKeys" = { };
      "Hotkey/EnumerateForwardKeys" = { };
      "Hotkey/EnumerateBackwardKeys" = { };
      "Hotkey/EnumerateGroupForwardKeys"."0" = "Control+Shift+space";
      "Hotkey/EnumerateGroupBackwardKeys" = { };
    };
  };

  # Electron (Cursor, etc.): nixpkgs wrappers only pass --enable-wayland-ime
  # when this is set. Without it Cursor still picks Wayland but does not wire
  # text-input to fcitx5, so Meltype cannot compose. Restart Cursor fully
  # after changing this (single-instance ignores flags on --new-window).
  environment.sessionVariables.NIXOS_OZONE_WL = lib.mkDefault "1";

  fonts.packages =
    with pkgs;
    [
      nerd-fonts.jetbrains-mono
      noto-fonts-color-emoji
      # Typst / docs often request "Noto Sans CJK JP" by name.
      # Also the sans / mono fallback when Hiragino is not installed.
      noto-fonts-cjk-sans
      # Serif fallback (Hiragino Mincho ProN) when the local OTFs are absent.
      noto-fonts-cjk-serif
      # Cursor's bespoke geometric sans-serif typeface ("Cursor Gothic").
      cursor-gothic
      # Adwaita Sans / Mono (used by Colorshell & Colorshell's Hyprlock config).
      adwaita-fonts
    ]
    ++ lib.optionals hiraginoEnabled [
      (pkgs.callPackage ../../pkgs/hiragino {
        src = builtins.path {
          path = hiraginoDir;
          name = "hiragino-otf";
          filter = path: type: type == "directory" || lib.hasSuffix ".otf" (lib.toLower path);
        };
      })
    ];
  # First family wins when it is installed. Missing families are skipped,
  # so Noto CJK is the default whenever Hiragino is not in fonts.packages.
  fonts.fontconfig.defaultFonts = {
    sansSerif = [
      "Hiragino Kaku Gothic ProN"
      "Noto Sans CJK JP"
    ];
    serif = [
      "Hiragino Mincho ProN"
      "Noto Serif CJK JP"
    ];
    monospace = [
      "JetBrainsMono Nerd Font"
      "Hiragino Kaku Gothic ProN"
      "Noto Sans CJK JP"
    ];
    emoji = [ "Noto Color Emoji" ];
  };

  # Userspace KMS/DRM console for TTY2-TTY6 with Japanese font rendering
  # (TTY1 stays owned by greetd while services.displayManager.enable is true).
  services.kmscon = {
    enable = true;
    useXkbConfig = true;
    config = {
      font-engine = "pango";
      font-name = "${theme.font.mono}, Noto Sans Mono CJK JP";
      font-size = 16;
      hwaccel = true;
    };
  };

  users.users.mitac.extraGroups = [
    "networkmanager"
    "render"
    "video"
    "dialout" # /dev/ttyUSB* / ttyACM* (ESP32, Arduino, …)
    "input" # /dev/input/event* (WhatPulse keystroke/mouse counting on Wayland)
    "vboxusers" # VirtualBox host / USB passthrough
  ];

  # XKB default layout (used by XWayland / console / greeter) and CUPS printing.
  # No standalone Xorg server is needed for the pure Wayland Hyprland stack.
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };
  services.printing.enable = true;

  # Nemo (GTK GUI file manager), video thumbnails, D-Bus FileManager1
  # (browser / Electron "Show in folder"), GVfs (Trash, USB/SD mounts, SMB/SFTP),
  # and workstation CLI utilities.
  environment.systemPackages = with pkgs; [
    alsa-utils # amixer/alsactl — mute SOF amps if audio wedges
    libva-utils # vainfo — verify VA-API / Parsec hw encode
    podman-compose # Multi-container labs (YAML) on top of Podman
    distrobox # Seamless host-integrated Linux containers (e.g. Kali) on Podman
    (callPackage ../../pkgs/disktui { }) # TUI disk & partition manager (wrapped with parted/cryptsetup/mkfs/smartctl)
    nemo-with-extensions
    ffmpegthumbnailer
  ];
  services.dbus.packages = [ pkgs.nemo-with-extensions ];
  services.gvfs.enable = true;

  # Cloudflare WARP (1.1.1.1): daemon + CLI, plus official GUI (warp-taskbar tray).
  services.cloudflare-warp.enable = true;
  # Upstream unit provides BindReadOnlyPaths=…:/usr: so warp-taskbar finds
  # /usr/share/warp/images. It also ships warp-svc — disable that duplicate;
  # NixOS owns cloudflare-warp.service.
  systemd.packages = [ pkgs.cloudflare-warp ];
  systemd.services.warp-svc.enable = false;

  # Steam needs the NixOS module (32-bit libs, FHS, steam-hardware).
  # Also pulls in hardware.graphics.enable32Bit, which Bottles/Wine need.
  programs.steam.enable = true;

  # VirtualBox host (builds vboxdrv/vboxnet* kernel modules and suid wrappers;
  # do not also add pkgs.virtualbox to environment.systemPackages).
  virtualisation.virtualbox.host = {
    enable = true;
    enableExtensionPack = true;
  };

  # Rootless OCI containers (Podman) + Compose + Distrobox.
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    # Enable container DNS on user-defined networks (required for podman-compose).
    defaultNetwork.settings.dns_enabled = true;
  };

  # WhatPulse External PCap Service: captures network traffic for the WhatPulse
  # AppImage without needing root/setcap on the desktop client.
  systemd.services.whatpulse-pcap-service = {
    description = "WhatPulse External PCap Service";
    after = [ "network.target" ];
    wants = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.whatpulse-pcap-service}/bin/whatpulse-pcap-service";
      Restart = "always";
      RestartSec = 5;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      CapabilityBoundingSet = [
        "CAP_NET_RAW"
        "CAP_NET_ADMIN"
      ];
      AmbientCapabilities = [
        "CAP_NET_RAW"
        "CAP_NET_ADMIN"
      ];
    };
  };

  # LocalSend (LAN file transfer); opens TCP/UDP 53317 by default.
  programs.localsend.enable = true;

  # Trust Tailscale so Lan Mouse (UDP 4242) and UniClipboard iroh QUIC
  # (ephemeral UDP ports) traverse tailscale0 without per-port rules.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Lan Mouse (software KVM); default UDP 4242.
  # UniClipboard mDNS LAN peer discovery; UDP 5353.
  # iperf3 server defaults to TCP/UDP 5201.
  networking.firewall.allowedTCPPorts = [ 5201 ];
  networking.firewall.allowedUDPPorts = [
    4242
    5201
    5353
  ];

  # T3 Code desktop backend listens on 0.0.0.0:3773 (serverExposureMode =
  # "network-accessible" in ~/.local/share/t3/userdata/desktop-settings.json). Allow the
  # web GUI from the home LAN only, not from the internet at large.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 192.168.0.0/18 --dport 3773 -j nixos-fw-accept
  '';

  # Allow unprivileged mounting of removable drives (udisksctl) in active sessions.
  services.udisks2.enable = true;

  # Desktop portals: Hyprland native portal with GTK fallback for file dialogs & settings.
  # programs.hyprland already adds xdg-desktop-portal-hyprland and xdg-desktop-portal-gtk
  # to extraPortals; omit them here to avoid duplicate dbus-1 servicedir entries.
  xdg.portal = {
    enable = true;
    config = {
      common.default = [ "gtk" ];
      hyprland.default = [
        "hyprland"
        "gtk"
      ];
    };
  };

  # Accessibility bus (AT-SPI2 over D-Bus) for computer-use agents (agent-desktop)
  # and assistive tech; also stops NixOS from exporting NO_AT_BRIDGE=1 / GTK_A11Y=none.
  services.gnome.at-spi2-core.enable = true;

  # Audio user daemons default to ConditionUser=!root, so the greetd greeter
  # user (UID 994, HOME=/var/empty) starts them and fails creating state.
  systemd.user.sockets = lib.mkMerge [
    (lib.mkIf (config.services.pipewire.enable && !config.services.pipewire.systemWide) (
      {
        pipewire.unitConfig.ConditionUser = "!@system";
      }
      // lib.optionalAttrs config.services.pipewire.pulse.enable {
        pipewire-pulse.unitConfig.ConditionUser = "!@system";
      }
    ))
    (lib.mkIf (config.services.pulseaudio.enable && !config.services.pulseaudio.systemWide) {
      pulseaudio.unitConfig.ConditionUser = "!@system";
    })
  ];
  systemd.user.services = lib.mkMerge [
    {
      # Tray needs a StatusNotifier host (colorshell). Start in every graphical
      # session (manual launch without /usr bind dies).
      warp-taskbar = {
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session-pre.target" ];
        # Logout: tray dies then Restart (upstream unit) storms without a limit.
        unitConfig = {
          ConditionUser = "!@system";
          PartOf = [ "graphical-session.target" ];
          BindsTo = [ "graphical-session.target" ];
          StartLimitIntervalSec = "30";
          StartLimitBurst = "3";
        };
      };
    }
    (lib.mkIf (config.services.pipewire.enable && !config.services.pipewire.systemWide) (
      {
        pipewire.unitConfig.ConditionUser = "!@system";
      }
      // lib.optionalAttrs config.services.pipewire.pulse.enable {
        pipewire-pulse.unitConfig.ConditionUser = "!@system";
      }
    ))
    (lib.mkIf
      (
        config.services.pipewire.enable
        && config.services.pipewire.wireplumber.enable
        && !config.services.pipewire.systemWide
      )
      {
        wireplumber.unitConfig.ConditionUser = "!@system";
      }
    )
    (lib.mkIf (config.services.pulseaudio.enable && !config.services.pulseaudio.systemWide) {
      pulseaudio.unitConfig.ConditionUser = "!@system";
    })
  ];
}
