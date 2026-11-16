# Graphical desktop stack: greeter + Hyprland + console-gui + portals.
{
  pkgs,
  ...
}:

{
  imports = [
    ./hyprland.nix
    ./greetd.nix
    ./console-gui.nix
  ];

  # Layout + printing (used by the Hyprland session).
  services.xserver.enable = true;
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };
  services.printing.enable = true;

  # Desktop portals. Hyprland provides its own portal; keep gtk as fallback.
  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-hyprland
      pkgs.xdg-desktop-portal-gtk
    ];
    config = {
      common.default = [ "gtk" ];
      hyprland.default = [
        "hyprland"
        "gtk"
      ];
    };
  };
}
