# Lecture audio recording (USB document camera `hw:CARD=Camera,DEV=0`)
# and rsync upload to ubuntu (`DEST=mitac@100.124.196.22:`, restricted key on ubuntu).
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

  # Known hosts file for `/var/lib/lecrec/.ssh/known_hosts` (matches `KNOWN_HOSTS=` in /etc/lecture-recorder/upload.conf).
  ubuntuKnownHosts = pkgs.writeText "lecrec-known-hosts" ''
    100.124.196.22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSTbPRFFlZw/Lc0o4CPsaSZpFNnP2/+B67QuwcWkSEH
    100.124.196.22 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOy8Dq6p16YoLs701NKMCp3p9vWeWyn+t97uJMTOdcH+K/qIRPxlY5mjCgDJK4Vxt3Fgap6tZZldbRCGECDGfTA=
  '';

  recorderScript = "/opt/lecture-recorder/lecrec.py";
in
{
  # Live /etc/lecture-recorder/upload.conf uses:
  #   KEY=/var/lib/lecrec/.ssh/id_ed25519
  #   KNOWN_HOSTS=/var/lib/lecrec/.ssh/known_hosts
  #   DEST=mitac@100.124.196.22:
  # TODO: Populate secrets/raspberrypi-lecture-upload-key.age with the write-only SSH
  # private key for /var/lib/lecrec/.ssh/id_ed25519, and secrets/raspberrypi-lecture-timetable-env.age.
  systemd.tmpfiles.rules = [
    "d /var/lib/lecrec 0750 lecrec lecrec -"
    "d /var/lib/lecrec/.ssh 0700 lecrec lecrec -"
    "d /etc/lecture-recorder 0750 root lecrec -"
    "L+ /var/lib/lecrec/.ssh/known_hosts - - - - ${ubuntuKnownHosts}"
  ]
  ++ lib.optional hasUploadKey "L+ /var/lib/lecrec/.ssh/id_ed25519 - - - - ${uploadKeyPath}";

  # Runs every minute at :05 (`lecrec.py tick`) to record scheduled classes from the Sunplus USB Camera.
  # Matches live /etc/systemd/system/lecture-recorder.service & .timer.
  systemd.services.lecture-recorder = {
    description = "Lecture audio recorder tick (USB document camera)";
    after = [
      "sound.target"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
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
      KillMode = "mixed";
      TimeoutStopSec = 30;
      Nice = -5;
      IOSchedulingClass = "best-effort";
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
      Persistent = false;
    };
  };

  # Runs 3min after boot then every 10min (`lecrec.py upload`) as User=lecrec
  # to rsync recordings over Tailscale to ubuntu (`DEST=mitac@100.124.196.22:`).
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
      Nice = 10;
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
