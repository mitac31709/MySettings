# Declarative disk layout for GMKtec NucBox G3 (single 256GB Apacer NVMe, UEFI).
# Used by nixos-anywhere + disko: GPT, 1G vfat ESP at /boot, btrfs root with
# zstd:1 compression (matching other hosts), and a 4G swapfile subvolume.
{ ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";
      # TODO: Optionally replace /dev/nvme0n1 with the exact /dev/disk/by-id/nvme-Apacer_...
      # path before adding a second NVMe drive.
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            name = "ESP";
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [
                "-f"
                "-L"
                "nixos"
              ];
              subvolumes = {
                "/@" = {
                  mountpoint = "/";
                  mountOptions = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                };
                "/@home" = {
                  mountpoint = "/home";
                  mountOptions = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                };
                "/@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                };
                "/@log" = {
                  mountpoint = "/var/log";
                  mountOptions = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                };
                "/@swap" = {
                  mountpoint = "/.swapvol";
                  mountOptions = [ "noatime" ];
                  swap.swapfile.size = "4G";
                };
              };
            };
          };
        };
      };
    };
  };
}
