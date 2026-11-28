# FreeWiFi Access Point (freeap0 @ 10.42.0.1/24 on USB TP-Link 2357:0138 rtw_8822bu)
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

  # Live /etc/usque/up.sh: install default route for table 142 via usque0 on connect/reconnect.
  usqueUpScript = pkgs.writeShellScript "usque-up.sh" ''
    ${pkgs.iproute2}/bin/ip route replace default dev "''${USQUE_IFACE:-usque0}" metric 10 table 142
  '';

  # Live /usr/local/sbin/freeap-count-notify.py with Nix store paths for iw and conntrack.
  # Reads `WEBHOOK=...` from /etc/freeap-notify.env (deployed from secrets/raspberrypi-freeap-notify-env.age).
  freeapCountNotifyScript = pkgs.writeScript "freeap-count-notify.py" (
    builtins.replaceStrings
      [
        "#!/usr/bin/env python3"
        ''"/usr/sbin/iw"''
        ''"/usr/sbin/conntrack"''
      ]
      [
        "#!${pkgs.python3}/bin/python3"
        ''"${pkgs.iw}/bin/iw"''
        ''"${pkgs.conntrack-tools}/bin/conntrack"''
      ]
      (builtins.readFile ./scripts/freeap-count-notify.py)
  );

  freeapPolicyScript = pkgs.writeShellScript "freeap-policy-setup" ''
    set -euo pipefail
    # Keep FreeAP's own subnet reachable in table `freeap` (142) (matches live freeap-policy.sh).
    ${pkgs.iproute2}/bin/ip route replace 10.42.0.0/24 dev freeap0 table freeap || true
    # Fail-closed fallback in table `freeap` (142): if usque0 goes down, clients get
    # unreachable instead of leaking onto campus eth0/wlan0 or tailscale0.
    ${pkgs.iproute2}/bin/ip route replace unreachable default metric 4000 table freeap
    if ${pkgs.iproute2}/bin/ip link show usque0 >/dev/null 2>&1; then
      ${pkgs.iproute2}/bin/ip route replace default dev usque0 metric 10 table freeap
    fi

    # Rule 99: keep local FreeAP subnet traffic (e.g. to 10.42.0.1 DHCP/DNS) on table main.
    ${pkgs.iproute2}/bin/ip rule del pref 99 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 99 from all to 10.42.0.0/24 iif freeap0 lookup main

    ${pkgs.iproute2}/bin/ip rule del pref 100 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 100 from 10.42.0.0/24 iif freeap0 lookup freeap

    ${pkgs.iproute2}/bin/ip rule del pref 101 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule add pref 101 from 172.16.0.2 lookup freeap
  '';

  freeapPolicyStopScript = pkgs.writeShellScript "freeap-policy-stop" ''
    ${pkgs.iproute2}/bin/ip rule del pref 100 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule del pref 99 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip rule del pref 101 2>/dev/null || true
    ${pkgs.iproute2}/bin/ip route flush table freeap 2>/dev/null || true
  '';
