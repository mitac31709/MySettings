# GMKtec NucBox G3 (Intel N100) headless home server host configuration.
{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/ubuntu.nix
    ../../modules/nixos/backup.nix
    ../../modules/nixos/release.nix
  ];

  # Match the NixOS release from the first install on this machine.
  system.stateVersion = "26.05";
}
