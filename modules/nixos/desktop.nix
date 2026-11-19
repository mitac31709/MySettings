# Graphical desktop stack: Hyprland (UWSM) + greetd/ReGreet + console-gui + portals.
{ ... }:

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
  # programs.hyprland already adds xdg-desktop-portal-hyprland and xdg-desktop-portal-gtk
  # to extraPortals; omit them here to avoid duplicate dbus-1 servicedir entries.
  xdg.portal = {
    enable = true;
    config = {
      common.default = [ "gtk" ];
      hyprland.default = [
        "hyprland"
        "gtk"
      ];
    };
  };

  # Accessibility bus (AT-SPI2 over D-Bus) for computer-use agents (agent-desktop)
  # and assistive tech; also stops NixOS from exporting NO_AT_BRIDGE=1 / GTK_A11Y=none.
  services.gnome.at-spi2-core.enable = true;
}
