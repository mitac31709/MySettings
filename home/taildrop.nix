# Auto-receive Taildrop files into ~/Downloads (Linux needs an explicit get loop).
# Requires services.tailscale.extraSetFlags = [ "--operator=mitac" ] so this
# user can call `tailscale file get` without sudo.
{ pkgs, config, ... }:

let
  waitForTailscaled = pkgs.writeShellScript "wait-for-tailscaled" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      [ -S /run/tailscale/tailscaled.sock ] && exit 0
      ${pkgs.coreutils}/bin/sleep 1
    done
    exit 1
  '';
in
{
  systemd.user.services.taildrop-receive = {
    Unit = {
      Description = "Taildrop: receive files into Downloads";
      After = [ "default.target" ];
    };
    Service = {
      UMask = "0077";
      ExecStartPre = "${waitForTailscaled}";
      ExecStart = "${pkgs.tailscale}/bin/tailscale file get --loop --verbose --conflict=rename ${config.home.homeDirectory}/Downloads";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
