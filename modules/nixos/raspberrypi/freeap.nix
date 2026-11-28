# FreeWiFi Access Point (freeap0 @ 10.42.0.1/24 on USB TP-Link rtw_8822bu)
# with hostapd, dnsmasq, Cloudflare WARP/MASQUE upstream (usque0 @ 172.16.0.2/32),
# fail-closed policy routing (table 142), nftables NAT, conntrack flowlog, and client-count notifier.
{
  config,
  pkgs,
  ...
}:

let
  hasHostapdSecret = config.age.secrets ? "raspberrypi-freeap-hostapd";
  hostapdConfigPath =
    if hasHostapdSecret then
      config.age.secrets."raspberrypi-freeap-hostapd".path
    else
      "/etc/hostapd/freeap.conf";

  hasUsqueSecret = config.age.secrets ? "raspberrypi-usque-config";
  usqueConfigPath =
    if hasUsqueSecret then
      config.age.secrets."raspberrypi-usque-config".path
    else
      "/etc/usque/config.json";

  hasNotifySecret = config.age.secrets ? "raspberrypi-freeap-notify-env";
  notifyEnvFile =
    if hasNotifySecret then
      config.age.secrets."raspberrypi-freeap-notify-env".path
    else
      "-/etc/freeap-notify.env";

  # Invoked by usque `--on-connect`. Runs restored /etc/usque/up.sh if present
  # (via nixpkgs bash so #!/bin/bash scripts work on NixOS), otherwise brings up
  # usque0 with 172.16.0.2/32 and routes table `freeap` (142) through it.
  usqueOnConnect = pkgs.writeShellScript "usque-on-connect" ''
    set -euo pipefail
    if [ -f /etc/usque/up.sh ]; then
      exec ${pkgs.bash}/bin/bash /etc/usque/up.sh "$@"
    fi
    ${pkgs.iproute2}/bin/ip addr replace 172.16.0.2/32 dev usque0
    ${pkgs.iproute2}/bin/ip link set usque0 up
    ${pkgs.iproute2}/bin/ip route replace default dev usque0 table freeap
  '';

  freeapPolicyScript = pkgs.writeShellScript "freeap-policy-setup" ''
    set -euo pipefail
    # Fail-closed fallback in table `freeap` (142): if usque0 goes down, clients get
    # unreachable instead of leaking onto campus eth0/wlan0 or tailscale0.
    ${pkgs.iproute2}/bin/ip route replace unreachable default metric 4294967295 table freeap
    if ${pkgs.iproute2}/bin/ip link show usque0 >/dev/null 2>&1; then
      ${pkgs.iproute2}/bin/ip route replace default dev usque0 table freeap
    fi

    # Rule 99: keep local FreeAP subnet traffic (e.g. to 10.42.0.1 DHCP/DNS) on table main.
    ${pkgs.iproute2}/bin/ip rule del pref 99 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 99 from all to 10.42.0.0/24 iif freeap0 lookup main

    ${pkgs.iproute2}/bin/ip rule del pref 100 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 100 from 10.42.0.0/24 iif freeap0 lookup freeap

    ${pkgs.iproute2}/bin/ip rule del pref 101 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 101 from 172.16.0.2 lookup freeap
  '';
