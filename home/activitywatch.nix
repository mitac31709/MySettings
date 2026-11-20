# ActivityWatch server + Wayland window/AFK watcher (awatcher) for Hyprland.
#
# Web UI: http://127.0.0.1:5600
# awatcher uses wlr-foreign-toplevel-management-unstable-v1 and ext-idle-notify-v1
# on Hyprland, so it runs under graphical-session.target (after WAYLAND_DISPLAY is
# exported) instead of HM's default.target watcher hook (which fires before login
# when user linger is enabled).
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    activitywatch
    awatcher
  ];

  services.activitywatch = {
    enable = true;
    package = pkgs.activitywatch;
  };

  systemd.user.services.activitywatch-watcher-wayland = {
    Unit = {
      Description = "ActivityWatch Wayland window & AFK watcher (awatcher)";
      PartOf = [ "graphical-session.target" ];
      After = [
        "graphical-session.target"
        "activitywatch.service"
      ];
      Requires = [ "activitywatch.service" ];
    };
    Service = {
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStart = "${pkgs.awatcher}/bin/awatcher";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
