{
  description = "NixOS configuration for mitac (Hyprland (UWSM) + greetd, Chromebook delbin & VAIO)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Declarative age-encrypted secrets (decrypted at activation using Bitwarden-backed master key).
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Live systemd job tree on the boot console.
    # https://codeberg.org/wvhulle/bootvine/src/branch/main/docs/install.md
    bootvine = {
      url = "git+https://codeberg.org/wvhulle/bootvine";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # ChromeOS ALSA UCM overlays (sof-rt5682 etc. for volteer/delbin)
    alsa-ucm-conf-cros = {
      url = "github:WeirdTreeThing/alsa-ucm-conf-cros/standalone";
      flake = false;
    };
    # Declarative AI agent skills & plugins (updated by `flake-update`).
    ponytail = {
      url = "github:DietrichGebert/ponytail";
      flake = false;
    };
    agent-desktop-skills = {
      url = "github:vercel-labs/agent-desktop";
      flake = false;
    };
    jakubkrehel-skills = {
      url = "github:jakubkrehel/skills";
      flake = false;
    };
    # Fresher nixpkgs solely for Cursor packages (avoid bumping the whole system).
    # flake-update does not move this input; flake-update-cursor does.
    nixpkgs-cursor.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Hermes Agent (CLI + ACP). Do not follow nixpkgs — uv2nix lock pins upstream.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # Colorshell (GTK4 + Astal Hyprland desktop shell). Do not follow nixpkgs —
    # our 26.11 nixpkgs removed pkgs.astal, while colorshell pins a compatible nixpkgs + pywal16.
    colorshell = {
      url = "github:retrozinndev/colorshell";
      inputs.home-manager.follows = "home-manager";
    };
    # HyprEndfield (Linux / Hyprland port of DDDuoDuo/EndfieldHUD).
    hyprendfield = {
      url = "github:OctoberPrayRain/HyprEndfield";
      flake = false;
    };
    # Vendor .debs (flake update re-fetches; see scripts/flake-update.sh).
    # Keep URL version in sync with uniclipboardVersion below (flake-update.sh).
    uniclipboard-deb = {
      url = "https://github.com/UniClipboard/UniClipboard/releases/download/v1.6.2/UniClipboard_1.6.2_amd64.deb";
      flake = false;
    };
    # Keep URL version in sync with chatgptVersion below (flake-update.sh).
    chatgpt-deb = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.1117.41037_amd64.deb";
      flake = false;
    };
    # Keep URL version in sync with grokBotVersion below (flake-update.sh).
    grok-bot-deb = {
      url = "https://downloads.cursor.com/grokbot/stable/a5927fa2ba82336a29f9343babd28b4c903abbb2/linux/x64/grok-bot_1.2.3_amd64.deb";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      agenix,
      alsa-ucm-conf-cros,
      bootvine,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      # Must match inputs.uniclipboard-deb URL (updated by scripts/flake-update.sh).
      uniclipboardVersion = "1.6.2";
      # Must match inputs.chatgpt-deb URL (updated by scripts/flake-update.sh).
      chatgptVersion = "26.1117.41037";
      # Must match inputs.grok-bot-deb URL (updated by scripts/flake-update.sh).
      grokBotVersion = "1.2.3";

      mkHost =
        {
          flakeTarget,
          hostModule,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs flakeTarget; };
          modules = [
            hostModule
            home-manager.nixosModules.home-manager
            agenix.nixosModules.default
            bootvine.nixosModules.default
            {
              # Links this generation to a git commit (shows in
              # `nixos-rebuild list-generations` / `nixos-version --json`).
              # Uncommitted trees get dirtyRev / dirtyShortRev; clean trees get rev.
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";

              nixpkgs.config.allowUnfree = true;
              nixpkgs.overlays = [
                (
                  final: prev:
                  let
                    # Electron app + Agent CLI; pull latest Cursor without a full nixpkgs bump.
                    cursorPkgs = import inputs.nixpkgs-cursor {
                      system = prev.stdenv.hostPlatform.system;
                      config.allowUnfree = true;
                    };
                  in
                  {
                    inherit (cursorPkgs) cursor-cli;
                    # Cursor's resources/helpers/node is an unpatched FHS binary that
                    # SIGSEGVs under nix-ld on this host (dl_main / SEGV_ACCERR). MCP
                    # / npm-exec helpers then dump core. Point it at nixpkgs node.
                    code-cursor = cursorPkgs.code-cursor.overrideAttrs (old: {
                      postInstall = (old.postInstall or "") + ''
                        helperNode="$out/lib/cursor/resources/app/resources/helpers/node"
                        if [[ -e "$helperNode" ]]; then
                          rm -f "$helperNode"
                          ln -s ${final.nodejs}/bin/node "$helperNode"
                        fi
                      '';
                    });
                    uniclipboard = final.callPackage ./pkgs/uniclipboard {
                      src = inputs.uniclipboard-deb;
                      version = uniclipboardVersion;
                    };
                    # Meltype Linux preview as Fcitx5 addon (not in nixpkgs).
                    meltype = final.callPackage ./pkgs/meltype { };
                    # Official ChatGPT Linux desktop (.deb + Wayland/Meltype IME + Vivaldi NativeMessagingHosts).
                    chatgpt = final.callPackage ./pkgs/chatgpt {
                      src = inputs.chatgpt-deb;
                      version = chatgptVersion;
                    };
                    # Official Grok Bot Linux desktop (Cursor / x.ai).
                    grok-bot = final.callPackage ./pkgs/grok-bot {
                      src = inputs.grok-bot-deb;
                      version = grokBotVersion;
                    };
                    # 1.8.4 + Hyprland/XWayland AWT / sounds / no-update-prompt wrapper.
                    jquake = final.callPackage ./pkgs/jquake { jquake = prev.jquake; };
                    # OpenCode 2 CLI (pin upstream @opencode/cli-linux-x64 npm binary for flake-update).
                    opencode = final.callPackage ./pkgs/opencode { };
                    # Google Antigravity CLI (`agy`; binary from antigravity-public).
                    antigravity = final.callPackage ./pkgs/antigravity { };
                    # Unified Rofi prompt helpers (Askpass, Pinentry, Polkit).
                    rofi-prompt = final.callPackage ./pkgs/rofi-prompt { };
                    # Wake-on-LAN SSH relay client (`wake-pc`) & desktop entry.
                    wol-pc = final.callPackage ./pkgs/wol-pc { };
                    # Activity trackers: WhatPulse (+ external pcap daemon) and Screenpipe.
                    whatpulse = final.callPackage ./pkgs/whatpulse { };
                    whatpulse-pcap-service = final.callPackage ./pkgs/whatpulse-pcap-service { };
                    screenpipe = final.callPackage ./pkgs/screenpipe { };
                    # Cursor Gothic sans-serif typeface (OpenType extracted from WOFF2).
                    cursor-gothic = final.callPackage ./pkgs/cursor-gothic { };
                    # T3 Code 0.1.11 (nixpkgs still ships 0.1.8) + Antigravity 1.5 quota auto-resume patch.
                    t3code = final.callPackage ./pkgs/t3code { };
                    # Tilion Fortress: local stealth Chromium engine + tilion / tilion-mcp CLI.
                    tilion-fortress = final.callPackage ./pkgs/tilion-fortress { };
                    # HyprEndfield: Arknights: Endfield inspired HUD overlay for Hyprland.
                    hyprendfield = final.callPackage ./pkgs/hyprendfield {
                      src = inputs.hyprendfield;
                    };
                  }
                )
              ];
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                # Rename colliding existing files instead of failing activation
                # (e.g. ~/.config/user-dirs.dirs from xdg-user-dirs).
                backupFileExtension = "backup";
                extraSpecialArgs = { inherit inputs flakeTarget; };
                users.mitac = import ./home/mitac.nix;
              };
            }
          ];
        };

      chromebook = mkHost {
        flakeTarget = "chromebook";
        hostModule = ./hosts/chromebook;
      };
    in
    {
      nixosConfigurations = {
        inherit chromebook;
        vaio = mkHost {
          flakeTarget = "vaio";
          hostModule = ./hosts/vaio;
        };
        # Legacy alias so existing `.#mitac` rebuild commands keep working.
        mitac = chromebook;
      };

      packages.${system} = {
        # Colorshell's T3 status bridge. Same sources the hosts install.
        agent-run-status =
          let
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
          in
          pkgs.callPackage ./pkgs/agent-run-status { };
      };
    };
}
