# Shared user programs and packages (Hyprland session).
{
  lib,
  pkgs,
  config,
  osConfig ? null,
  ...
}:

let
  email = "mitac31709@gmail.com";
  theme = import ../lib/theme.nix;
  p = theme.palette;
  # Rasi unquoted value (same shape as config.lib.formats.rasi.mkLiteral).
  mkLiteral = value: {
    _type = "literal";
    inherit value;
  };

  ghostty = "${pkgs.ghostty}/bin/ghostty";
  yazi = "${pkgs.yazi}/bin/yazi";
  lazyPlugins = import ./lazy-plugins.nix { inherit pkgs lib; };
  agentDesktop = pkgs.callPackage ../pkgs/agent-desktop { };

  cursorPkg = theme.cursor.package pkgs;
  repoCursorsDir = ./cursors;
  localCursorPackages =
    if builtins.pathExists repoCursorsDir then
      lib.mapAttrsToList (name: _: theme.mkLocalCursor pkgs name) (
        lib.filterAttrs (name: type: type == "directory" && name != theme.cursor.name) (
          builtins.readDir repoCursorsDir
        )
      )
    else
      [ ];

  xdgSessionVariables = {
    # Keep dev toolchains, npm, PulseAudio cookie, XCompose cache, and agent/tool homes in XDG dirs.
    GOPATH = "${config.xdg.dataHome}/go";
    GRADLE_USER_HOME = "${config.xdg.dataHome}/gradle";
    NPM_CONFIG_USERCONFIG = "${config.xdg.configHome}/npm/npmrc";
    PULSE_COOKIE = "${config.xdg.configHome}/pulse/cookie";
    XCOMPOSECACHE = "${config.xdg.cacheHome}/xcompose";
    T3CODE_HOME = "${config.xdg.dataHome}/t3";
    CLAUDE_CONFIG_DIR = "${config.xdg.configHome}/claude";
    CODEX_HOME = "${config.xdg.configHome}/codex";
    DSH_HOME = "${config.xdg.dataHome}/dsh";
    AGENT_DESKTOP_HOME = "${config.xdg.dataHome}/agent-desktop";
    # Atuin 18.20+ defaults to ~/.atuin/data on fresh installs unless overridden.
    ATUIN_DATA_DIR = "${config.xdg.dataHome}/atuin";
    PLATFORMIO_CORE_DIR = "${config.xdg.dataHome}/platformio";
    ARDUINO_DIRECTORIES_DATA = "${config.xdg.dataHome}/arduino15";
    ARDUINO_DIRECTORIES_DOWNLOADS = "${config.xdg.cacheHome}/arduino15";
    ARDUINO_DIRECTORIES_USER = "${config.xdg.dataHome}/arduino";
  };
