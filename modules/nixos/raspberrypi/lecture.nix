# Lecture audio recording (USB document camera `hw:CARD=Camera,DEV=0`)
# and rsync upload to ubuntu (mitac@100.124.196.22:~/lectures/inbox).
{ config, pkgs, ... }:

let
  lecturePython = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  hasTimetableEnv = config.age.secrets ? "raspberrypi-lecture-timetable-env";
  timetableEnvFile =
    if hasTimetableEnv then
      config.age.secrets."raspberrypi-lecture-timetable-env".path
    else
      "-/etc/lecture-recorder/timetable.env";

  # TODO: Confirm whether the live scripts stay under /opt/lecture-recorder or are
  # relocated under /home/mitac/lecture-recorder, and verify the exact upload script
  # path & arguments from /etc/systemd/system/lecture-{recorder,upload}.service.
  recorderScript = "/opt/lecture-recorder/lecrec.py";
  uploadScript = "/opt/lecture-recorder/upload.sh";
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/lecrec 0750 lecrec lecrec -"
    "d /etc/lecture-recorder 0750 root lecrec -"
  ];

  # Runs every minute at :05 to record scheduled classes from the Sunplus USB Camera.
  systemd.services.lecture-recorder = {
    description = "Lecture audio recorder (USB document camera)";
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
      # TODO: Verify exact ExecStart flags (and whether the script lives under /home/mitac/...).
      ExecStart = "${lecturePython}/bin/python3 ${recorderScript}";
    };
  };

  systemd.timers.lecture-recorder = {
    description = "Trigger lecture-recorder every minute at :05";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:05";
      AccuracySec = "1s";
    };
  };

  # Runs every 10 minutes to rsync recordings over Tailscale to ubuntu:~/lectures/inbox.
  # TODO: Populate secrets/raspberrypi-lecture-upload-key.age (write-only SSH key for
  # mitac@100.124.196.22) and confirm whether lecture-upload runs as User=lecrec or User=mitac
  # and what script path under /opt/lecture-recorder or /home/mitac it invokes.
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
    unitConfig = {
      ConditionPathExists = uploadScript;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "mitac";
      Group = "users";
      WorkingDirectory = "/var/lib/lecrec";
      ExecStart = "${pkgs.bash}/bin/bash ${uploadScript}";
    };
  };

  systemd.timers.lecture-upload = {
    description = "Upload recorded lectures to ubuntu every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      Persistent = true;
    };
  };
}
