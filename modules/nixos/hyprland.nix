# Hyprland: primary Wayland desktop session (UWSM, hyprlock, Wayland toolkit defaults).
{ lib, pkgs, ... }:

{
  services.displayManager.defaultSession = "hyprland-uwsm";

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true; # JQuake / stalonetray / legacy X11 apps
  };

  # PAM stack for hyprlock (invoked manually via Super+L and by hypridle).
  programs.hyprlock.enable = true;
  # programs.hyprlock pulls in NixOS's global /etc/systemd/user/hypridle.service,
  # which fails for users without hypridle.conf (e.g. greeter). Home Manager owns
  # hypridle.service and ~/.config/hypr/hypridle.conf for normal users.
  services.hypridle.enable = lib.mkForce false;

  # Standard Wayland / Hyprland session environment defaults.
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    GDK_BACKEND = "wayland,x11,*";
    QT_QPA_PLATFORM = "wayland;xcb";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    XDG_SESSION_TYPE = "wayland";
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
