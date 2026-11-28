# Workspace 10 TUI/CLI dashboard: 6 tiled Ghostty windows launched on demand via ws10-dashboard.
# Windows: btop, OS details (fastfetch), system/service monitor, yazi, nmtui, and shell.
{
  lib,
  pkgs,
  ...
}:

let
  ghosttyBin = "${pkgs.ghostty}/bin/ghostty";
  hyprctlBin = "${pkgs.hyprland}/bin/hyprctl";
  btopBin = "${pkgs.btop}/bin/btop";
  yaziBin = "${pkgs.yazi}/bin/yazi";
  nmtuiBin = "${pkgs.networkmanager}/bin/nmtui";
  bashBin = "${pkgs.bash}/bin/bash";

  osInfoPane = pkgs.writeShellApplication {
    name = "ws10-osinfo";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.fastfetch
      pkgs.gawk
    ];
    text = ''
      render() {
        printf '\033[2J\033[H'
        fastfetch --logo-padding-right 2 || true
        printf '\n\033[1;36m── NixOS Generation ────────────────────────\033[0m\n'
        cur_sys="$(readlink -f /run/current-system 2>/dev/null || true)"
        if [ -n "$cur_sys" ]; then
          printf '  System: %s\n' "$(basename "$cur_sys")"
        fi
        if [ -r /etc/nixos-version ]; then
          printf '  Version: %s\n' "$(cat /etc/nixos-version)"
        fi
        printf '\n\033[1;36m── Disk Usage ──────────────────────────────\033[0m\n'
        df -h -x tmpfs -x devtmpfs -x efivarfs --output=target,size,used,avail,pcent / /home 2>/dev/null | awk '!seen[$0]++' || df -h /
        printf '\n\033[2mUpdated: %s  [r: refresh / q: quit]\033[0m\n' "$(date '+%H:%M:%S')"
      }

      while true; do
        render
        key=""
        IFS= read -rsn1 -t 30 key || true
        case "$key" in
          q|Q) exit 0 ;;
        esac
      done
    '';
  };

  servicesPane = pkgs.writeShellApplication {
    name = "ws10-services";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.systemd
      pkgs.tailscale
    ];
    text = ''
      fmt_state() {
        local state="$1"
        case "$state" in
          active)   printf '\033[32m● %-10s\033[0m' "$state" ;;
          activating|reloading) printf '\033[33m◐ %-10s\033[0m' "$state" ;;
          inactive|deactivating) printf '\033[2m○ %-10s\033[0m' "$state" ;;
          *)        printf '\033[31m✖ %-10s\033[0m' "''${state:-unknown}" ;;
        esac
      }

      show_unit() {
        local scope="$1"
        local unit="$2"
        local label="$3"
        local st
        if [ "$scope" = "user" ]; then
          st="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
        else
          st="$(systemctl is-active "$unit" 2>/dev/null || true)"
        fi
        printf '  %-22s %s\n' "$label" "$(fmt_state "''${st:-n/a}")"
      }

      render() {
        printf '\033[2J\033[H'
        printf '\033[1;36m── System Services ─────────────────────────\033[0m\n'
        show_unit system NetworkManager.service "NetworkManager"
        show_unit system keyd.service "keyd"
        show_unit system capsomnia-helperd.service "capsomnia-helperd"
        show_unit system tailscaled.service "tailscaled"
        show_unit system restic-backups-home.timer "restic-backup.timer"

        printf '\n\033[1;36m── User Services ───────────────────────────\033[0m\n'
        show_unit user colorshell.service "colorshell"
        show_unit user agent-run-status.service "agent-run-status"
        show_unit user uniclipd.service "uniclipd"
        show_unit user lan-mouse.service "lan-mouse"
        show_unit user taildrop-receive.service "taildrop-receive"
        show_unit user jquake.service "jquake"

        printf '\n\033[1;36m── Tailscale ───────────────────────────────\033[0m\n'
        if ts_json="$(tailscale status --json --peers=false 2>/dev/null)"; then
          ts_state="$(printf '%s' "$ts_json" | jq -r '.BackendState // "unknown"')"
          ts_ip="$(printf '%s' "$ts_json" | jq -r '.Self.TailscaleIPs[0] // "-"')"
          ts_name="$(printf '%s' "$ts_json" | jq -r '.Self.HostName // "-"')"
          printf '  State: %s   Host: %s (%s)\n' "$ts_state" "$ts_name" "$ts_ip"
        else
          printf '  \033[2m(tailscale unavailable)\033[0m\n'
        fi

        printf '\n\033[1;36m── Recent Warnings (journalctl) ────────────\033[0m\n'
        journalctl -p warning..emerg -n 6 --no-pager --output=short-monotonic 2>/dev/null \
          || journalctl --user -n 6 --no-pager --output=short-monotonic 2>/dev/null \
          || true

        printf '\n\033[2mUpdated: %s  [r: refresh / j: live journal / q: quit]\033[0m\n' "$(date '+%H:%M:%S')"
      }

      while true; do
        render
        key=""
        IFS= read -rsn1 -t 10 key || true
        case "$key" in
          q|Q) exit 0 ;;
          j|J)
            printf '\033[2J\033[H\033[1;36m── Live journalctl --user (Ctrl+C to return) ──\033[0m\n'
            journalctl --user -f -n 30 --no-pager || true
            ;;
        esac
      done
    '';
  };

  ws10Dashboard = pkgs.writeShellApplication {
    name = "ws10-dashboard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      autostart=0
      reset=0
      for arg in "$@"; do
        case "$arg" in
          --autostart) autostart=1 ;;
          --reset) reset=1 ;;
          -h|--help)
            printf 'Usage: ws10-dashboard [--autostart] [--reset]\n'
            exit 0
            ;;
        esac
      done

      if [ "$autostart" -eq 1 ]; then
        sleep 1.5
      fi

      if [ "$reset" -eq 1 ]; then
        ${hyprctlBin} clients -j 2>/dev/null \
          | jq -r '.[] | select(.class | startswith("ws10.")) | .address' \
          | while IFS= read -r addr; do
              [ -n "$addr" ] || continue
              ${hyprctlBin} dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null 2>&1 || true
            done
        sleep 0.3
      fi

      existing="$(${hyprctlBin} clients -j 2>/dev/null | jq -r '.[].class' 2>/dev/null || true)"
      has_class() {
        printf '%s\n' "$existing" | grep -Fxq "$1"
      }

      spawn_tile() {
        local cls="$1"
        local title="$2"
        shift 2
        if has_class "$cls"; then
          return 0
        fi
        ${ghosttyBin} \
          --gtk-single-instance=false \
          --class="$cls" \
          --title="$title" \
          --font-size=10 \
          --window-padding-x=8 \
          --window-padding-y=6 \
          -e "$@" >/dev/null 2>&1 &
        sleep 0.15
      }

      spawn_tile "ws10.btop"     "WS10 · btop"     ${btopBin}
      spawn_tile "ws10.osinfo"   "WS10 · OS Info"  ${lib.getExe osInfoPane}
      spawn_tile "ws10.services" "WS10 · Services" ${lib.getExe servicesPane}
      spawn_tile "ws10.yazi"     "WS10 · yazi"     ${yaziBin}
      spawn_tile "ws10.nmtui"    "WS10 · nmtui"    ${nmtuiBin}
      spawn_tile "ws10.shell"    "WS10 · Shell"    ${bashBin} -i
    '';
  };
in
{
  home.packages = [
    pkgs.fastfetch
    ws10Dashboard
  ];

  wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
    -- Workspace 10 TUI/CLI dashboard tiles (placed silently on WS 10)
    hl.window_rule({
      name = "ws10-dashboard-tiles",
      match = { class = "^ws10\\..+$" },
      workspace = "10 silent",
    })
  '';
}
