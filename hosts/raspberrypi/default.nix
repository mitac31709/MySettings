# Raspberry Pi 5 (8GB, aarch64) headless server configuration.
# Built with nvmd/nixos-raspberrypi for the current 28.8GB SD card (mmcblk0).
{
  config,
  inputs,
  nixos-raspberrypi,
  ...
}:

{
  imports = [
    nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    ./hardware-configuration.nix
    ../../modules/nixos/raspberrypi
  ];

  # Link generations to git commits (`nixos-version --json`).
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or "dirty";

  # Generation label showing RPi5 variant, bootloader, and vendor kernel version.
  system.nixos.tags =
    let
      cfg = config.boot.loader.raspberry-pi;
    in
    [
      "raspberry-pi-${cfg.variant}"
      cfg.bootloader
      config.boot.kernelPackages.kernel.version
    ];

  # Match nixos-raspberrypi's NixOS 26.05 base release.
  system.stateVersion = "26.05";
}
