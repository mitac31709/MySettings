# Lecture audio recording (USB document camera `hw:CARD=Camera,DEV=0`)
# and rsync upload to ubuntu (mitac@100.124.196.22:~/lectures/inbox).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  lecturePython = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  hasTimetableEnv = config.age.secrets ? "raspberrypi-lecture-timetable-env";
  timetableEnvFile =
    if hasTimetableEnv then
      config.age.secrets."raspberrypi-lecture-timetable-env".path
    else
      "-/etc/lecture-recorder/timetable.env";

  hasUploadKey = config.age.secrets ? "raspberrypi-lecture-upload-key";
  uploadKeyPath =
    if hasUploadKey then config.age.secrets."raspberrypi-lecture-upload-key".path else null;

  recorderScript = "/opt/lecture-recorder/lecrec.py";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/lecrec 0750 lecrec lecrec -"
    "d /var/lib/lecrec/.ssh 0700 lecrec lecrec -"
    "d /etc/lecture-recorder 0750 root lecrec -"
  ]
  ++ lib.optional hasUploadKey "L+ /var/lib/lecrec/.ssh/id_lecture_upload - - - - ${uploadKeyPath}";

  # Runs every minute at :05 (`lecrec.py tick`) to record scheduled classes from the Sunplus USB Camera.
  systemd.services.lecture-recorder = {
    description = "Lecture audio recorder tick (USB document camera)";
    after = [ "sound.target" ];
    path = with pkgs; [
      alsa-utils
      coreutils
      ffmpeg
      lecturePython
    ];
    unitConfig = {
      ConditionPathExists = recorderScript;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "lecrec";
      Group = "lecrec";
      SupplementaryGroups = [ "audio" ];
      WorkingDirectory = "/var/lib/lecrec";
      EnvironmentFile = timetableEnvFile;
      ExecStart = "${lecturePython}/bin/python3 ${recorderScript} tick";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/var/lib/lecrec" ];
    };
  };

  systemd.timers.lecture-recorder = {
    description = "Trigger lecture-recorder tick every minute at :05";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:05";
      AccuracySec = "1s";
    };
  };

  # Runs 3min after boot then every 10min (`lecrec.py upload`) as User=lecrec
  # to rsync recordings over Tailscale to ubuntu:~/lectures/inbox.
  # TODO: Populate secrets/raspberrypi-lecture-upload-key.age (write-only SSH key for
  # mitac@100.124.196.22) and verify /etc/lecture-recorder/upload.conf points to
  # /run/agenix/raspberrypi-lecture-upload-key (or /var/lib/lecrec/.ssh/id_lecture_upload).
  systemd.services.lecture-upload = {
    description = "Upload recorded lectures to ubuntu:~/lectures/inbox";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      coreutils
      openssh
      rsync
      lecturePython
    ];
    environment = lib.optionalAttrs hasUploadKey {
      LECTURE_UPLOAD_KEY = uploadKeyPath;
    };
    unitConfig = {
      ConditionPathExists = recorderScript;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "lecrec";
      Group = "lecrec";
      WorkingDirectory = "/var/lib/lecrec";
      EnvironmentFile = timetableEnvFile;
      ExecStart = "${lecturePython}/bin/python3 ${recorderScript} upload";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/var/lib/lecrec" ];
    };
  };

  systemd.timers.lecture-upload = {
    description = "Upload recorded lectures to ubuntu every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "10min";
    };
  };
}
