# Hyprland: primary Wayland session (UWSM, hyprlock, greetd + ReGreet).
{ lib, pkgs, ... }:

{
  services.displayManager.defaultSession = "hyprland-uwsm";

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true; # JQuake / stalonetray / X11 apps
  };

  # PAM stack for hyprlock (also used by hypridle before-sleep).
  programs.hyprlock.enable = true;

  # Wayland / Electron defaults for the Hyprland session.
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    SUDO_ASKPASS = lib.getExe' pkgs.rofi-prompt "rofi-askpass";
  };

  # Unify SSH and `sudo -A` prompts onto Rofi instead of x11-ssh-askpass / gcr4.
  programs.ssh = {
    startAgent = true;
    askPassword = lib.getExe' pkgs.rofi-prompt "rofi-askpass";
  };
  systemd.user.services.ssh-agent.serviceConfig.ExecStartPost =
    "-${pkgs.systemd}/bin/systemctl --user set-environment SSH_AUTH_SOCK=%t/ssh-agent";
}
