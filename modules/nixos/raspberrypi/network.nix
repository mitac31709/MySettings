# NetworkManager (wired & Wi-Fi 802.1x PEAP/MSCHAPv2 via agenix),
# povo WWAN (Prolific NCXX UX302NC via ModemManager), Tailscale exit node,
# and IP forwarding / conntrack sysctls.
{ pkgs, ... }:

{
  networking.networkmanager = {
    enable = true;
    # Use wpa_supplicant (not iwd) for wired 802.1x and campus PEAP/MSCHAPv2 Wi-Fi
    # ("Wired connection 1", "Hazamaru AP-tr", "eduroam").
    wifi.backend = "wpa_supplicant";

    # Keep FreeWiFi AP and WARP TUN interfaces out of NetworkManager
    # (matches /etc/NetworkManager/conf.d/99-unmanaged-usque0.conf).
    unmanaged = [
      "interface-name:usque0"
      "interface-name:freeap0"
      "interface-name:wlan1"
    ];

    # Declarative non-secret GSM profile for povo (UX302NC WWAN).
    # 802.1x profiles (Wired connection 1, Hazamaru AP-tr, eduroam) are deployed
    # from agenix secret `secrets/raspberrypi-nm-connections.age` (see secrets.nix).
    ensureProfiles.profiles.povo = {
      connection = {
        id = "povo";
        type = "gsm";
        autoconnect = true;
      };
      gsm = {
        apn = "povo.jp";
      };
      ipv4 = {
        method = "auto";
        route-metric = 800;
      };
      ipv6 = {
        method = "auto";
      };
    };
  };

  # Avoid dropping networking mid-switch if a rebuild fails.
  systemd.services.NetworkManager = {
    wantedBy = [ "multi-user.target" ];
    stopIfChanged = false;
  };

  # Prolific NCXX UX302NC WWAN (povo.jp) via ModemManager + usb-modeswitch.
  networking.modemmanager.enable = true;
  hardware.usb-modeswitch.enable = true;

  environment.systemPackages = with pkgs; [
    libqmi
    modemmanager
    usb-modeswitch
  ];

  # Bind Prolific NCXX UX302NC USB modem via ux302nc-bind@.service on attach.
  # TODO: Compare with /etc/udev/rules.d/99-ux302nc.rules on the live Pi to pin the exact
  # idVendor/idProduct and any modeswitch action if different.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTRS{product}=="*UX302NC*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ux302nc-bind@%k.service"
  '';

  # TODO: Verify exact script path/args from /etc/systemd/system/ux302nc-bind@.service on the live Pi.
  systemd.services."ux302nc-bind@" = {
    description = "Bind Prolific NCXX UX302NC modem (%I)";
    after = [ "ModemManager.service" ];
    path = with pkgs; [
      bash
      coreutils
      kmod
      libqmi
      modemmanager
      usb-modeswitch
    ];
    unitConfig = {
      ConditionPathExists = "/usr/local/sbin/ux302nc-bind.sh";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/usr/local/sbin/ux302nc-bind.sh %i";
    };
  };

  # Matches live Pi unit type (oneshot).
  # TODO: Verify exact script path/trigger (boot vs timer) from /etc/systemd/system/ux302nc-regwatch.service on the live Pi.
  systemd.services.ux302nc-regwatch = {
    description = "Watch UX302NC cellular registration (povo WWAN)";
    after = [
      "ModemManager.service"
      "NetworkManager.service"
    ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [
      bash
      coreutils
      modemmanager
      networkmanager
    ];
    unitConfig = {
      ConditionPathExists = "/usr/local/sbin/ux302nc-regwatch.sh";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/usr/local/sbin/ux302nc-regwatch.sh";
    };
  };

  # Tailscale exit node.
  # Existing node identity in /var/lib/tailscale is restored after install, so no authKeyFile is used.
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    openFirewall = true;
    extraSetFlags = [
      "--operator=mitac"
      "--advertise-exit-node"
    ];
  };

  # Trust tailscale0 so SSH, ntopng, code-server (if forwarded), iperf3, etc. traverse Tailscale cleanly.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Kernel sysctls from inventory section 7 (99-ipforward.conf, 99-tailscale.conf, 90-conntrack-acct.conf).
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.netfilter.nf_conntrack_acct" = 1;
  };
}
