# Home Manager entry for mitac: identity + session/program imports.
{ ... }:

{
  imports = [
    ./flake-tools.nix
    ./agent-skills.nix
    ./local-llm.nix
    ./hermes.nix
    ./secrets.nix
    ./shell.nix
    ./programs.nix
    ./startup-sound.nix
    ./meltype.nix
    ./clipboard.nix
    ./cursor.nix
    ./t3code.nix
    ./lan-mouse.nix
    ./rquickshare.nix
    ./taildrop.nix
    ./uniclipboard.nix
    ./vivaldi-extensions-repair.nix
    ./vivaldi-pwa-desktop.nix
    ./jquake.nix
    ./capsomnia.nix
    ./power-save.nix
    ./activitywatch.nix
    ./whatpulse.nix
    ./hyprland.nix
    ./ws10-dashboard.nix
    ./niri.nix
  ];

  home.username = "mitac";
  home.homeDirectory = "/home/mitac";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
}
