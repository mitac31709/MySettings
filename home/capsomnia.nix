# Capsomnia user session daemon (logind lid-switch inhibitor, auto-off timer,
# closed-lid display dimming/sleep, lock-on-lid-open, hotspot keepalive).
{
  pkgs,
  ...
}:

let
  capsomniaPkg = pkgs.callPackage ../pkgs/capsomnia { };
in
{
  systemd.user.services.capsomniad = {
    Unit = {
      Description = "Capsomnia keep-awake session daemon";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = "30";
      StartLimitBurst = "5";
    };
    Service = {
      Type = "simple";
      ExecStart = "${capsomniaPkg}/bin/capsomniad";
      Restart = "on-failure";
      RestartSec = "1";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
