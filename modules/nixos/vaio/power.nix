# VAIO laptop (VJPK13C12N) power / S3 resume quirks.
#
# This platform uses S3 (`deep`) sleep (`FACP` Low Power S0 Idle = 0) and its
# `LID0` ACPI device has no `_PRW` wakeup entry. Instead, the Embedded Controller
# controls S3 lid-open wake via `\_SB.PCI0.LPCB.EC0.WLD3` (exposed by `\_SB.SNCX`
# feature `0x015D`, methods `LORR` / `LORW`), which defaults to 0 on Linux.
{
  config,
  pkgs,
  ...
}:

let
  vaioLidOpenResume = pkgs.writeShellScript "vaio-lid-open-resume" ''
    set -euo pipefail
    if [ ! -w /proc/acpi/call ]; then
      echo "vaio-lid-open-resume: /proc/acpi/call not writable" >&2
      exit 1
    fi

    printf '%s\n' '\_SB.SNCX.LORW 1' > /proc/acpi/call
    res=$(${pkgs.coreutils}/bin/tr -d '\0\n' < /proc/acpi/call)
    case "$res" in
      Error:*)
        echo "vaio-lid-open-resume: ACPI call failed: $res" >&2
        exit 1
        ;;
    esac
  '';
in
{
  boot.extraModulePackages = [ config.boot.kernelPackages.acpi_call ];
  boot.kernelModules = [ "acpi_call" ];

  systemd.services.vaio-lid-open-resume = {
    description = "Enable VAIO lid-open resume from S3 (EC0.WLD3)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    unitConfig.ConditionPathExists = "/proc/acpi/call";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${vaioLidOpenResume}";
    };
  };

  # Re-apply after S3/S4 resume in case EC/firmware resets WLD3.
  powerManagement.resumeCommands = ''
    if [ -w /proc/acpi/call ]; then
      ${vaioLidOpenResume} || true
    fi
  '';

  # Intel Wi-Fi 6 AX200 [8086:2723] hits frequent PCIe AER BadTLP correctable errors
  # with L1 ASPM / ClkPM enabled on this Ice Lake root port. Disable link ASPM L1/ClkPM
  # specifically for this device rather than disabling system-wide ASPM.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2723", TEST=="link/l1_2_aspm", ATTR{link/l1_2_aspm}="0"
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2723", TEST=="link/l1_1_aspm", ATTR{link/l1_1_aspm}="0"
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2723", TEST=="link/l1_aspm", ATTR{link/l1_aspm}="0"
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x2723", TEST=="link/clkpm", ATTR{link/clkpm}="0"
  '';
}