in
{
  # User identity. The system profile also ships git, without this
  # name/email, so root and a recovery shell can still run git.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "mitac";
        inherit email;
      };
      # Origin CLI credential helper (also mirrored by `origin login` in ~/.gitconfig).
      credential = {
        "https://origin.cursor.com".helper = [
          ""
          "!${config.home.homeDirectory}/.local/bin/origin credential-helper"
        ];
        "https://origin.cursor.com/git".helper = [
          ""
          "!${config.home.homeDirectory}/.local/bin/origin credential-helper"
        ];
      };
    };
  };

  # App launcher / dmenu: Nocturne Slate frosted-glass theme matching Hyprland.
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    settings = {
      terminal = "${pkgs.ghostty}/bin/ghostty";
      modes = "drun,run";
      font = "${theme.font.mono} 12";
      show-icons = true;
      disable-history = false;
      sort = true;
      sorting-method = "fzf";
      case-sensitive = false;
      cycle = true;
      # comment must be listed here to appear in drun-display-format.
      drun-match-fields = "name,generic,exec,categories,keywords,comment";
      drun-display-format = "{name} <span weight='light' size='small' foreground='${p.fgMuted}'><i>{generic}</i>  {comment}</span>";
      drun-show-actions = true;
      display-drun = "󰀻";
      display-run = "󰆍";
      display-dmenu = "󰍉";
      location = 0;
      # overlay sits above Fcitx5 ClassicUI, so Meltype candidates never appear.
      # top keeps the launcher above windows but below the IME panel.
      wayland-layer = "top";
      # click-to-exit steals focus from the Meltype candidate surface (upstream #2278).
      click-to-exit = false;
    };
    theme = {
      "*" = {
        bg = mkLiteral "${p.surface}e8";
        bg-card = mkLiteral "${p.surfaceAlt}f0";
        bg-sel = mkLiteral "${p.accentSoft}f5";
        border-col = mkLiteral p.border;
        fg = mkLiteral p.fg;
        fg-dim = mkLiteral p.fgMuted;
        accent = mkLiteral p.accent;
        urgent = mkLiteral p.danger;
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@fg";
      };

      "window" = {
        background-color = mkLiteral "@bg";
        border = mkLiteral "1.5px";
        border-color = mkLiteral "@accent";
        border-radius = mkLiteral "${toString theme.radius.popup}px";
        width = mkLiteral "54em";
        padding = mkLiteral "16px";
      };

      "mainbox" = {
        children = map mkLiteral [
          "inputbar"
          "message"
          "listview"
        ];
        spacing = mkLiteral "12px";
      };

      "inputbar" = {
        children = map mkLiteral [
          "prompt"
          "entry"
        ];
        spacing = mkLiteral "10px";
        padding = mkLiteral "10px 14px";
        border = mkLiteral "1px";
        border-color = mkLiteral "@border-col";
        border-radius = mkLiteral "${toString theme.radius.control}px";
        background-color = mkLiteral "@bg-card";
        text-color = mkLiteral "@accent";
      };

      "prompt" = {
        text-color = mkLiteral "@accent";
        background-color = mkLiteral "transparent";
      };

      "entry" = {
        placeholder = "検索・起動…";
        placeholder-color = mkLiteral "@fg-dim";
        text-color = mkLiteral "@fg";
        background-color = mkLiteral "transparent";
        cursor = mkLiteral "text";
      };

      "listview" = {
        lines = 11;
        columns = 1;
        fixed-height = true;
        dynamic = true;
        scrollbar = true;
        spacing = mkLiteral "4px";
        background-color = mkLiteral "transparent";
      };

      "scrollbar" = {
        width = mkLiteral "4px";
        handle-color = mkLiteral "@accent";
        handle-width = mkLiteral "4px";
        border-radius = mkLiteral "4px";
        background-color = mkLiteral "transparent";
      };

      "element" = {
        padding = mkLiteral "7px 12px";
        spacing = mkLiteral "12px";
        border = mkLiteral "1px";
        border-color = mkLiteral "transparent";
        border-radius = mkLiteral "${toString theme.radius.control}px";
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@fg";
        children = map mkLiteral [
          "element-icon"
          "element-text"
        ];
      };

      "element-icon" = {
        size = mkLiteral "1.45em";
        background-color = mkLiteral "inherit";
        text-color = mkLiteral "inherit";
      };

      "element-text" = {
        background-color = mkLiteral "inherit";
        text-color = mkLiteral "inherit";
        vertical-align = mkLiteral "0.5";
        markup = mkLiteral "true";
      };

      "element selected" = {
        background-color = mkLiteral "@bg-sel";
        border-color = mkLiteral "@accent";
        text-color = mkLiteral "@accent";
      };

      "element alternate" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@fg";
      };

      "element urgent" = {
        text-color = mkLiteral "@urgent";
      };

      "message" = {
        background-color = mkLiteral "@bg-card";
        border = mkLiteral "1px";
        border-color = mkLiteral "@border-col";
        border-radius = mkLiteral "${toString theme.radius.control}px";
        padding = mkLiteral "8px 12px";
      };

      "textbox" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "@fg-dim";
      };
    };
  };

  # GitHub CLI. gitCredentialHelper (default on) wires HTTPS push/pull to
  # `gh auth git-credential` so we never need to write ~/.config/git/config
  # (that path is a Home Manager → Nix store symlink on this host).
  programs.gh = {
    enable = true;
    settings.git_protocol = "https";
  };

  # Clean GTK 2/3/4 + Adwaita icon/cursor config (replaces legacy KDE settings.ini
  # with missing colorreload-gtk-module / breeze_cursors). Keep gtk.colorScheme null
  # so gtk-4.0/settings.ini uses gtk-interface-color-scheme instead of deprecated
  # gtk-application-prefer-dark-theme (which triggers libadwaita warnings).
  gtk = {
    enable = true;
    colorScheme = null;
    iconTheme = {
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
    };
    gtk2 = {
      force = true;
      configLocation = "${config.xdg.configHome}/gtk-2.0/gtkrc";
    };
    gtk3 = {
      colorScheme = "dark";
      extraConfig.gtk-application-prefer-dark-theme = true;
    };
    gtk4.extraConfig.gtk-interface-color-scheme = "dark";
  };

  # Packaged cursor themes go through home.pointerCursor. Local-only themes
  # (theme.cursor.package = null) live in ~/.local/share/icons/<name> outside
  # the repo: home.pointerCursor requires a store package and would symlink
  # over that directory, so emit the equivalent configuration directly.
  home.pointerCursor = lib.mkIf (theme.cursor.package != null) {
    enable = true;
    package = cursorPkg;
    name = theme.cursor.name;
    size = theme.cursor.size;
    gtk.enable = true;
    x11.enable = true;
    hyprcursor.enable = theme.cursor.hyprcursor;
  };

  home.sessionSearchVariables.XCURSOR_PATH = lib.mkIf (theme.cursor.package == null) [
    "${config.home.homeDirectory}/.local/share/icons"
    "${config.home.profileDirectory}/share/icons"
  ];
  gtk.cursorTheme = lib.mkIf (theme.cursor.package == null) {
    package = null;
    inherit (theme.cursor) name size;
  };
  xdg.dataFile."icons/default/index.theme" = lib.mkIf (theme.cursor.package == null) {
    text = ''
      [Icon Theme]
      Name=Default
      Comment=Default Cursor Theme
      Inherits=${theme.cursor.name}
    '';
  };
  home.file.".icons/default/index.theme" = lib.mkIf (theme.cursor.package == null) {
    text = ''
      [Icon Theme]
      Name=Default
      Comment=Default Cursor Theme
      Inherits=${theme.cursor.name}
    '';
  };
  xresources.properties = lib.mkIf (theme.cursor.package == null) {
    "Xcursor.theme" = theme.cursor.name;
    "Xcursor.size" = theme.cursor.size;
  };

  dconf.settings = {
    # Keystroke overlay preferences (JP keyboard layout, interactive mode).
    "one/alynx/showmethekey" = {
      clickable = true;
      first-time = false;
      layout = "jp";
    };
    # Nemo "Open in Terminal" (defaults to gnome-terminal otherwise).
    "org/cinnamon/desktop/applications/terminal" = {
      exec = "ghostty";
      exec-arg = "-e";
    };
  };

  # Stub: prevent stale light colors.css @import from overriding GTK / Colorshell theme.
  xdg.configFile = lib.mkMerge [
    {
      "gtk-3.0/settings.ini".force = true;
      "gtk-4.0/settings.ini".force = true;
      "gtk-3.0/gtk.css".text = ''
        /* keep empty — avoid stale light GTK CSS overrides */
      '';
      "gtk-4.0/gtk.css".text = ''
        /* keep empty — avoid stale light GTK CSS overrides */
      '';
      "npm/npmrc".text = ''
        prefix=${config.xdg.dataHome}/npm-global
        cache=${config.xdg.cacheHome}/npm
        allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs
      '';
      "nvim".source = ./nvim;
    }
    (lib.mkIf (osConfig != null) {
      # Fcitx reads ~/.config/fcitx5 before /etc/xdg/fcitx5. These symlinks are the
      # same INI the NixOS module writes to /etc, so an old user copy (keyboard-jp,
      # Zenkaku as Trigger) cannot win. The store file is read-only: change the
      # input method in modules/nixos/common.nix, not in fcitx5-configtool.
      "fcitx5/profile" = {
        text = osConfig.environment.etc."xdg/fcitx5/profile".text;
        force = true;
      };
      "fcitx5/config" = {
        text = osConfig.environment.etc."xdg/fcitx5/config".text;
        force = true;
      };
      "fcitx5/conf/classicui.conf" = {
        text = osConfig.environment.etc."xdg/fcitx5/conf/classicui.conf".text;
        force = true;
      };
      "fcitx5/conf/waylandim.conf" = {
        text = osConfig.environment.etc."xdg/fcitx5/conf/waylandim.conf".text;
        force = true;
      };
    })
  ];

  # Bitwarden client (rbw). Holds the restic backup encryption key; see
  # modules/nixos/backup.nix. Log in once with `rbw login` after first switch.
  programs.rbw = {
    enable = true;
    settings = {
      inherit email;
      # Official Bitwarden EU cloud (defaults are .com / US).
      base_url = "https://api.bitwarden.eu";
      identity_url = "https://identity.bitwarden.eu";
      ui_url = "https://vault.bitwarden.eu";
      notifications_url = "https://notifications.bitwarden.eu";
      pinentry = pkgs.rofi-prompt;
      lock_timeout = 3600;
    };
  };

  # GnuPG + gpg-agent using the same Rofi pinentry as rbw.
  programs.gpg = {
    enable = true;
    homedir = "${config.xdg.dataHome}/gnupg";
  };
  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.rofi-prompt;
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    # LazyVim plugins and treesitter parsers come from nixpkgs
    # (home/lazy-plugins.nix). Mason stays disabled. LSP / format / search
    # CLIs stay here; nvim does not download them.
    extraPackages = with pkgs; [
      ripgrep
      fd
      lua-language-server
      stylua
    ];
  };

  # Default terminal (Ctrl+Alt+T / Super+Return) — Nocturne Slate translucent theme.
  programs.ghostty = {
    enable = true;
    settings = {
      font-family = theme.font.mono;
      font-size = 12;
      gtk-single-instance = true;
      window-padding-x = 12;
      window-padding-y = 10;
      window-decoration = false;
      background = p.bg;
      foreground = p.fg;
      cursor-color = p.accent;
      selection-background = p.accentSoft;
      selection-foreground = p.fg;
      background-opacity = 0.90;
      palette = [
        "0=#131922"
        "1=#f07178"
        "2=#6ee7b7"
        "3=#f2b866"
        "4=#4ea8de"
        "5=#b794f4"
        "6=#56d4c8"
        "7=#c7d3e0"
        "8=#4b596b"
        "9=#ff8a92"
        "10=#8cf2ca"
        "11=#ffd08a"
        "12=#73c0f0"
        "13=#cdb4fa"
        "14=#7ae6dc"
        "15=#f0f5fa"
      ];
    };
  };

  home.sessionVariables =
    xdgSessionVariables
    // {
      TERMINAL = "ghostty";
      # Java AWT on tiling Wayland/XWayland compositors: prevents solid black frames.
      _JAVA_AWT_WM_NONREPARENTING = "1";
      # Expose Qt widget trees over AT-SPI2 for agent-desktop.
      QT_ACCESSIBILITY = "1";
    }
    # Local-only cursor theme (see the home.pointerCursor note above).
    // lib.optionalAttrs (theme.cursor.package == null) (
      {
        XCURSOR_THEME = theme.cursor.name;
        XCURSOR_SIZE = toString theme.cursor.size;
      }
      // lib.optionalAttrs theme.cursor.hyprcursor {
        HYPRCURSOR_THEME = theme.cursor.name;
        HYPRCURSOR_SIZE = toString theme.cursor.size;
      }
    );

  systemd.user.sessionVariables = xdgSessionVariables;

  # libX11 creates compose cache files under $XCOMPOSECACHE only when the directory exists.
  home.activation.ensureXComposeCacheDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.coreutils}/bin/install -d -m 700 "${config.xdg.cacheHome}/xcompose"
  '';

  # Yazi via Ghostty launcher entry.
  xdg.dataFile."applications/mitac-yazi.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Yazi
    Comment=Terminal file manager (Ghostty)
    Exec=${ghostty} -e ${yazi} %U
    Icon=yazi
    Terminal=false
    Categories=System;FileManager;FileTools;
    MimeType=inode/directory;
    StartupNotify=true
  '';

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = [ "nemo.desktop" ];
      "text/plain" = [ "nvim.desktop" ];
      "text/markdown" = [ "nvim.desktop" ];
      "text/x-cmake" = [ "nvim.desktop" ];
      "application/json" = [ "nvim.desktop" ];
      "application/x-shellscript" = [ "nvim.desktop" ];
      "application/zip" = [ "peazip.desktop" ];
      "application/x-7z-compressed" = [ "peazip.desktop" ];
      "application/x-tar" = [ "peazip.desktop" ];
      "application/gzip" = [ "peazip.desktop" ];
      "application/x-xz" = [ "peazip.desktop" ];
      "application/x-rar" = [ "peazip.desktop" ];
      "application/vnd.rar" = [ "peazip.desktop" ];
      "text/html" = [ "vivaldi-stable.desktop" ];
      "x-scheme-handler/http" = [ "vivaldi-stable.desktop" ];
      "x-scheme-handler/https" = [ "vivaldi-stable.desktop" ];
      "x-scheme-handler/about" = [ "vivaldi-stable.desktop" ];
      "x-scheme-handler/unknown" = [ "vivaldi-stable.desktop" ];
      "x-scheme-handler/codex" = [ "chatgpt.desktop" ];
    };
  };

  # Writable npm global prefix (store node/npm cannot install -g into itself)
  # lives in xdg.configFile."npm/npmrc" + NPM_CONFIG_USERCONFIG.
  home.sessionPath = [
    "${config.xdg.dataHome}/npm-global/bin"
  ];

  # Export XDG_* variables explicitly (xdg.localBinInPath stays false so stale
  # legacy symlinks in ~/.local/bin do not shadow Nix store binaries).
  xdg.enable = true;

  # Keep XDG dirs in English even with ja_JP.UTF-8 locale; disable unused ones with "$HOME/".
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = "$HOME/";
    documents = "$HOME/Documents";
    download = "$HOME/Downloads";
    music = "$HOME/";
    pictures = "$HOME/Pictures";
    publicShare = "$HOME/";
    templates = "$HOME/";
    videos = "$HOME/";
    projects = "$HOME/Projects";
  };

  # xdg.configFile."nvim".source is merged in xdg.configFile above.
  # Keep outside lazy's plugin root (~/.local/share/nvim/lazy/): a HM symlink
  # there is seen as uninstalled (Util.ls reports "link"), so lazy tries to
  # re-clone and fails with "should be a directory!". dev.path below is a
  # sibling directory of real directories (linkFarm), which lazy accepts.
  xdg.dataFile."nvim/nix/lazy.nvim".source = "${pkgs.vimPlugins.lazy-nvim}";
  xdg.dataFile."nvim/nix/plugins".source = lazyPlugins.plugins;
  xdg.dataFile."nvim/nix/treesitter".source = lazyPlugins.treesitter;

  # Terminal file manager (Hyprland: Super+e → Ghostty -e yazi).
  # Bash wrapper `y` cds into the last dir on quit.
  programs.yazi = {
    enable = true;
    enableBashIntegration = true;
    settings = {
      mgr = {
        show_hidden = true;
        show_symlink = true;
        sort_by = "natural";
        sort_dir_first = true;
        # mtime on the right; toggle with m+m / m+p / m+o inside Yazi.
        linemode = "mtime";
      };
      preview = {
        wrap = "yes";
        tab_size = 2;
      };
    };
  };

  # Resource monitor (btop; installed via programs.btop.package).
  # save_config_on_exit = false avoids write-on-exit noise against RO store link.
  programs.btop = {
    enable = true;
    settings = {
      shown_boxes = "net proc cpu mem";
      update_ms = 400;
      proc_sorting = "cpu-lazy";
      save_config_on_exit = false;
    };
  };

  home.packages =
    with pkgs;
    [
      nix-output-monitor
      # Cat clone with syntax highlighting (`bat`; Debian package name is batcat).
      bat
      # Steam Locomotive — joke for mistyping `ls`.
      sl
      # Download utility (command: aria2c).
      aria2
      # YouTube / media downloader.
      yt-dlp
      # Media file technical metadata.
      mediainfo
      # RTSP / local video player (`mpv`).
      mpv
      # ffmpeg + ffplay (RTSP probe / playback).
      ffmpeg
      # 7-Zip with Zstd/Brotli/LZ4/etc. (`7z` / `7zz`). Attribute starts with `_` (digit).
      _7zip-zstd
      # Archive manager GUI (7z / Zstd / zip / tar / …). Desktop: PeaZip.
      peazip
      code-cursor
      # Zed code editor (CLI: zeditor).
      zed-editor
      # Terminal Agent CLI (`cursor-agent`; also aliased as `agent`).
      cursor-cli
      # OpenCode 2 terminal agent (`opencode`; pkgs/opencode overrides nixpkgs 1.x).
      opencode
      # Anthropic Claude Code CLI (`claude`).
      claude-code
      # Computer use CLI for AI agents (`agent-desktop`; pkgs/agent-desktop).
      agentDesktop
      # T3 Code: desktop + `t3` CLI; PATH wraps already-installed agents (including raw `antigravity` CLI).
      # The Colorshell agent card (pkgs/agent-run-status) speaks this package's
      # RPC. home/hyprland.nix rejects any version other than 0.1.11.
      (symlinkJoin {
        name = "t3code-${t3code.version}";
        paths = [
          (t3code.override {
            enableClaude = true;
            enableCursor = true;
            enableCursorCli = true;
            enableOpencode = true;
          })
        ];
        nativeBuildInputs = [ makeBinaryWrapper ];
        postBuild = ''
          for program in "$out/bin"/*; do
            if [ -e "$program" ]; then
              wrapProgram "$program" --prefix PATH : ${lib.makeBinPath [ antigravity ]}
            fi
          done
        '';
        inherit (t3code) meta;
      })
      # Google Antigravity CLI (`agy` / `antigravity`; pkgs/antigravity).
      antigravity
      # ChatGPT desktop (Codex included). App menu: ChatGPT.
      chatgpt
      # Grok Bot desktop agent. App menu: Grok Bot (`grok-bot`).
      grok-bot
      # Earthquake map (pkgs/jquake: Hyprland/XWayland AWT fix + sounds cwd + http.agent).
      jquake
      onlyoffice-desktopeditors
      # 3D printer slicer (Bambu/Prusa fork). App menu: OrcaSlicer (`orca-slicer`).
      orca-slicer
      # Affinity v3 is not installed. The affinity-nix input and overlay were
      # removed. Re-add steps are in the README (Affinity). Wine builds often
      # take hours when cache.forall.systems misses.
      parsec-bin
      # Wineprefix manager for Windows apps/games (FHS-wrapped).
      (bottles.override { removeWarningPopup = true; })
      # wol-pc (Wake-on-LAN client): packaged via pkgs/wol-pc; reads agenix
      # (/run/agenix/wol-pc-env) or $WOL_PC_CONFIG.
      wol-pc
      rofi-prompt
      tmux
      ripgrep
      fd
      trayscale
      vivaldi
      firefox
      # Tor Browser Bundle (not the tor daemon alone).
      tor-browser
      # Terminal web browser (`cha`) and man-page viewer (`mancha`).
      chawan
      # On-screen keystroke overlay (useful for demos / Chromebook Fn keys).
      showmethekey
      # Activity / work history trackers (ActivityWatch: home/activitywatch.nix, WhatPulse: home/whatpulse.nix).
      screenpipe
      # Google Quick Share / Nearby Share client for Linux.
      rquickshare
      discord
      # ESP32 / Arduino CLI flash & board package manager.
      arduino-cli
      # Espressif ROM / flash probe (chip-id, flash-id, …).
      esptool
      # Android screen mirror / control (GUI; wraps adb + scrcpy-server).
      qtscrcpy
      # adb / fastboot on PATH. QtScrcpy embeds its own adb, but the cheatsheet
      # runs `adb devices` as a separate command, so this package stays.
      android-tools
      # Node.js (`node` / `npm`) and pnpm (standalone binary; uses `node` on PATH).
      nodejs
      pnpm
      # Typst typesetting (CLI). Cursor uses the Tinymist extension for LSP/preview.
      typst
      tinymist
      typstyle
      # Qalculate! scientific calculator (Qt GUI `qalculate-qt` + CLI `qalc`).
      qalculate-qt
      libqalculate
      # Tilion Fortress: local stealth Chromium engine + `tilion` / `tilion-mcp` CLI (pkgs/tilion-fortress).
      tilion-fortress
    ]
    ++ localCursorPackages;
}
