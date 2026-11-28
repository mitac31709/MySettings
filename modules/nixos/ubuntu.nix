# Headless home server configuration for host `ubuntu` (GMKtec NucBox G3, Intel N100).
# Reproduces the Ubuntu 24.04 server without a desktop stack.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  winCredsPath =
    config.age.secrets."ubuntu-win-credentials".path or "/run/agenix/ubuntu-win-credentials";

  # On-demand launcher for Minecraft instances under /home/mitac/minecraft/<name>.
  # Checks instance start scripts first (modpacks like ATM9-Eureka ship run.sh/start.sh),
  # then falls back to server.jar.
  minecraftRunner = pkgs.writeShellScript "minecraft-instance-runner" ''
    set -euo pipefail
    instance="$1"
    dir="/home/mitac/minecraft/$instance"
    cd "$dir"
    if [ -x "./start.sh" ]; then
      exec ./start.sh
    elif [ -x "./run.sh" ]; then
      exec ./run.sh
    elif [ -f "./start.sh" ]; then
      exec ${pkgs.bash}/bin/bash ./start.sh
    elif [ -f "./run.sh" ]; then
      exec ${pkgs.bash}/bin/bash ./run.sh
    elif [ -f "./server.jar" ]; then
      exec ${pkgs.jdk21_headless}/bin/java ''${JAVA_OPTS:--Xms4G -Xmx10G} -jar ./server.jar nogui
    else
      echo "minecraft@$instance: no start.sh, run.sh, or server.jar found in $dir" >&2
      exit 1
    fi
  '';
