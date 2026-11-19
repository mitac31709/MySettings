# Graphical desktop stack: Hyprland (UWSM) + greetd/ReGreet + console-gui + portals.
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

  # XKB default layout (used by XWayland / console / greeter) and CUPS printing.
  # No standalone Xorg server is needed for the pure Wayland Hyprland stack.
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };
  services.printing.enable = true;

  # Desktop portals: Hyprland native portal with GTK fallback for file dialogs & settings.
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
