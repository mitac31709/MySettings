# Home Manager entry for mitac: identity + session/program imports.
{ ... }:

{
  imports = [
    ./flake-tools.nix
    ./agent-skills.nix
    ./antigravity.nix
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
    ./vivaldi-chatgpt-extension.nix
    ./vivaldi-extensions-repair.nix
    ./vivaldi-pwa-desktop.nix
    ./jquake.nix
    ./capsomnia.nix
    ./activitywatch.nix
    ./hyprland.nix
  ];

  home.username = "mitac";
  home.homeDirectory = "/home/mitac";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
}
