# Sway: primary keyboard-first Wayland session (tuigreet-adjacent TUI feel).
{ lib, pkgs, ... }:

{
  services.displayManager.defaultSession = "sway";

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraSessionCommands = ''
      if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
      fi
    '';
    # swaylock stays on the system profile: its PAM stack is system-wide
    # (security.pam.services.swaylock below). waybar / rofi / mako are Home
    # Manager programs. cliphist, wl-clipboard, grim, slurp, swayidle,
    # brightnessctl, and jq are home.packages. Keybinds use those same store
    # paths, so each command is linked once. wlrctl was not referenced.
    extraPackages = with pkgs; [
      swaylock
    ];
  };

  security.pam.services.swaylock.enable = true;

  # Unify SSH and `sudo -A` prompts onto Rofi instead of x11-ssh-askpass / gcr4.
  programs.ssh = {
    startAgent = true;
    askPassword = lib.getExe' pkgs.rofi-prompt "rofi-askpass";
  };
  systemd.user.services.ssh-agent.serviceConfig.ExecStartPost =
    "-${pkgs.systemd}/bin/systemctl --user set-environment SSH_AUTH_SOCK=%t/ssh-agent";
  environment.sessionVariables = {
    SUDO_ASKPASS = lib.getExe' pkgs.rofi-prompt "rofi-askpass";
  };

  # Audio (PulseAudio on Chromebook, PipeWire on VAIO) and power-profiles-daemon stay host-managed.
}
