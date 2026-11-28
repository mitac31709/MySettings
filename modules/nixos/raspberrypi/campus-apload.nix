# Campus Wi-Fi AP BSS Load logger (every 5 min) and Discord graph posters:
# - campus-apload-log.timer    (every 5 min, Nice=10)
# - campus-apload-report.timer (18:00 JST)
# - campus-apload-final.timer  (00:00:30 JST, previous day full 00-24h chart)
#
# Both report units read `WEBHOOK=...` directly from `/etc/freeap-notify.env`
# (shared with freeap-count-notify; populated from secrets/raspberrypi-freeap-notify-env.age).
{ pkgs, ... }:

let
  aploadPython = pkgs.python3.withPackages (ps: [
    ps.matplotlib
    ps.requests
  ]);

  campusAploadLogScript = pkgs.writeScript "campus-apload-log.py" (
    builtins.replaceStrings
      [
        "#!/usr/bin/env python3"
        ''IW = "/usr/sbin/iw"''
      ]
      [
        "#!${aploadPython}/bin/python3"
        ''IW = "${pkgs.iw}/bin/iw"''
      ]
      (builtins.readFile ./scripts/campus-apload-log.py)
  );

  campusAploadReportScript = pkgs.writeScript "campus-apload-report.py" (
    builtins.replaceStrings
      [
        "#!/usr/bin/env python3"
        ''
          FONT_CANDIDATES = [
              "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
              "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
          ]''
      ]
      [
        "#!${aploadPython}/bin/python3"
        ''
          FONT_CANDIDATES = [
              "${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc",
              "${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-Regular.ttc",
              "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
              "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
          ]''
      ]
      (builtins.readFile ./scripts/campus-apload-report.py)
  );
in
{
  systemd.tmpfiles.rules = [
    "d /usr/local/sbin 0755 root root -"
    "d /var/lib/campus-apload 0755 root root -"
    "L+ /usr/local/sbin/campus-apload-log.py - - - - ${campusAploadLogScript}"
    "L+ /usr/local/sbin/campus-apload-report.py - - - - ${campusAploadReportScript}"
  ];

  # Matches live /etc/systemd/system/campus-apload-log.service & .timer.
  systemd.services.campus-apload-log = {
    description = "Log campus AP BSS Load (station count / channel utilisation)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/campus-apload";
      ExecStart = "${campusAploadLogScript}";
      Nice = 10;
    };
  };

  systemd.timers.campus-apload-log = {
    description = "Log campus AP load every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "30s";
      Persistent = true;
    };
  };

  # Matches live /etc/systemd/system/campus-apload-report.service & .timer (18:00 JST).
  systemd.services.campus-apload-report = {
    description = "Post daily campus AP load graph to Discord";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = "/etc/freeap-notify.env";
    };
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/campus-apload";
      ExecStart = "${campusAploadReportScript}";
    };
  };

  systemd.timers.campus-apload-report = {
    description = "Daily campus AP load graph at 18:00 JST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 18:00:00";
      Persistent = true;
    };
  };

  # Matches live /etc/systemd/system/campus-apload-final.service & .timer (00:00:30 JST).
  systemd.services.campus-apload-final = {
    description = "Post previous day full campus AP load graph to Discord (00:00)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = "/etc/freeap-notify.env";
    };
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/campus-apload";
      ExecStart = "${campusAploadReportScript} --final";
    };
  };

  systemd.timers.campus-apload-final = {
    description = "Daily previous-day campus AP load graph at 00:00 JST";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:00:30";
      Persistent = true;
    };
  };
}
