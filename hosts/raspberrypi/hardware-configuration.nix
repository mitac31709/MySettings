# Raspberry Pi 5 SD card (mmcblk0, 28.8GB) hardware & storage layout.
# Uses the partition layout recommended by nvmd/nixos-raspberrypi's SD image:
#   - /boot/firmware: vfat (LABEL=FIRMWARE, 1GiB on sd-image)
#   - /:              ext4 (LABEL=NIXOS_SD, auto-expanded on first boot)
# Marked lib.mkDefault so nixos-raspberrypi's sd-image module can compose cleanly.
{ lib, ... }:

{
  # Recommended generational bootloader for Raspberry Pi 5 SD installations.
  boot.loader.raspberry-pi.bootloader = "kernel";

  fileSystems."/boot/firmware" = {
    device = lib.mkDefault "/dev/disk/by-label/FIRMWARE";
    fsType = lib.mkDefault "vfat";
    options = lib.mkDefault [
      "noatime"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
    ];
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
    fsType = lib.mkDefault "ext4";
    options = lib.mkDefault [ "noatime" ];
  };

  # Match Raspberry Pi OS /etc/dphys-swapfile (CONF_SWAPSIZE=512).
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 512;
    }
  ];

  # Keep Japanese wireless regulatory domain (from /boot/firmware/cmdline.txt).
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=JP" ];

  # Load i2c-dev (from /etc/modules) and nf_conntrack (for freeap-flowlog / acct).
  boot.kernelModules = [
    "i2c-dev"
    "nf_conntrack"
  ];

  hardware = {
    enableRedistributableFirmware = true;
    wirelessRegulatoryDatabase = true;
    i2c.enable = true;
  };

  # Ensure unfree firmware/packages (e.g. Raspberry Pi wireless firmware) evaluate cleanly.
  nixpkgs.config.allowUnfree = true;
}
