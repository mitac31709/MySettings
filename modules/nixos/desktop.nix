# Graphical desktop stack: Hyprland (UWSM) + greetd/Dux Greeter + console-gui + portals.
{
  config,
  lib,
  ...
}:

{
  imports = [
    ./hyprland.nix
    ./greetd.nix
    ./console-gui.nix
  ];

  # XKB default layout (used by XWayland / console) and CUPS printing.
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

  # Audio user daemons default to ConditionUser=!root, so the greetd greeter
  # user (dms-greeter) starts them and fails creating state.
  systemd.user.sockets = lib.mkMerge [
    (lib.mkIf (config.services.pipewire.enable && !config.services.pipewire.systemWide) (
      {
        pipewire.unitConfig.ConditionUser = "!@system";
      }
      // lib.optionalAttrs config.services.pipewire.pulse.enable {
        pipewire-pulse.unitConfig.ConditionUser = "!@system";
      }
    ))
    (lib.mkIf (config.services.pulseaudio.enable && !config.services.pulseaudio.systemWide) {
      pulseaudio.unitConfig.ConditionUser = "!@system";
    })
  ];
  systemd.user.services = lib.mkMerge [
    (lib.mkIf (config.services.pipewire.enable && !config.services.pipewire.systemWide) (
      {
        pipewire.unitConfig.ConditionUser = "!@system";
      }
      // lib.optionalAttrs config.services.pipewire.pulse.enable {
        pipewire-pulse.unitConfig.ConditionUser = "!@system";
      }
    ))
    (lib.mkIf
      (
        config.services.pipewire.enable
        && config.services.pipewire.wireplumber.enable
        && !config.services.pipewire.systemWide
      )
      {
        wireplumber.unitConfig.ConditionUser = "!@system";
      }
    )
    (lib.mkIf (config.services.pulseaudio.enable && !config.services.pulseaudio.systemWide) {
      pulseaudio.unitConfig.ConditionUser = "!@system";
    })
  ];
}
