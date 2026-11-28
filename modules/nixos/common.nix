# Shared NixOS base across all hosts (desktops and headless servers).
# Desktop-only settings (NetworkManager, Fcitx5/Meltype, fonts, kmscon, WARP,
# Steam, VirtualBox, Podman, WhatPulse, LocalSend, desktop firewall) live in
# modules/nixos/desktop.nix.
{
  config,
  pkgs,
  lib,
  flakeTarget ? "chromebook",
  ...
}:
let
  hasBtrfs = lib.any (fs: (fs.fsType or null) == "btrfs") (lib.attrValues config.fileSystems);
in
{
  imports = [
    ./secrets.nix
  ];

  boot.loader.limine = {
    enable = true;
    efiSupport = true;
    # Keep the latest 10 generations in the boot menu (and cap ESP usage).
    # Limine renders its own framebuffer menu instead of relying on UEFI
    # SimpleTextOutput/SimpleTextInputEx, avoiding the multi-second arrow-key
    # stalls seen with systemd-boot on Phoenix UEFI (VAIO).
    maxGenerations = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable monthly scrub automatically once a host's hardware-configuration uses btrfs.
  services.btrfs.autoScrub = lib.mkIf hasBtrfs {
    enable = true;
    interval = "monthly";
  };

  # Live systemd job tree on the boot console (flake input `bootvine`).
  # This nixpkgs pin is NixOS 26.11, where the initrd is systemd-only, so the
  # module covers the initrd without boot.initrd.systemd.enable (removed).
  services.bootvine.enable = lib.mkDefault true;

  # Distinct per-host hostname (chromebook / vaio / ubuntu) avoids Avahi/mDNS,
  # Tailscale, RQuickShare, and Chromium SingletonLock collisions across machines.
  networking.hostName = lib.mkDefault flakeTarget;

  # Prefer reclaiming user/session memory under pressure before the whole machine
  # thrashing (8 GiB Chromebook + browsers).
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
  };

  # Cap journald disk use so logs cannot grow without bound.
  services.journald.settings.Journal = {
    SystemMaxUse = "1G";
    RuntimeMaxUse = "100M";
  };

  time.timeZone = "Asia/Tokyo";
  # Chromebook RTC can wake in the past (seen as 2024-01-24) until NTP lands;
  # TLS then fails with "certificate is not yet valid". Keep timesyncd on.
  services.timesyncd.enable = true;

  # Allow wheel users to trigger an immediate NTP resync (via `ntp-sync` /
  # cheatsheet) without granting broader unit control.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "systemd-timesyncd.service" &&
          action.lookup("verb") == "restart" &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';

  i18n.defaultLocale = lib.mkDefault "ja_JP.UTF-8";
  i18n.extraLocaleSettings = lib.mkDefault {
    LC_ADDRESS = "ja_JP.UTF-8";
    LC_IDENTIFICATION = "ja_JP.UTF-8";
    LC_MEASUREMENT = "ja_JP.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8";
    LC_NAME = "ja_JP.UTF-8";
    LC_NUMERIC = "ja_JP.UTF-8";
    LC_PAPER = "ja_JP.UTF-8";
    LC_TELEPHONE = "ja_JP.UTF-8";
    LC_TIME = "ja_JP.UTF-8";
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Affinity is not installed (input and overlay removed; see README).
    # Do not hard-depend on cache.forall.systems — a wrong RTC before NTP
    # makes every fetch fail with SSL "certificate is not yet valid", and
    # misses also stall rebuild. When re-enabling affinity-v3, restore:
    #   extra-substituters = [ "https://cache.forall.systems" ];
    #   extra-trusted-public-keys = [
    #     "cache.forall.systems:5PmD7QO4MSF8YgyRZtkSGXRDo96H3bybIf2SsQh8ScI="
    #   ];
  };

  users.users.mitac = {
    isNormalUser = true;
    description = "mitac";
    # Keep systemd --user (default.target services) running from boot before graphical login
    linger = true;
    extraGroups = [
      "wheel"
      "systemd-journal" # restic backup notify reads unit logs for progress/summary
    ];
    # Set a password after first boot: passwd mitac
  };

  environment.systemPackages =
    with pkgs;
    [
      # git and vim stay on the system profile for root and recovery shells.
      # sudo's secure_path is /run/current-system/sw/bin and does not include
      # the user Home Manager profile. programs.git (home/programs.nix) is the
      # user's git, with name and email; this package is the unconfigured one.
      vim
      git
      wget
      curl
      iperf3 # LAN / WAN bandwidth test (server: -s, client: -c HOST)
    ]
    ++ lib.optionals hasBtrfs [ compsize ];

  # Tailscale daemon; Trayscale (GUI) is in home.packages on desktop hosts.
  # --operator lets the login user run `tailscale file get` (Taildrop) and
  # `tailscale up/down/set` without sudo. Mirror it in extraUpFlags so
  # `tailscaled-autoconnect.service` (driven by services.tailscale.authKeyFile)
  # does not fail when reconciling non-default flags on `tailscale up`.
  services.tailscale = {
    enable = true;
    extraSetFlags = lib.mkDefault [ "--operator=mitac" ];
    extraUpFlags = lib.mkDefault [ "--operator=mitac" ];
  };

  hardware.enableRedistributableFirmware = true;

  # Pre-populate verified SSH host public keys in /etc/ssh/ssh_known_hosts
  # so clients don't rely solely on mutable ~/.ssh/known_hosts.
  programs.ssh.knownHosts =
    let
      knownHostSpecs = {
        galleria-mitac-wsl = {
          hostNames = [
            "[galleria-mitac]:2222"
            "[100.102.102.53]:2222"
          ];
          keys = {
            ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID+Dgx7oDIHOa5CPTkDbeGqIjGsCf2evYSI/pRIjz7H0";
            ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFLPfYzIfOIyrYtT8tObRvQO1vb/XMCTkcNUs4PnviQ4iVJ6BRxLScfMAYikqlyeVTcCzNEy+FQ3/kFTBd92LSY=";
            rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDfpApYB38avxk4++jCX2neAP6Yv4/oKafbO2ROlTVilSXGookWRRv5TM7W2bq0TstgKd0P7Jvg/Q1U9WzssAGNzdgWsCAYKeMItcxsx2V6WRTs/GFaduPCnPSlqovFjLG6gHzXUXAnaWc2eT78tPfFsLPCVscv1s3jrakHcUMOJDcX1IaThlrPsSNVRJ/IZC4SUi2M3JWWNi16y/LX5WHLV9YTFBy9D6pJnf8+/llDK3Q0J/5daOHscTTrVuP/6i1eAK9dlcUJqcGyW0qcnPCH5RfPaY5ezBYjhjHefgjOS8P9nK3lqD0r4dEKX2wupZ2GFF8TDAYAqncAozjx+9LJCo5VMTbcqkSqUFFfIOqybg3wCv8UvIdVjlKQf98v4POPWhPuyijgsHCO0+ICuiLoHs/7P8/yKs3GpEC/W/7jZqbYao0X2jRxmSUjER1YolYiUegR6a/Tye4QwUjSDWxK2DmTSonF1rfyAugY7MyJE+h2Zte49Jb1JYxmdPLJ07k=";
          };
        };
        ubuntu = {
          hostNames = [
            "100.124.196.22"
            "ubuntu"
          ];
          keys = {
            ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSTbPRFFlZw/Lc0o4CPsaSZpFNnP2/+B67QuwcWkSEH";
            ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOy8Dq6p16YoLs701NKMCp3p9vWeWyn+t97uJMTOdcH+K/qIRPxlY5mjCgDJK4Vxt3Fgap6tZZldbRCGECDGfTA=";
            rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCy0KxAon1lH6rjQKYFzPM9eOQ+y9Rd+aNlSiq7JhwrUd9qhxRpl0yRJA1DfC/Vbt9EgpWFAgSlh+NW9hdzYfr80jS8h/xrUUsMwoP4Sxb1FLtdqW3DTt3c/uuMdkNjpG0PDNdomHyfxU5HZUBwRmWU7Kyfx1whYQEF+RPJxI/BiXxmyfbQ97HlOG+oggaufH7Amoeqv3UXgfggA9xLONjmyeo7/TXYZKzvjyEN6yElgjI0zAzigz79OzQsqLHYllMTYsoTlY9v1oDjU8yGACDbUsYOqN08g0tTsPIDRDb4e81HdQJ3T/tNw2JvwcjR+wZJLjK1D9HbzpIIEiIqnDIg2PTuFAQBu9Prlm63QnLFytSbEGBhUWqkFYZv+3HjSuwSJxGVZozaTMG4LpyFGql+Iv2ZJASqMBgMd/U56JXc+yAPdx0pg65coHRYcqfjH9+3RlHYW62V1x/ShLuMTyKx4/BE8Uy9B2+jcqGBfbuYLR+Mk1RBiI4A59JdYvl8tAc=";
          };
        };
        raspberrypi = {
          hostNames = [
            "100.71.240.112"
            "raspberrypi"
            "172.18.46.146"
          ];
          keys = {
            ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJvCFYDYl5bZWqCpJzrjKzrnJSk2mjGQJ/1xHad1PvsN";
            ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBeL6WwcmX4K/r5aY6Lhh2kyj3ri82rqjlWvYEmNTIQq/JZIjE8ra2+0gm38cG99LwdVDAXtBV6tsJb8vhCKJLw=";
            rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCcPNwgD4BRwMxXcBEWxyXMvMH18IQPXhQ1x4xt0mruJYfH7i0ZB0bwWeKXpLL0tvCcfRFtMRV+JJa2ilyLE8W3SVu1WXhpQab1F/uFqa+Ck6pY3XWj+kb42nkpRxXNVmmv3RFYLPQTaWeuq71lD5WXa4RsIvHsM4RxvlxdojNxYz8dxc3HM58onAZLHYZ6JfZxDwAuXV6zM5+m6L+jbZi1jipsLOSa/pDm1/JlZYNwsLlbCavp50r+fGZjSGCexXgfHiR0D5GuLYV7jw+VIewuWzEHff7SwUyyojrUSdThbWpQs1QLMxe9ecUxzBQfTavEHecL19DnpzMRSc21SUUGdfOI56I8rhcIZGmtx14d+th3cesxp6ToM4Ehn8+cAvP21JRlxbkKKI5lOKcwSwsWtYa6XnPf2n9NfMPO/NUknu/12K7eZhrIskTv44YuYhcUCeNE/HQNgQ7r1cgG+thmLxU6s8Jnfs72jIBc7MEPgHnrdWgC7KgjCOwCioeOBG0=";
          };
        };
        lan-172-18-43-172 = {
          hostNames = [ "172.18.43.172" ];
          keys = {
            ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIQYPYm11vnHbWzIx+nVFmOBIgGtuNLdb83dSK7H3j3a";
            ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBB0gRCxomoetliuRS12CIoNQE40RdsXKa47Emn4/GCHKRXtdJhmfMbuEGENmbQ9CVIJcDjp+iw8QfUfCwa7adY8=";
            rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC9cmaJZK/Lj3LhXjX4G5CS4zf7j+fzr4OXrmsCz1ZSmRWPt4TP+aeFC8MWloW0sbj/f4DlkvpDB9prvflsAUkPKVaRowq30HvonTofr+u49RrSwNl5lUp8VXztjwIdWmFCQSPry8rgHtbsooNfM/ebWrggnnr7Wbd791Thn2F8NqtU9v4MkP6XsOIgZBr2tB5muWzJXLUYjzhKJ7htGSNpQOvi3v6+IIV9f7+t+CEg5B+M8yKOM4sTFkLpj0HYmXTwF1r+/ENzalYKAgzYRRSNEOD6kDIad5NIkGz/MQV/84ozFYI5PiKFRRsCFlqUjkaN/zBTQ/1X8+PHAXPR66oWyCZJ5QiRy5M7HwZlOIeZE6bz9zA3wkO56VEbmupIWzhy7LsB9fKhK9W6K4D3RIVHNM72eT2Xzs21tLxuXOK0z+8RGqFl4TjlZf/uwn8Kfs2Wo1Fz/HWgFLfEMWIi2WFU67W0lpCutO5hNgugULaKdYUkX7gM7EkjYeaOlToxQi0=";
          };
        };
      };
    in
    pkgs.lib.concatMapAttrs (
      host: spec:
      pkgs.lib.mapAttrs' (algo: key: {
        name = "${host}-${algo}";
        value = {
          inherit (spec) hostNames;
          publicKey = key;
        };
      }) spec.keys
    ) knownHostSpecs;

  services.openssh.enable = lib.mkDefault false;
}
