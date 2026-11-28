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
  zstdvpnEnvPath = config.age.secrets."ubuntu-zstdvpn-env".path or "/run/agenix/ubuntu-zstdvpn-env";

  javaBin = "${pkgs.jdk21_headless}/bin/java";

  # Confirmed Minecraft instances under /home/mitac/minecraft/ (measured 2026-11-29).
  # Directory name typos (`latest-vanila`, `yower-1.21.1`) and jar names match the
  # live machine verbatim. All 6 stay disabled at boot (wantedBy = [ ]) and share
  # TCP 25565 (mutually exclusive via systemd conflicts). ATM9-Eureka was used last.
  minecraftInstanceSpecs = {
    # Live scripts: startserver.sh (also run.sh). user_jvm_args.txt: -Xms6G -Xmx12G + Aikar G1.
    "ATM10" = {
      execStart = "${javaBin} @user_jvm_args.txt @libraries/net/neoforged/neoforge/21.1.215/unix_args.txt nogui";
    };
    # Live scripts: startserver.sh (also run.sh). user_jvm_args.txt: -Xms3072M -Xmx10G + G1/StringDedup/gc.log.
    "ATM9-Eureka" = {
      execStart = "${javaBin} @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.4.23/unix_args.txt nogui";
    };
    # Live script: run.sh (no user_jvm_args.txt). Heap: -Xms6G -Xmx6G.
    "latest-vanila" = {
      execStart = "${javaBin} -Xms6G -Xmx6G -jar server.jar --nogui";
    };
    # Live script: startserver.sh. user_jvm_args.txt: -Xms6G -Xmx12G + Aikar G1.
    "mohist-1.20.1" = {
      execStart = "${javaBin} @user_jvm_args.txt -jar mohist-1.20.1-6e92c50.jar nogui";
    };
    # Live script: run.sh (no user_jvm_args.txt). Heap: -Xms4096M -Xmx4096M.
    "paper-1.21.11" = {
      execStart = "${javaBin} -Xms4096M -Xmx4096M -jar server.jar --nogui";
    };
    # Live script: start.sh (jar is youer-1.21.1-a54a27d.jar). user_jvm_args.txt: -Xms4G -Xmx12G + Aikar G1.
    "yower-1.21.1" = {
      execStart = "${javaBin} @user_jvm_args.txt -jar youer-1.21.1-a54a27d.jar nogui";
    };
  };

  minecraftInstances = builtins.attrNames minecraftInstanceSpecs;

  # Generic fallback runner for the minecraft@ template (any ad-hoc future instance).
  minecraftRunner = pkgs.writeShellScript "minecraft-instance-runner" ''
    set -euo pipefail
    instance="$1"
    dir="/home/mitac/minecraft/$instance"
    cd "$dir"
    for script in ./startserver.sh ./start.sh ./run.sh; do
      if [ -x "$script" ]; then
        exec "$script"
      elif [ -f "$script" ]; then
        exec ${pkgs.bash}/bin/bash "$script"
      fi
    done
    if [ -f "./server.jar" ]; then
      exec ${javaBin} ''${JAVA_OPTS:--Xms4G -Xmx10G} -jar ./server.jar nogui
    else
      echo "minecraft@$instance: no startserver.sh, start.sh, run.sh, or server.jar found in $dir" >&2
      exit 1
    fi
  '';

  mkMinecraftUnit = instance: spec: {
    description = "Minecraft Server (${instance})";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Only one instance may bind TCP 25565 at a time.
    conflicts = map (other: "minecraft@${other}.service") (
      lib.filter (other: other != instance) minecraftInstances
    );
    wantedBy = [ ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/minecraft/${instance}";
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
      WorkingDirectory = "/home/mitac/minecraft/${instance}";
      Environment = [ "HOME=/home/mitac" ];
      ExecStart = spec.execStart;
      SuccessExitStatus = [
        0
        143
      ];
      TimeoutStopSec = 60;
      Restart = "no";
    };
  };
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
  # Matches live ubuntu /etc/ssh/sshd_config exactly:
  # - Key-only globally (including public IP port 22).
  # - Password auth allowed from LAN (192.168.1.0/24) and loopback.
  # - Password auth allowed from Tailscale range (100.64.0.0/10, fd7a:115c:a1e0::/48)
  #   ONLY when arriving on the host's Tailscale LocalAddress (100.124.196.22 /
  #   fd7a:115c:a1e0::f101:c484, preserved by restoring /var/lib/tailscale).
  # - PermitRootLogin = "prohibit-password" allows key-only root SSH right after
  #   nixos-anywhere finishes (before `passwd mitac` and state restore).
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
      Match Address 192.168.1.0/24,127.0.0.1/32,::1/128
        PasswordAuthentication yes
        KbdInteractiveAuthentication yes
        AuthenticationMethods any

      Match LocalAddress 100.124.196.22,fd7a:115c:a1e0::f101:c484 Address 100.64.0.0/10,fd7a:115c:a1e0::/48
        PasswordAuthentication yes
        KbdInteractiveAuthentication yes
        AuthenticationMethods any
    '';
  };

  # All 4 public keys from live ubuntu ~/.ssh/authorized_keys:
  # - mitac@NixOS comes from ../../secrets/id-wsl-builder.pub (no duplication).
  # - pi-lecture-upload keeps command=rrsync (using pkgs.rrsync on NixOS),
  #   restrict, and from="100.71.240.112" (raspberrypi Tailscale IP).
  users.users.mitac = {
    extraGroups = [ "docker" ];
    openssh.authorizedKeys = {
      keyFiles = [
        ../../secrets/id-wsl-builder.pub
      ];
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINA+Viz0A1SfEl0MwqyLjLicGL+8tTGntansBGu/K8RX grokbot-box"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPC4hGzSF3S6BzLUPeHAO5TGPR3xRWefQpgpmrUYL9J"
        ''command="${lib.getExe pkgs.rrsync} -wo -no-del /home/mitac/lectures/inbox",restrict,from="100.71.240.112" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK2N8cVaSxLCHbwt1k0d7uCsSjGSp9vTUytf4B5z70Eo pi-lecture-upload''
      ];
    };
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [
    ../../secrets/id-wsl-builder.pub
  ];

  # ---------------------------------------------------------------------------
  # Tailscale (exit node + home LAN subnet router; /var/lib/tailscale restored)
  # ---------------------------------------------------------------------------
  services.tailscale = {
    enable = true;
    # Exit node / routing server; also enables IPv4/IPv6 forwarding (replacing
    # /etc/sysctl.d/99-tailscale.conf; note live Ubuntu had IPv6 forwarding off).
    useRoutingFeatures = "server";
    # Overrides modules/nixos/common.nix mkDefault; keep --operator=mitac (needed
    # by znc-tailscale-cert for `tailscale cert`) and declare exit node + home
    # LAN subnet route matching live Tailscale prefs.
    extraSetFlags = [
      "--operator=mitac"
      "--advertise-exit-node"
      "--advertise-routes=192.168.1.0/24"
    ];
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
  # Docker & OCI containers
  # ---------------------------------------------------------------------------
  # Compose stacks restored under /home/mitac (have compose files on live host):
  #   ntopng (~/ntopng), FindSenryu4Discord (~/FindSenryu4Discord).
  # Stopped apps (data backed up only; no NixOS config):
  #   immich (~/immich-app + immich_model-cache), AdGuard Home (~/AdGuardHome),
  #   kikoune (~/kikoune), CloudflareOS (~/CloudflareOS), DiscordShogi (~/DiscordShogi).
  # Standalone `docker run` containers (no compose file on live host) are
  # declared below via virtualisation.oci-containers.
  virtualisation.docker.enable = true;

  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      znc = {
        image = "znc:latest";
        user = "1000:1000";
        ports = [ "100.124.196.22:6697:6697/tcp" ];
        volumes = [ "/home/mitac/znc:/znc-data" ];
      };

      ts-ubuntu-at-exit = {
        image = "tailscale/tailscale:latest";
        capabilities = {
          NET_ADMIN = true;
          NET_RAW = true;
        };
        devices = [ "/dev/net/tun:/dev/net/tun" ];
        entrypoint = "/entrypoint.sh";
        volumes = [
          "/home/mitac/ts-ubuntu-at-exit/entrypoint.sh:/entrypoint.sh:ro"
          "ts-ubuntu-at-exit-state:/var/lib/tailscale"
        ];
      };

      uploaderjp-grab = {
        image = "atdr.meo.ws/archiveteam/uploaderjp-grab:latest";
        cmd = [
          "--concurrent"
          "5"
          "mitac"
        ];
        labels = {
          "com.centurylinklabs.watchtower.enable" = "true";
        };
      };

      uploaderjp-grab-pi = {
        image = "atdr.meo.ws/archiveteam/uploaderjp-grab:latest";
        cmd = [
          "--concurrent"
          "5"
          "mitac"
        ];
        labels = {
          "com.centurylinklabs.watchtower.enable" = "true";
        };
        extraOptions = [ "--network=container:ts-ubuntu-at-exit" ];
        dependsOn = [ "ts-ubuntu-at-exit" ];
      };

      watchtower = {
        image = "nickfedor/watchtower";
        cmd = [
          "--label-enable"
          "--cleanup"
          "--interval"
          "3600"
          "--include-restarting"
        ];
        volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ];
        labels = {
          "com.centurylinklabs.watchtower" = "true";
        };
      };

      # TODO: Encrypt SLOWLINK_PSK=... (from ~/slowflow-vpn/psk) into
      # secrets/ubuntu-zstdvpn-env.age (`secrets edit ubuntu-zstdvpn-env`) and
      # verify the exact `-tls-auto ...` flags from live `docker inspect zstdvpn-server`.
      zstdvpn-server = {
        image = "alpine:3.20";
        privileged = true;
        capabilities = {
          NET_ADMIN = true;
        };
        devices = [ "/dev/net/tun:/dev/net/tun" ];
        extraOptions = [ "--network=host" ];
        volumes = [
          "/home/mitac/slowflow-vpn/bin/zstdvpn-server:/usr/local/bin/zstdvpn-server:ro"
          "/home/mitac/slowflow-vpn/scripts/nat-up.sh:/nat-up.sh:ro"
        ];
        environmentFiles = [ zstdvpnEnvPath ];
        cmd = [
          "sh"
          "-c"
          ''apk add --no-cache iptables iproute2 && zstdvpn-server -listen 0.0.0.0:44123 -psk "$SLOWLINK_PSK" -tls-auto & pid=$!; sleep 2; sh /nat-up.sh sl0 enp3s0; wait "$pid"''
        ];
      };

      # Stopped on live host (Exited 130); keep on-demand only.
      archiveteam-warrior = {
        image = "atdr.meo.ws/archiveteam/warrior-dockerfile";
        ports = [ "8001:8001" ];
        autoStart = false;
      };
    };
  };

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
  # Restored home-directory services & on-demand Minecraft instances
  # (User=mitac, matching live ~/.config/systemd/user/ units verbatim; guarded
  # with ConditionPathExists so first boot stays clean before /home/mitac restore)
  # ---------------------------------------------------------------------------
  systemd.services = {
    # Hermes Agent gateway (live unit: ~/.config/systemd/user/hermes-gateway.service)
    # TODO: Hermes auth/API secrets live outside the unit under /home/mitac/.hermes/
    # (.env, auth.json) — restore from backup or migrate to agenix.
    hermes-gateway = {
      description = "Hermes Agent Gateway - Messaging Platform Integration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        StartLimitIntervalSec = 0;
        ConditionPathExists = "/home/mitac/.hermes/hermes-agent/.hermes/bin/hermes";
      };
      serviceConfig = {
        Type = "simple";
        User = "mitac";
        Group = "users";
        WorkingDirectory = "/home/mitac/.hermes";
        Environment = [
          "HOME=/home/mitac"
          "PATH=/home/mitac/.hermes/hermes-agent/node_modules/.bin:/home/mitac/.hermes/tools/node-26.12.1-linux-x64/bin:/home/mitac/.hermes/tools/npm-12.2.2-linux-x64/bin:/home/mitac/.local/bin:/run/current-system/sw/bin"
          "HERMES_HOME=/home/mitac/.hermes"
          "HERMES_SUPERVISED_CHILD=1"
        ];
        ExecStart = ''"/home/mitac/.hermes/hermes-agent/.hermes/bin/hermes" "gateway" "run"'';
        Restart = "always";
        RestartSec = 5;
        RestartForceExitStatus = 75;
        SuccessExitStatus = 75;
        RestartPreventExitStatus = 78;
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
        ExecStop = ''-"/home/mitac/.hermes/hermes-agent/.hermes/bin/hermes" "--run-module" "gateway.systemd_stop_mark"'';
        ExecStopPost = ''-"/home/mitac/.hermes/hermes-agent/.hermes/bin/hermes" "--run-module" "gateway.cgroup_cleanup"'';
        TimeoutStopSec = 70;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # siesta-bot (Python venv under ~/siesta-bot, NOT Docker — live unit: siesta-bot.service)
    # TODO: Discord bot token lives outside the unit under /home/mitac/siesta-bot/
    # (.env) — restore from backup or migrate to agenix.
    siesta-bot = {
      description = "シエスタ公国 Discord Bot";
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
          "PYTHONUNBUFFERED=1"
          "PATH=/home/mitac/siesta-bot/.venv/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "/home/mitac/siesta-bot/.venv/bin/python bot.py";
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

    # lecture-asr (venv at ~/.local/share/lecture-asr/venv, ~/lectures/bin/lecture_asr.py)
    # TODO: Gemini API key lives outside the unit (~/.config/lecture-asr/gemini.env)
    # — restore from backup or migrate to agenix.
    lecture-asr = {
      description = "Ingest + transcribe lecture audio (~/lectures)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        StartLimitIntervalSec = 0;
        ConditionPathExists = "/home/mitac/.local/share/lecture-asr/venv/bin/python";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "mitac";
        Group = "users";
        # Wait so the sidecar + audio of one upload are handled in a single run.
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 30";
        ExecStart = "/home/mitac/.local/share/lecture-asr/venv/bin/python /home/mitac/lectures/bin/lecture_asr.py run";
        Nice = 15;
        CPUWeight = 20;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "12h";
        Environment = [
          "HOME=/home/mitac"
          "HF_HUB_OFFLINE=0"
          "OMP_NUM_THREADS=4"
          "PATH=/home/mitac/.local/bin:/run/current-system/sw/bin"
        ];
      };
    };

    # lecture-publish (hourly timer only; no lecture-publish.path on live machine)
    # TODO: Any publish/git credentials used by publish-transcripts.sh live outside
    # the unit — restore from backup or manage via agenix.
    lecture-publish = {
      description = "Push lecture transcripts to Teiki-Test (retry)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        ConditionPathExists = "/home/mitac/lectures/bin/publish-transcripts.sh";
      };
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.git
        pkgs.gh
        pkgs.openssh
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "mitac";
        Group = "users";
        Environment = [
          "HOME=/home/mitac"
          "PATH=/home/mitac/.local/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "/home/mitac/lectures/bin/publish-transcripts.sh";
        Nice = 10;
      };
    };

    # ZNC Tailscale certificate renewal (replaces user cron `17 4 1 * *` UTC = 13:17 JST)
    znc-tailscale-cert = {
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

    # Wait for restored home data / Tailscale / agenix secrets before starting
    # OCI containers that bind host paths, Tailscale IPs, or secret env files.
    docker-znc = {
      after = [ "tailscaled.service" ];
      unitConfig.ConditionPathExists = "/home/mitac/znc";
    };
    docker-ts-ubuntu-at-exit = {
      unitConfig.ConditionPathExists = "/home/mitac/ts-ubuntu-at-exit/entrypoint.sh";
    };
    docker-zstdvpn-server = {
      unitConfig.ConditionPathExists = [
        "/home/mitac/slowflow-vpn/bin/zstdvpn-server"
        zstdvpnEnvPath
      ];
    };

    # Generic Minecraft template (empty wantedBy: never started at boot).
    # Concrete units for all 6 live instances (ATM10, ATM9-Eureka, latest-vanila,
    # mohist-1.20.1, paper-1.21.11, yower-1.21.1) are merged right below.
    "minecraft@" = {
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
        ExecStart = "${minecraftRunner} %i";
        SuccessExitStatus = [
          0
          143
        ];
        TimeoutStopSec = 60;
        Restart = "no";
      };
    };
  }
  // lib.mapAttrs' (name: spec: {
    name = "minecraft@${name}";
    value = mkMinecraftUnit name spec;
  }) minecraftInstanceSpecs;

  systemd.paths.lecture-asr = {
    description = "Start transcription when lecture audio arrives in ~/lectures/inbox";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/home/mitac/lectures/inbox";
    };
    pathConfig = {
      PathChanged = "/home/mitac/lectures/inbox";
      Unit = "lecture-asr.service";
    };
  };

  systemd.timers = {
    lecture-asr = {
      description = "Fallback: check for untranscribed lectures every 30 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "30min";
        Unit = "lecture-asr.service";
      };
    };

    lecture-publish = {
      description = "Hourly retry of lecture transcript push";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = 300;
        Persistent = true;
        Unit = "lecture-publish.service";
      };
    };

    znc-tailscale-cert = {
      description = "Monthly ZNC Tailscale certificate renewal";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 13:17:00";
        Persistent = true;
        Unit = "znc-tailscale-cert.service";
      };
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
    screen
    htop
    unzip
    zip
    lsof
    psmisc
    gcc
    gnumake
    pkg-config
    docker-compose
    rsync
    rrsync
  ];
}
