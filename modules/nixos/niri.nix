# Niri: scrollable-tiling Wayland compositor (optional session alongside Hyprland).
# Selectable from tuigreet's session menu (F3) while keeping Hyprland (UWSM) default.
{ pkgs, ... }:

{
  programs.niri = {
    enable = true;
    # Use GTK FileChooser (Nemo is already our file manager) instead of pulling in Nautilus.
    useNautilus = false;
  };

  # Native X11 compatibility daemon auto-spawned by Niri when present on PATH.
  environment.systemPackages = [ pkgs.xwayland-satellite ];
}