in
{
  # Pin the USB TP-Link 802.11ac adapter (rtw_8822bu) to interface name `freeap0`.
  systemd.network.links."10-freeap0" = {
    matchConfig = {
      Driver = "rtw_8822bu";
      # TODO: Pin MACAddress = "xx:xx:xx:xx:xx:xx"; from the live Pi's TP-Link USB adapter.
    };
    linkConfig = {
      Name = "freeap0";
    };
  };

  # Routing table `freeap` = 142 (matches /etc/iproute2/rt_tables.d/freeap.conf on the live Pi).
  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = ''
      142 freeap
    '';
  };

  # nftables NAT + fail-closed forwarding for FreeWiFi -> usque0
  # (replaces /etc/nftables.d/freeap-usque.nft).
  # TODO: Compare with /etc/nftables.d/freeap-usque.nft on the live Pi (root)
  # to confirm any extra MSS clamping or client-isolation rules.
  networking.nftables = {
    enable = true;
    tables.freeap-usque = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter - 5; policy accept;
          iifname "freeap0" oifname "usque0" tcp flags syn tcp option maxseg size set rt mtu
          iifname "freeap0" oifname "usque0" accept
          iifname "usque0" oifname "freeap0" ct state established,related accept
          # Fail-closed: never allow FreeAP clients to forward to eth0, wlan0, wwan0, or tailscale0.
          iifname "freeap0" drop
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr 10.42.0.0/24 oifname "usque0" masquerade
        }
      '';
    };
  };

  # Allow FreeAP clients to reach local DHCP and DNS on freeap0 (10.42.0.1).
  networking.firewall.interfaces.freeap0 = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [
      53
      67
      68
    ];
  };

  # Ensure directories exist for restored scripts/configs/state.
  systemd.tmpfiles.rules = [
    "d /etc/hostapd 0700 root root -"
    "d /etc/usque 0700 root root -"
    "d /var/lib/freeap-notify 0750 root root -"
  ];

  # Assign 10.42.0.1/24 on freeap0 (since freeap0 is unmanaged by NetworkManager).
  systemd.services.freeap-interface = {
    description = "Configure static IP 10.42.0.1/24 on freeap0";
    wantedBy = [ "multi-user.target" ];
    after = [ "sys-subsystem-net-devices-freeap0.device" ];
    wants = [ "sys-subsystem-net-devices-freeap0.device" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "freeap-interface-up" ''
        set -euo pipefail
        ${pkgs.iproute2}/bin/ip addr replace 10.42.0.1/24 dev freeap0
        ${pkgs.iproute2}/bin/ip link set freeap0 up
      '';
    };
  };

  # Keep stock hostapd disabled (just as hostapd.service is masked on Pi OS).
  services.hostapd.enable = false;

  # Custom freeap-hostapd reading SSID & passphrase from agenix (or /etc/hostapd/freeap.conf).
  # TODO: Populate secrets/raspberrypi-freeap-hostapd.age with /etc/hostapd/freeap.conf
  # (interface=freeap0, hw_mode=a, channel=36, country_code=JP, WPA2, SSID, passphrase).
  systemd.services.freeap-hostapd = {
    description = "FreeWiFi Access Point (hostapd on freeap0)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "freeap-interface.service"
    ];
    wants = [ "freeap-interface.service" ];
    unitConfig = {
      ConditionPathExists = hostapdConfigPath;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hostapd}/bin/hostapd ${hostapdConfigPath}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # DHCP (10.42.0.10-254, 60m lease) & DNS (10.42.0.1 -> 1.1.1.1 / 1.0.0.1 via usque0 src 172.16.0.2).
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    alwaysKeepRunning = true;
    settings = {
      interface = "freeap0";
      listen-address = "10.42.0.1";
      bind-dynamic = true;
      domain-needed = true;
      bogus-priv = true;
      no-resolv = true;
      dhcp-range = "10.42.0.10,10.42.0.254,255.255.255.0,60m";
      dhcp-option = [
        "option:router,10.42.0.1"
        "option:dns-server,10.42.0.1"
      ];
      server = [
        "1.1.1.1@172.16.0.2"
        "1.0.0.1@172.16.0.2"
      ];
    };
  };

  systemd.services.dnsmasq = {
    aliases = [ "freeap-dnsmasq.service" ];
    after = [
      "freeap-interface.service"
      "freeap-policy.service"
    ];
    wants = [
      "freeap-interface.service"
      "freeap-policy.service"
    ];
  };

  # Cloudflare WARP / MASQUE TUN upstream (usque0 @ 172.16.0.2/32), matching the live Pi flags.
  # TODO: Populate secrets/raspberrypi-usque-config.age (or restore /etc/usque/config.json)
  # and restore /etc/usque/up.sh if custom post-connect commands are needed beyond the default helper.
  systemd.services.usque = {
    description = "Usque Cloudflare WARP/MASQUE TUN (usque0)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      coreutils
      iproute2
      nftables
    ];
    unitConfig = {
      ConditionPathExists = usqueConfigPath;
    };
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/etc/usque";
      ExecStart = "${pkgs.usque}/bin/usque -c ${usqueConfigPath} nativetun --http2 -n usque0 -S --always-reconnect --on-connect ${usqueOnConnect}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Policy routing rules (fail-closed table `freeap` = 142, rules 99/100/101).
  systemd.services.freeap-policy = {
    description = "FreeWiFi fail-closed policy routing (freeap0 -> usque0)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "freeap-interface.service"
      "usque.service"
    ];
    wants = [
      "network-online.target"
      "freeap-interface.service"
      "usque.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${freeapPolicyScript}";
    };
  };

  # Log conntrack DESTROY events for FreeAP traffic auditing (matches live Pi args & log path).
  systemd.services.freeap-flowlog = {
    description = "FreeWiFi conntrack DESTROY flow logger";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.conntrack-tools}/bin/conntrack -E -e DESTROY -s 10.42.0.0/24 -o id,extended";
      StandardOutput = "append:/var/lib/freeap-notify/destroy.log";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Periodic FreeAP client-count notifier (every minute, matching live Pi timer).
  # TODO: Populate secrets/raspberrypi-freeap-notify-env.age and restore /usr/local/sbin/freeap-count-notify.py.
  systemd.services.freeap-count-notify = {
    description = "FreeWiFi connected client count notifier";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      iw
      python3
    ];
    unitConfig = {
      ConditionPathExists = "/usr/local/sbin/freeap-count-notify.py";
    };
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = notifyEnvFile;
      ExecStart = "${pkgs.python3}/bin/python3 /usr/local/sbin/freeap-count-notify.py";
    };
  };

  systemd.timers.freeap-count-notify = {
    description = "Run FreeWiFi client count notifier every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
    };
  };

  environment.systemPackages = with pkgs; [
    hostapd
    usque
  ];
}
