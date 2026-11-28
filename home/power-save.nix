# User-space power-save mode CLI (`power-save`) and battery/AC auto-switch watcher.
# System-level CPU profile units (`power-save-cpu-on/off.service`) live in
# modules/nixos/laptop/power.nix.
{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:

let
  isChromebook = osConfig != null && (osConfig.networking.hostName or "") == "chromebook";

  powerSavePkg = pkgs.writers.writePython3Bin "power-save" {
    flakeIgnore = [
      "E501"
      "W503"
      "E203"
    ];
  } (builtins.readFile ../pkgs/power-save/power-save.py);
in
{
  mitac.scripts.powerSave = powerSavePkg;

  home.packages = [ powerSavePkg ];

  systemd.user.services.power-save-watcher = {
    Unit = {
      Description = "Power-save mode battery/AC auto-switch watcher";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = "30";
      StartLimitBurst = "5";
    };
    Service = {
      Type = "simple";
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.brightnessctl
            pkgs.bluez
            pkgs.libnotify
            pkgs.hyprland
            pkgs.systemd
            pkgs.coreutils
          ]
        }"
        "POWER_SAVE_ADAPTER_DEV=${if isChromebook then "AC" else "ACAD"}"
      ]
      ++ lib.optionals (!isChromebook) [
        "POWER_SAVE_BATTERY_DEV=BAT1"
      ];
      ExecStart = "${lib.getExe powerSavePkg} watch";
      Restart = "on-failure";
      RestartSec = "3";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
