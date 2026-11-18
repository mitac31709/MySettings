# Capsomnia privileged helper daemon (Caps Lock key/LED + suspend) and CLI/GUI package.
{
  pkgs,
  ...
}:

let
  capsomniaPkg = pkgs.callPackage ../../../pkgs/capsomnia { };
in
{
  environment.systemPackages = [ capsomniaPkg ];

  systemd.services.capsomnia-helperd = {
    description = "Capsomnia privileged Caps Lock key/LED and sleep helper";
    wantedBy = [ "multi-user.target" ];
    after = [ "keyd.service" ];
    wants = [ "keyd.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${capsomniaPkg}/bin/capsomnia-helperd";
      Restart = "on-failure";
      RestartSec = "1s";
      Environment = [
        "CAPS_HELPER_SOCKET=/run/capsomnia/helper.sock"
        "CAPS_HELPER_GROUP=wheel"
      ];
    };
  };
}
