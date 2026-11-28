# Shared laptop power management: zram, thermald, auto-cpufreq, power-chords, power-save CPU units.
{ pkgs, ... }:

let
  autoCpufreqBin = "${pkgs.auto-cpufreq}/bin/auto-cpufreq";

  powerSaveCpuOn = pkgs.writeShellScript "power-save-cpu-on" ''
    set -euo pipefail
    ${autoCpufreqBin} --force=powersave
    ${autoCpufreqBin} --turbo=never || true
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      [ -w "$f" ] && printf 'power\n' > "$f" 2>/dev/null || true
    done
  '';

  powerSaveCpuOff = pkgs.writeShellScript "power-save-cpu-off" ''
    set -euo pipefail
    ${autoCpufreqBin} --force=reset
    ${autoCpufreqBin} --turbo=auto || true
    ac_online=0
    for ps in /sys/class/power_supply/*; do
      [ -r "$ps/type" ] || continue
      case "$(cat "$ps/type")" in
        Mains|USB|USB_PD|USB_C)
          if [ -r "$ps/online" ] && [ "$(cat "$ps/online")" = "1" ]; then
            ac_online=1
            break
          fi
          ;;
      esac
    done
    target_epp="balance_power"
    [ "$ac_online" = "1" ] && target_epp="balance_performance"
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      [ -w "$f" ] && printf '%s\n' "$target_epp" > "$f" 2>/dev/null || true
    done
  '';
in
{
  imports = [ ./power-chords.nix ];

  # zram at 100% of RAM (zstd) gives compressed memory swap without a swapfile.
  zramSwap = {
    enable = true;
    memoryPercent = 100;
    algorithm = "zstd";
  };

  # zram-friendly VM knobs: swap earlier into cheap compressed RAM, avoid
  # reading ahead multiple pages from zram (page-cluster=0).
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.vfs_cache_pressure" = 50;
  };

  # Sustained performance under Intel laptop thermal limits.
  services.thermald.enable = true;

  # Expose battery / power-supply state over org.freedesktop.UPower for
  # WirePlumber, Bluetooth battery reporting, and desktop portals.
  services.upower.enable = true;

  # auto-cpufreq manages governors/turbo; conflicts with power-profiles-daemon.
  services.power-profiles-daemon.enable = false;
  services.auto-cpufreq = {
    enable = true;
    settings = {
      charger = {
        governor = "performance";
        turbo = "auto";
      };
      battery = {
        governor = "powersave";
        turbo = "auto";
      };
    };
  };

  # Oneshot CPU profile switches invoked by user-space `power-save` without sudo prompts.
  systemd.services.power-save-cpu-on = {
    description = "Apply power-save CPU profile (powersave + no turbo + EPP=power)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${powerSaveCpuOn}";
    };
  };

  systemd.services.power-save-cpu-off = {
    description = "Restore normal CPU profile (auto-cpufreq auto + balanced EPP)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${powerSaveCpuOff}";
    };
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          (action.lookup("unit") == "power-save-cpu-on.service" ||
           action.lookup("unit") == "power-save-cpu-off.service") &&
          action.lookup("verb") == "start" &&
          subject.isInGroup("wheel")) {
        return polkit.Result.YES;
      }
    });
  '';
}
