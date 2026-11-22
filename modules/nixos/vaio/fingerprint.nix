# VAIO laptop fingerprint sensor (ELAN 04f3:0c46) via libfprint + fprintd.
# Upstream libfprint does not list 04f3:0c46 yet; patch the elan driver
# (and autosuspend.hwdb so libfprint's installCheckPhase passes), matching
# PLD Linux's vaio-sx.patch (ELAN_NOT_ROTATED, adapted for 1.94.100 bitmasks).
{
  pkgs,
  ...
}:

{
  nixpkgs.overlays = [
    (_final: prev: {
      libfprint = prev.libfprint.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace libfprint/drivers/elan.h \
            --replace-fail \
              '#define ELAN_0C58 (1 << 3)' \
              $'#define ELAN_0C58 (1 << 3)\n#define ELAN_0C46 (1 << 4)' \
            --replace-fail \
              '#define ELAN_NOT_ROTATED ELAN_0C03' \
              '#define ELAN_NOT_ROTATED (ELAN_0C03 | ELAN_0C46)' \
            --replace-fail \
              '{.vid = ELAN_VEND_ID,  .pid = 0x0c42, .driver_data = ELAN_0C42},' \
              $'{.vid = ELAN_VEND_ID,  .pid = 0x0c42, .driver_data = ELAN_0C42},\n  {.vid = ELAN_VEND_ID,  .pid = 0x0c46, .driver_data = ELAN_0C46},'
          substituteInPlace data/autosuspend.hwdb \
            --replace-fail \
              'usb:v04F3p0C42*' \
              $'usb:v04F3p0C42*\nusb:v04F3p0C46*'
        '';
      });
    })
  ];

  services.fprintd = {
    enable = true;
    # Keep PAM opt-in per service: login/greetd must stay password-based to
    # unlock gnome-keyring, hyprlock uses native D-Bus auth.fingerprint, and
    # cmd-polkit (rofi-polkit) only handles password requests.
    enablePam = false;
  };

  services.udev.packages = [ pkgs.libfprint ];

  security.pam.services.sudo.fprintAuth = true;
  security.pam.services.hyprlock.fprintAuth = false;
}
