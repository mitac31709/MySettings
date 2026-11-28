# Users, SSH access, sudoers, and known hosts for the Raspberry Pi 5 server.
{ lib, ... }:

let
  # Live authorized key present on both mitac and grokbot (fingerprint SHA256:YxTtd3yHGAgRFGxv1AEt3tFKE1TK3Dw4cfKvcudznMU).
  grokbotBoxKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINA+Viz0A1SfEl0MwqyLjLicGL+8tTGntansBGu/K8RX grokbot-box";

  repoAuthorizedKeys = lib.optional (builtins.pathExists ../../../secrets/id-wsl-builder.pub) (
    lib.trim (builtins.readFile ../../../secrets/id-wsl-builder.pub)
  );
in
{
  # Hardware peripheral groups from Raspberry Pi OS (i2c is created by hardware.i2c.enable).
  users.groups = {
    gpio = { };
    spi = { };
    lecrec = { };
  };

  users.users = {
    mitac = {
      isNormalUser = true;
      uid = 1000;
      description = "mitac";
      extraGroups = [
        "wheel"
        "networkmanager"
        "dialout"
        "video"
        "render"
        "audio"
        "i2c"
        "gpio"
        "spi"
      ];
      openssh.authorizedKeys.keys = [ grokbotBoxKey ] ++ repoAuthorizedKeys;
    };

    # Local dev user for code-server & Drogon; intentionally excluded from SSH AllowUsers.
    shimesaba = {
      isNormalUser = true;
      uid = 1001;
      description = "shimesaba";
      extraGroups = [ "wheel" ];
    };

    # Automation / agent user (sudo + dialout + networkmanager; matches Pi OS dialout + netdev).
    grokbot = {
      isNormalUser = true;
      uid = 1002;
      description = "grokbot";
      extraGroups = [
        "wheel"
        "dialout"
        "networkmanager"
      ];
      openssh.authorizedKeys.keys = [ grokbotBoxKey ];
    };

    # Dedicated system account for lecture-recorder & lecture-upload (USB document camera audio).
    lecrec = {
      isSystemUser = true;
      group = "lecrec";
      extraGroups = [ "audio" ];
      home = "/var/lib/lecrec";
      createHome = true;
    };
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = true;
      # Match current Pi OS sshd_config: shimesaba cannot log in via SSH.
      AllowUsers = [
        "mitac"
        "grokbot"
      ];
    };
  };

  # Match /etc/sudoers.d/010_pi-nopasswd (mitac) and /etc/sudoers.d/90-grokbot (grokbot),
  # while keeping wheelNeedsPassword = true for shimesaba.
  security.sudo = {
    enable = true;
    wheelNeedsPassword = true;
    extraRules = [
      {
        users = [
          "mitac"
          "grokbot"
        ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  # Pre-populate ubuntu's SSH host keys so lecture-upload rsync over Tailscale
  # trusts mitac@100.124.196.22 without interactive TOFU prompts.
  programs.ssh.knownHosts = {
    ubuntu-ed25519 = {
      hostNames = [
        "100.124.196.22"
        "ubuntu"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSTbPRFFlZw/Lc0o4CPsaSZpFNnP2/+B67QuwcWkSEH";
    };
    ubuntu-ecdsa = {
      hostNames = [
        "100.124.196.22"
        "ubuntu"
      ];
      publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOy8Dq6p16YoLs701NKMCp3p9vWeWyn+t97uJMTOdcH+K/qIRPxlY5mjCgDJK4Vxt3Fgap6tZZldbRCGECDGfTA=";
    };
  };
}
