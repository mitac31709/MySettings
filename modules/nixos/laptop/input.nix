# Shared keyboard daemon (keyd): manual kernel OOM killer via Ctrl+Alt+Del
# (and Ctrl+Alt+Backspace) + virtual keyboard libinput quirk.
{
  lib,
  pkgs,
  ...
}:

let
  # keyd command(): invoke kernel OOM killer (SysRq-f). Prefer this over a
  # Hyprland bind — compositor may be wedged.
  sysrqOom = pkgs.writeShellScript "sysrq-oom" ''
    ${pkgs.coreutils}/bin/printf f > /proc/sysrq-trigger
  '';
in
{
  # Allow Magic SysRq via keyboard too (Alt+SysRq+letter). /proc/sysrq-trigger
  # ignores this mask; kept so classic SysRq still works if needed.
  boot.kernel.sysctl."kernel.sysrq" = 244;

  # keyd drops privileges to group "keyd"; NixOS module never creates it.
  users.groups.keyd = { };

  # nixpkgs keyd.nix: RestrictSUIDSGID + missing CAP_SETGID break setgid("keyd")
  # ("setgid: Operation not permitted"); ProcSubset=pid and
  # ProtectKernelTunables hide/RO-mount /proc/sysrq-trigger (sysrqOom).
  systemd.services.keyd.serviceConfig = {
    # keyd 2.6.0 exits 15 on SIGTERM instead of returning 0.
    SuccessExitStatus = [ 15 ];
    CapabilityBoundingSet = lib.mkForce [
      "CAP_SYS_NICE"
      "CAP_IPC_LOCK"
      "CAP_SETGID"
    ];
    RestrictSUIDSGID = lib.mkForce false;
    ProtectKernelTunables = lib.mkForce false;
    ProcSubset = lib.mkForce "all";
  };

  services.keyd = {
    enable = true;
    keyboards = {
      # Matches all keyboards (VAIO internal + external USB/BT keyboards) unless
      # a more specific host id block (e.g. chromebook/input.nix cros) matches.
      ctrl-alt-del-oom = {
        ids = [
          "*"
          # Exclude capsomnia-helperd's synthetic toggle UInput device so
          # non-dedicated fallback toggles are not remapped back to KEY_MACRO.
          "-k:1209:ca95"
        ];
        extraConfig = ''
          [main]
          # Remap physical Caps Lock to KEY_MACRO (XKB <I120> = NoSymbol) so it
          # never triggers Eisu_toggle / Caps_Lock in Hyprland, fcitx5/Meltype,
          # or TTY; capsomnia-helperd watches KEY_MACRO to toggle Keep Awake.
          capslock = macro
          # Tap: z, Hold/chord with H/J/K/L: arrow keys (also duplicated in chromebook/input.nix).
          z = overloadt2(z_nav, z, 200)

          [z_nav]
          h = left
          j = down
          k = up
          l = right

          [control+alt]
          delete = command(${sysrqOom})
          backspace = command(${sysrqOom})
        '';
      };
    };
  };

  # Mark keyd's virtual keyboard as internal for libinput palm rejection.
  # Chromebook overrides this with ModelTabletModeNoSuspend=1.
  environment.etc."libinput/local-overrides.quirks".text = lib.mkDefault ''
    [keyd virtual keyboard]
    MatchName=keyd virtual keyboard
    AttrKeyboardIntegration=internal
  '';
}