in
{
  # Headless server: skip bootvine on the boot console so remote installs stay lean.
  services.bootvine.enable = false;

  # Match current Ubuntu server locale (timezone Asia/Tokyo comes from common.nix).
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = lib.mkForce { };

  # ---------------------------------------------------------------------------
  # Networking & firewall
  # ---------------------------------------------------------------------------
  # DHCP on enp3s0 (MAC e0:51:d8:1e:90:95). The router's DHCP reservation assigns
  # 192.168.1.50; ClientIdentifier = "mac" ensures systemd-networkd presents the
  # NIC MAC instead of an RFC 4361 DUID so the reservation always matches.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.wait-online.anyInterface = true;
  systemd.network.networks."10-enp3s0" = {
    matchConfig = {
      MACAddress = "e0:51:d8:1e:90:95";
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    dhcpV4Config = {
      ClientIdentifier = "mac";
    };
  };

  # Same as Ubuntu today (ufw ENABLED=no). The router forwards TCP 22, 443,
  # 25565 and UDP 500, 4500, 1194.
  networking.firewall.enable = false;

  # ---------------------------------------------------------------------------
  # SSH & authorized keys
  # ---------------------------------------------------------------------------
  # Key-only globally (including public IP port 22); password auth allowed only
  # from LAN (192.168.1.0/24), loopback, and Tailscale (100.64.0.0/10, CGNAT/ULA).
  # PermitRootLogin = "prohibit-password" allows key-only root SSH right after
  # nixos-anywhere finishes (before `passwd mitac` and state restore).
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PubkeyAuthentication = true;
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthenticationMethods = "publickey";
    };
    extraConfig = ''
      Match Address 192.168.1.0/24,127.0.0.1/32,::1/128,100.64.0.0/10,fd7a:115c:a1e0::/48
        PasswordAuthentication yes
        KbdInteractiveAuthentication yes
        AuthenticationMethods any
    '';
  };

  # TODO: Add the remaining 3 public keys from current ubuntu's ~/.ssh/authorized_keys
  # (including the restricted pi-lecture-upload key) into keys = [ ... ] before
  # deploying, or rely on restoring /home/mitac/.ssh/authorized_keys after boot.
  users.users.mitac = {
    extraGroups = [ "docker" ];
    openssh.authorizedKeys.keyFiles = [
      ../../secrets/id-wsl-builder.pub
    ];
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [
    ../../secrets/id-wsl-builder.pub
  ];

  # ---------------------------------------------------------------------------
  # Tailscale (exit node; existing /var/lib/tailscale state will be restored)
  # ---------------------------------------------------------------------------
  services.tailscale = {
    enable = true;
    # Exit node / routing server; also enables IPv4/IPv6 forwarding (replacing
    # /etc/sysctl.d/99-tailscale.conf).
    useRoutingFeatures = "server";
    # Override modules/nixos/secrets.nix mkDefault: restored /var/lib/tailscale
    # already holds the node identity, so do not auto-reauth with an auth key.
    authKeyFile = null;
    extraUpFlags = [ ];
  };

  # ---------------------------------------------------------------------------
  # SoftEther VPN Server (nixpkgs 4.44-9807-rtm matches current build)
  # ---------------------------------------------------------------------------
  # Module dataDir defaults to /var/lib/softether.
  # vpnserver reads /var/lib/softether/vpnserver/vpn_server.config and its
  # certificates, and expects hamcore.se2 in the same directory (seeded by
  # softether-init.service on first run — restore config after init or keep
  # hamcore.se2 intact).
  services.softether = {
    enable = true;
    vpnserver.enable = true;
    dataDir = "/var/lib/softether";
  };

  # ---------------------------------------------------------------------------
  # Docker (compose stacks restored under /home/mitac; not converted to Nix)
  # ---------------------------------------------------------------------------
  # Active Docker stacks kept on compose after home restore:
  #   ZNC (~/znc), ntopng (~/ntopng), FindSenryu4Discord (~/FindSenryu4Discord),
  #   ArchiveTeam uploaderjp x2 (+ optional warrior), watchtower,
  #   zstdvpn (~/slowflow-vpn), ts-ubuntu-at-exit.
  # Stopped apps (data backed up only; no NixOS config):
  #   immich (~/immich-app + immich_model-cache), AdGuard Home (~/AdGuardHome),
  #   kikoune (~/kikoune), CloudflareOS (~/CloudflareOS), DiscordShogi (~/DiscordShogi).
  virtualisation.docker.enable = true;

  # ---------------------------------------------------------------------------
  # nix-ld: dynamic linker + shared libs for prebuilt Python wheels
  # (ctranslate2, onnxruntime, av, numpy) and Hermes binaries
  # ---------------------------------------------------------------------------
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib # libstdc++.so.6, libgomp.so.1 (ctranslate2 / onnxruntime)
      zlib
      openssl
      curl
      libffi
      sqlite
      libxml2
      libxslt
      xz
      bzip2
      ncurses
      readline
      libxcrypt
      glib
      icu
      expat
    ];
  };

  # ---------------------------------------------------------------------------
  # CIFS mount: //192.168.1.33/photos -> /mnt/windows-hdd
  # ---------------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /mnt/windows-hdd 0755 root root -"
  ];

  # TODO: Encrypt ubuntu's /etc/win-credentials into secrets/ubuntu-win-credentials.age
  # (`secrets edit ubuntu-win-credentials`) so agenix decrypts it to
  # /run/agenix/ubuntu-win-credentials. Boot never blocks thanks to nofail + automount.
  fileSystems."/mnt/windows-hdd" = {
    device = "//192.168.1.33/photos";
    fsType = "cifs";
    options = [
      "credentials=${winCredsPath}"
      "uid=mitac"
      "gid=users"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.device-timeout=15s"
      "x-systemd.mount-timeout=15s"
      "x-systemd.idle-timeout=300s"
    ];
  };

  # ---------------------------------------------------------------------------
  # Restored home-directory services (User=mitac, guarded with ConditionPathExists
  # so first boot stays clean before /home/mitac is restored)
  # ---------------------------------------------------------------------------

  # Hermes Agent gateway (~/.hermes + ~/.local/bin/hermes*)
  systemd.services.hermes-gateway = {
    description = "Hermes Agent Gateway";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/.hermes";
    };
    serviceConfig = {
      Type = "simple";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/home/mitac/.hermes";
      Environment = [
        "HOME=/home/mitac"
        "HERMES_HOME=/home/mitac/.hermes"
        "PATH=/home/mitac/.local/bin:/run/current-system/sw/bin"
      ];
      EnvironmentFile = "-/home/mitac/.hermes/.env";
      # TODO: Verify exact ExecStart from ubuntu's ~/.config/systemd/user/hermes-gateway.service
      ExecStart = "/home/mitac/.local/bin/hermes gateway run";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # siesta-bot (Python venv under ~/siesta-bot, NOT Docker — per inventory)
  systemd.services.siesta-bot = {
    description = "siesta-bot Discord Bot";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/siesta-bot/.venv/bin/python";
    };
    serviceConfig = {
      Type = "simple";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/home/mitac/siesta-bot";
      Environment = [
        "HOME=/home/mitac"
        "PATH=/home/mitac/siesta-bot/.venv/bin:/run/current-system/sw/bin"
      ];
      EnvironmentFile = "-/home/mitac/siesta-bot/.env";
      # TODO: Verify exact ExecStart from ubuntu's ~/.config/systemd/user/siesta-bot.service
      ExecStart = "/home/mitac/siesta-bot/.venv/bin/python main.py";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # lecture-asr (~/lectures, uv Python 3.12 venv, kotoba-whisper-v2.0-faster)
  systemd.services.lecture-asr = {
    description = "Lecture ASR pipeline";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/lectures/asr-config.yaml";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/home/mitac/lectures";
      Environment = [
        "HOME=/home/mitac"
        "PATH=/home/mitac/.local/bin:/run/current-system/sw/bin"
      ];
      EnvironmentFile = "-/home/mitac/.config/lecture-asr/gemini.env";
      # TODO: Verify exact venv path and ExecStart from ubuntu's ~/.config/systemd/user/lecture-asr.service
      ExecStart = "/home/mitac/lectures/.venv/bin/python -m lecture_asr --config /home/mitac/lectures/asr-config.yaml";
    };
  };

  systemd.paths.lecture-asr = {
    description = "Watch lecture ASR inbox for new recordings";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/lectures";
    };
    pathConfig = {
      # TODO: Verify exact inbox path and directive (PathChanged / DirectoryNotEmpty)
      # from ubuntu's ~/.config/systemd/user/lecture-asr.path
      DirectoryNotEmpty = "/home/mitac/lectures/inbox";
      Unit = "lecture-asr.service";
    };
  };

  systemd.timers.lecture-asr = {
    description = "Fallback timer for lecture ASR pipeline (every 30 min)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # TODO: Verify schedule against ubuntu's ~/.config/systemd/user/lecture-asr.timer
      OnUnitActiveSec = "30min";
      OnBootSec = "5min";
      Unit = "lecture-asr.service";
    };
  };

  # lecture-publish (hourly timer)
  systemd.services.lecture-publish = {
    description = "Lecture publish pipeline";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/lectures";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/home/mitac/lectures";
      Environment = [
        "HOME=/home/mitac"
        "PATH=/home/mitac/.local/bin:/run/current-system/sw/bin"
      ];
      EnvironmentFile = "-/home/mitac/.config/lecture-asr/gemini.env";
      # TODO: Verify exact ExecStart from ubuntu's ~/.config/systemd/user/lecture-publish.service
      ExecStart = "/home/mitac/lectures/.venv/bin/python -m lecture_publish";
    };
  };

  systemd.timers.lecture-publish = {
    description = "Hourly timer for lecture publish pipeline";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # TODO: Verify schedule against ubuntu's ~/.config/systemd/user/lecture-publish.timer
      OnCalendar = "hourly";
      Persistent = true;
      Unit = "lecture-publish.service";
    };
  };

  # ZNC Tailscale certificate renewal (replaces user cron `17 4 1 * *` UTC = 13:17 JST)
  systemd.services.znc-tailscale-cert = {
    description = "Renew Tailscale TLS certificate for ZNC";
    after = [
      "network-online.target"
      "tailscaled.service"
      "docker.service"
    ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/bin/renew-znc-tailscale-cert.sh";
    };
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.docker
      pkgs.tailscale
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "mitac";
      Group = "users";
      Environment = [ "HOME=/home/mitac" ];
      ExecStart = "${pkgs.bash}/bin/bash /home/mitac/bin/renew-znc-tailscale-cert.sh";
    };
  };

  systemd.timers.znc-tailscale-cert = {
    description = "Monthly ZNC Tailscale certificate renewal";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 13:17:00";
      Persistent = true;
      Unit = "znc-tailscale-cert.service";
    };
  };

  # ---------------------------------------------------------------------------
  # Minecraft on-demand template (6 instances under ~/minecraft; port 25565)
  # ---------------------------------------------------------------------------
  # Empty wantedBy: never started at boot. Start one instance on demand, e.g.:
  #   sudo systemctl start minecraft@ATM9-Eureka
  # TODO: Verify each of the 6 instance directory names under ~/minecraft and
  # whether any instance needs custom JAVA_OPTS / start command beyond start.sh/run.sh.
  systemd.services."minecraft@" = {
    description = "Minecraft Server (%i)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/minecraft/%i";
    };
    path = [
      pkgs.jdk21_headless
      pkgs.bash
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "simple";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/home/mitac/minecraft/%i";
      Environment = [ "HOME=/home/mitac" ];
      EnvironmentFile = "-/home/mitac/minecraft/%i/.env";
      ExecStart = "${minecraftRunner} %i";
      SuccessExitStatus = [
        0
        143
      ];
      TimeoutStopSec = 60;
      Restart = "no";
    };
  };

  # ---------------------------------------------------------------------------
  # System packages (strictly no cloudflared, code-server, wrangler, Node 18,
  # snapd, cloud-init, or open-vm-tools)
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    jdk21_headless
    btop
    bat
    aria2
    gh
    sqlite
    nettools
    cifs-utils
    wakeonlan
    neovim
    uv
    sl
    git
    tmux
    htop
    docker-compose
  ];
}
