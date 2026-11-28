# NetworkManager (wired & Wi-Fi 802.1x PEAP/MSCHAPv2 via agenix),
# povo WWAN (Prolific NCXX UX302NC via ModemManager + udev + bind/regwatch),
# Tailscale exit node, and IP forwarding / conntrack sysctls.
{ pkgs, ... }:

let
  # Live /usr/local/sbin/ux302nc-bind.sh (UX302NC 11f6:1034: serial ports -> option, interface 3 -> qmi_wwan).
  ux302ncBindScript = pkgs.writeShellScript "ux302nc-bind.sh" ''
    # UX302NC (11f6:1034): serial ports -> option, interface 3 -> qmi_wwan
    DEV="$1"   # e.g. 3-1
    modprobe option; modprobe qmi_wwan
    grep -q "11f6 1034" /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || echo "11f6 1034" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || true
    sleep 2
    IF="''${DEV}:1.3"
    if [ -e "/sys/bus/usb/drivers/option/$IF" ]; then echo "$IF" > /sys/bus/usb/drivers/option/unbind; fi
    grep -q "11f6 1034" /sys/bus/usb/drivers/qmi_wwan/new_id 2>/dev/null || echo "11f6 1034" > /sys/bus/usb/drivers/qmi_wwan/new_id 2>/dev/null || true
    sleep 1
    [ -e "/sys/bus/usb/drivers/qmi_wwan/$IF" ] || echo "$IF" > /sys/bus/usb/drivers/qmi_wwan/bind 2>/dev/null || true
    if [ -e "/sys/bus/usb/drivers/qmi_wwan/$IF" ]; then logger -t ux302nc "bound $IF to qmi_wwan"; else logger -t ux302nc "FAILED to bind $IF to qmi_wwan"; fi
    sleep 1; systemctl restart ModemManager
  '';

  # Live /usr/local/sbin/ux302nc-regwatch.sh (steer unregistered UX302NC to povo PLMN 44051 then back to automatic).
  ux302ncRegwatchScript = pkgs.writeShellScript "ux302nc-regwatch.sh" ''
    # If not registered, steer to povo PLMN 44051 then back to automatic
    for i in $(seq 1 20); do
      sleep 15
      D=$(ls /dev/cdc-wdm* 2>/dev/null | head -1); [ -n "$D" ] || continue
      if qmicli -p -d "$D" --nas-get-serving-system 2>/dev/null | grep -q "Registration state: .registered."; then exit 0; fi
      if [ "$i" -ge 4 ]; then
        logger -t ux302nc "not registered, forcing PLMN 44051"
        qmicli -p -d "$D" --nas-set-system-selection-preference=lte,manual=44051 >/dev/null 2>&1
        sleep 30
        qmicli -p -d "$D" --nas-set-system-selection-preference=lte,automatic >/dev/null 2>&1
      fi
    done
  '';
in
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
        route-metric = 900;
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

  # Expose UX302NC helper scripts at their live paths under /usr/local/sbin.
  systemd.tmpfiles.rules = [
    "d /usr/local/sbin 0755 root root -"
    "L+ /usr/local/sbin/ux302nc-bind.sh - - - - ${ux302ncBindScript}"
    "L+ /usr/local/sbin/ux302nc-regwatch.sh - - - - ${ux302ncRegwatchScript}"
  ];

  # Matches live /etc/udev/rules.d/99-ux302nc.rules:
  #   - 11f6:1035 (storage mode) -> usb_modeswitch
  #   - 11f6:1034 (modem mode)   -> trigger ux302nc-bind@%k.service
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="11f6", ATTR{idProduct}=="1035", RUN+="${pkgs.usb-modeswitch}/bin/usb_modeswitch -v 11f6 -p 1035 -M 55534243123456780000000080000606f50402527000000000000000000000"
    ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="11f6", ATTR{idProduct}=="1034", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ux302nc-bind@%k.service"
  '';

  # Matches live /etc/systemd/system/ux302nc-bind@.service (no [Install]; triggered by udev).
  systemd.services."ux302nc-bind@" = {
    description = "Bind UX302NC interfaces (%i)";
    path = with pkgs; [
      coreutils
      gnugrep
      kmod
      systemd
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ux302ncBindScript} %i";
      ExecStartPost = "${pkgs.systemd}/bin/systemctl --no-block start ux302nc-regwatch.service";
    };
  };

  # Matches live /etc/systemd/system/ux302nc-regwatch.service (no [Install]; started by ux302nc-bind@).
  systemd.services.ux302nc-regwatch = {
    description = "UX302NC registration watchdog (povo 44051)";
    after = [ "ModemManager.service" ];
    path = with pkgs; [
      coreutils
      gnugrep
      libqmi
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ux302ncRegwatchScript}";
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
      "--accept-dns=false"
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
