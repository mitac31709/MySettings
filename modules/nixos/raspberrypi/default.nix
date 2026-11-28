# Headless Raspberry Pi 5 server profile (no desktop, no lightdm, no rpi-connect, no CUPS).
{
  lib,
  pkgs,
  flakeTarget ? "raspberrypi",
  ...
}:

{
  imports = [
    ./users.nix
    ./secrets.nix
    ./network.nix
    ./freeap.nix
    ./lecture.nix
    ./campus-apload.nix
    ./monitoring.nix
    ./shimesaba.nix
  ];

  networking.hostName = lib.mkDefault flakeTarget;

  time.timeZone = "Asia/Tokyo";
  # Matches live /etc/systemd/timesyncd.conf.d/10-campus-ntp.conf.
  services.timesyncd = {
    enable = true;
    servers = [
      "ntp.tokyo-ct.ac.jp"
      "172.20.0.19"
      "172.20.0.18"
    ];
    fallbackServers = [
      "time.google.com"
      "ntp.nict.jp"
    ];
  };

  # Match existing Raspberry Pi OS locale while keeping UTF-8 Japanese available
  # for matplotlib graph rendering (campus-apload-final).
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.supportedLocales = [
    "C.UTF-8/UTF-8"
    "en_GB.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "ja_JP.UTF-8/UTF-8"
  ];

  # Server-only: disable desktop, display managers, printing, Bluetooth, Avahi.
  services.xserver.enable = false;
  services.printing.enable = false;
  services.avahi.enable = false;
  hardware.bluetooth.enable = false;

  # Cap journald disk usage (the 28.8GB SD card previously accumulated ~2.1GB of journals).
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    RuntimeMaxUse=50M
  '';

  # Japanese font for matplotlib charts (campus-apload-final).
  fonts.packages = [ pkgs.noto-fonts-cjk-sans ];

  # TODO: If /usr/local/share/ca-certificates/burp-ca.crt is still needed,
  # copy it into this repo (or deploy via agenix) and add it to:
  # security.pki.certificateFiles = [ ./burp-ca.crt ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    rsync
    btop
    htop
    gh
    tmux
    screen
    tree
    ncdu
    strace
    inetutils # telnet
    unzip
    zip
    wakeonlan
    speedtest-cli
    jq
    iperf3
    iw
    ethtool
    usbutils
    pciutils
    i2c-tools
    conntrack-tools
    tcpdump
    alsa-utils
    ffmpeg
    python3
  ];
}
