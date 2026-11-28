# Campus Wi-Fi AP BSS Load logger (every 5 min) and daily final graph poster (00:00:30 JST).
# Note: campus-apload-report.timer (18:00) remains disabled, matching the current Pi.
{ config, pkgs, ... }:

let
  aploadPython = pkgs.python3.withPackages (ps: [ ps.matplotlib ]);

  hasAploadEnv = config.age.secrets ? "raspberrypi-campus-apload-env";
  aploadEnvFile =
    if hasAploadEnv then
      config.age.secrets."raspberrypi-campus-apload-env".path
    else
      "-/etc/campus-apload.env";

  # TODO: Move the Discord webhook URL into secrets/raspberrypi-campus-apload-env.age
  # if campus-apload-report.py currently hardcodes it.
  logScript = "/usr/local/sbin/campus-apload-log.py";
  reportScript = "/usr/local/sbin/campus-apload-report.py";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/campus-apload 0755 root root -"
  ];

  systemd.services.campus-apload-log = {
    description = "Log campus AP BSS Load metrics";
    after = [ "network.target" ];
    path = with pkgs; [
      iw
      aploadPython
    ];
    unitConfig = {
      ConditionPathExists = logScript;
    };
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/campus-apload";
      ExecStart = "${aploadPython}/bin/python3 ${logScript}";
    };
  };

  systemd.timers.campus-apload-log = {
    description = "Collect campus AP BSS Load every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };

  systemd.services.campus-apload-final = {
    description = "Render previous day campus AP BSS Load chart and post to Discord";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      aploadPython
      curl
    ];
    unitConfig = {
      ConditionPathExists = reportScript;
    };
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/campus-apload";
      EnvironmentFile = aploadEnvFile;
      ExecStart = "${aploadPython}/bin/python3 ${reportScript} --final";
    };
  };

  systemd.timers.campus-apload-final = {
    description = "Post daily campus AP BSS Load final chart at 00:00:30 JST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:00:30";
      Persistent = true;
    };
  };
}
