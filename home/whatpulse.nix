# WhatPulse client autostart (minimized to tray; also spawns whatpulse-collector).
# Network traffic stats use the system `whatpulse-pcap-service` unit
# (modules/nixos/common.nix), and keystroke/mouse stats use the `input` group.
{ pkgs, ... }:

{
  home.packages = [ pkgs.whatpulse ];

  systemd.user.services.whatpulse = {
    Unit = {
      Description = "WhatPulse activity tracker (tray client + collector)";
      PartOf = [ "graphical-session.target" ];
      BindsTo = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${pkgs.whatpulse}/bin/whatpulse --minimized";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
