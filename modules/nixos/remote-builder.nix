# Offload Nix builds to WSL2 on the LAN Windows box (Tailscale: galleria-mitac).
# Local max-jobs stay enabled so builds fall back here if the remote is down.
#
# One-time on the builder: Nix + sshd (port 2222), this host's pubkey in
# authorized_keys, user in trusted-users. Key is decrypted via agenix at
# `/run/agenix/id-wsl-builder-{root,user}` (passphrase-less; nix-daemon cannot prompt).

{ config, ... }:

let
  rootBuilderKey = config.age.secrets."id-wsl-builder-root".path or null;
  userBuilderKey = config.age.secrets."id-wsl-builder-user".path or null;
in
{
  # Tailscale MagicDNS is unreliable while Cloudflare WARP owns resolv.conf;
  # pin the stable CGNAT address (galleria-mitac).
  programs.ssh.extraConfig = ''
    Host wsl-builder galleria-mitac
      HostName 100.102.102.53
      Port 2222
      User mitac
      ${
        if userBuilderKey != null then
          "IdentityFile ${userBuilderKey}\n  IdentitiesOnly yes"
        else
          "# (waiting for secrets/id-wsl-builder.age)"
      }
  '';

  nix.distributedBuilds = true;
  nix.settings = {
    builders-use-substitutes = true;
    # Fail over to local builds quickly when WSL is asleep / offline.
    connect-timeout = 5;
  };

  nix.buildMachines =
    if rootBuilderKey != null then
      [
        {
          hostName = "wsl-builder";
          sshUser = "mitac";
          sshKey = rootBuilderKey;
          system = "x86_64-linux";
          # WSL is not NixOS; ssh-ng often breaks on non-interactive PATH.
          protocol = "ssh";
          maxJobs = 8;
          speedFactor = 2;
          # Omit kvm: nested virt in WSL is hit-or-miss.
          supportedFeatures = [
            "big-parallel"
            "nixos-test"
          ];
          # ssh-keyscan -p 2222 -t ed25519 galleria-mitac
          publicHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAID+Dgx7oDIHOa5CPTkDbeGqIjGsCf2evYSI/pRIjz7H0";
        }
      ]
    else
      [ ];
}