in
{
  # Pin the USB TP-Link 802.11ac adapter (USB 2357:0138, rtw_8822bu, MAC ac:15:a2:eb:82:ab) to `freeap0`.
  # Matches live /etc/systemd/network/10-freeap0.link.
  systemd.network.links."10-freeap0" = {
    matchConfig = {
      MACAddress = "ac:15:a2:eb:82:ab";
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

  # Exact match of live /etc/nftables.d/freeap-usque.nft (fail-closed forwarding + NAT masquerade).
  networking.nftables = {
    enable = true;
    tables.freeap_usque = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter - 10; policy accept;
          # fail-closed: AP clients may only leave via usque0 (or stay on freeap0)
          iifname "freeap0" oifname != { "usque0", "freeap0" } counter drop
          oifname "usque0" tcp flags syn tcp option maxseg size set rt mtu
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "usque0" ip saddr 10.42.0.0/24 counter masquerade
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

  # Declarative /etc/usque/up.sh matching the live Pi.
  environment.etc."usque/up.sh" = {
    source = usqueUpScript;
    mode = "0755";
  };

  # Ensure directories/files exist with proper ownership (dnsmasq drops to user `dnsmasq`)
  # and expose freeap-count-notify.py at /usr/local/sbin.
  systemd.tmpfiles.rules = [
    "d /etc/hostapd 0700 root root -"
    "d /etc/usque 0700 root root -"
    "d /usr/local/sbin 0755 root root -"
    "d /var/lib/freeap-notify 0750 root root -"
    "d /var/lib/misc 0755 dnsmasq dnsmasq -"
    "f /var/lib/misc/freeap.leases 0644 dnsmasq dnsmasq -"
    "f /var/log/freeap-dns.log 0644 dnsmasq dnsmasq -"
    "L+ /usr/local/sbin/freeap-count-notify.py - - - - ${freeapCountNotifyScript}"
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
    bindsTo = [ "sys-subsystem-net-devices-freeap0.device" ];
    after = [
      "network.target"
      "NetworkManager.service"
      "sys-subsystem-net-devices-freeap0.device"
      "freeap-interface.service"
    ];
    wants = [
      "freeap-interface.service"
      "dnsmasq.service"
    ];
    unitConfig = {
      ConditionPathExists = hostapdConfigPath;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.hostapd}/bin/hostapd ${hostapdConfigPath}";
      # Matches live freeap-hostapd.service: wait briefly then ensure table 142 has the local freeap0 route.
      ExecStartPost = pkgs.writeShellScript "freeap-hostapd-route" ''
        sleep 2
        ${pkgs.iproute2}/bin/ip route replace 10.42.0.0/24 dev freeap0 table 142 || true
      '';
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # DHCP (10.42.0.10-254, 60m lease) & DNS (10.42.0.1 -> 1.1.1.1 / 1.0.0.1 via usque0 src 172.16.0.2).
  # Matches live freeap-dnsmasq.service and /etc/NetworkManager/dnsmasq-shared.d/*.conf.
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    alwaysKeepRunning = true;
    settings = {
      interface = "freeap0";
      except-interface = "lo";
      listen-address = "10.42.0.1";
      bind-dynamic = true;
      no-hosts = true;
      clear-on-reload = true;
      strict-order = true;
      domain-needed = true;
      bogus-priv = true;
      no-resolv = true;
      dhcp-range = "10.42.0.10,10.42.0.254,255.255.255.0,60m";
      dhcp-leasefile = "/var/lib/misc/freeap.leases";
      log-facility = "/var/log/freeap-dns.log";
      log-async = true;
      log-queries = true;
      log-dhcp = true;
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
    bindsTo = [ "freeap-hostapd.service" ];
    after = [
      "freeap-interface.service"
      "freeap-policy.service"
      "freeap-hostapd.service"
    ];
    wants = [
      "freeap-interface.service"
      "freeap-policy.service"
    ];
  };

  # Rotate both FreeAP DNS and conntrack destroy logs (matches live /etc/logrotate.d/freeap-dns).
  services.logrotate.settings.freeap-dns = {
    files = [
      "/var/log/freeap-dns.log"
      "/var/lib/freeap-notify/destroy.log"
    ];
    frequency = "daily";
    rotate = 2;
    missingok = true;
    notifempty = true;
    copytruncate = true;
  };

  # Cloudflare WARP / MASQUE TUN upstream (usque0 @ 172.16.0.2/32), matching the live Pi flags.
  # Ordered after freeap-policy.service so fail-closed rules exist before usque connects.
  # TODO: Populate secrets/raspberrypi-usque-config.age (or restore /etc/usque/config.json).
  systemd.services.usque = {
    description = "Usque Cloudflare WARP/MASQUE TUN (usque0)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "freeap-policy.service"
    ];
    wants = [
      "network-online.target"
      "freeap-policy.service"
    ];
    unitConfig = {
      ConditionPathExists = usqueConfigPath;
    };
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/etc/usque";
      ExecStart = "${pkgs.usque}/bin/usque -c ${usqueConfigPath} nativetun --http2 -n usque0 -S --always-reconnect --on-connect /etc/usque/up.sh";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Policy routing rules (fail-closed table `freeap` = 142, rules 99/100/101).
  # Runs before usque.service (matching live freeap-policy.service).
  systemd.services.freeap-policy = {
    description = "FreeWiFi fail-closed policy routing (freeap0 -> usque0)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-pre.target"
      "freeap-interface.service"
    ];
    before = [ "usque.service" ];
    wants = [ "freeap-interface.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${freeapPolicyScript}";
      ExecStop = "${freeapPolicyStopScript}";
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
  # Reads `WEBHOOK=...` from /etc/freeap-notify.env (agenix placeholder: secrets/raspberrypi-freeap-notify-env.age).
  systemd.services.freeap-count-notify = {
    description = "FreeWiFi connected client count notifier";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      conntrack-tools
      curl
      iw
      python3
      systemd
    ];
    unitConfig = {
      ConditionPathExists = "/etc/freeap-notify.env";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${freeapCountNotifyScript}";
    };
  };

  systemd.timers.freeap-count-notify = {
    description = "Run FreeWiFi client count notifier every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      AccuracySec = "10s";
    };
  };

  environment.systemPackages = with pkgs; [
    hostapd
    usque
  ];
}
