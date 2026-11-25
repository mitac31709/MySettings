# RQuickShare writes ~/.config/autostart/RQuickShare.desktop with a hardcoded
# /nix/store/... path that breaks after upgrades/GC. Rewrite Exec= to the
# stable per-user profile symlink (same approach as vivaldi-pwa-desktop.nix).
#
# Also keep startminimized=true so login autostart lands in the tray without
# popping the main window (RQuickShare rewrites .settings.json itself).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  rquickshareBin = "${config.home.profileDirectory}/bin/rquickshare";

  fixDesktopScript = pkgs.writeShellApplication {
    name = "rquickshare-desktop-fix";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      set -euo pipefail
      autostart="''${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
      desktop="$autostart/RQuickShare.desktop"
      target='${rquickshareBin}'
      if [[ ! -e "$target" || -L "$desktop" || ! -f "$desktop" ]]; then
        exit 0
      fi
      if ! grep -qE '^Exec=/nix/store/[^ ]*rquickshare' "$desktop"; then
        exit 0
      fi
      tmp="$(mktemp)"
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          Exec=/nix/store/*rquickshare*)
            args="''${line#Exec=}"
            args="''${args%"''${args##*[![:space:]]}"}"
            rest="''${args#* }"
            if [[ "$args" == "$rest" ]]; then
              printf 'Exec=%s\n' "$target"
            else
              printf 'Exec=%s %s\n' "$target" "$rest"
            fi
            ;;
          *)
            printf '%s\n' "$line"
            ;;
        esac
      done <"$desktop" >"$tmp"
      if ! cmp -s "$desktop" "$tmp"; then
        mv "$tmp" "$desktop"
        echo "Fixed RQuickShare autostart desktop: $desktop"
      else
        rm -f "$tmp"
      fi
    '';
  };

  ensureMinimizedScript = pkgs.writeShellApplication {
    name = "rquickshare-ensure-minimized";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      set -euo pipefail
      cfg="''${XDG_DATA_HOME:-$HOME/.local/share}/dev.mandre.rquickshare/.settings.json"
      python3 - "$cfg" <<'PY'
      import json
      import os
      import stat
      import sys
      import tempfile
      from pathlib import Path

      cfg_path = Path(sys.argv[1])
      cfg_path.parent.mkdir(parents=True, exist_ok=True)

      data: dict = {}
      mode = 0o644
      if cfg_path.is_file() and not cfg_path.is_symlink():
          mode = stat.S_IMODE(cfg_path.stat().st_mode)
          try:
              loaded = json.loads(cfg_path.read_text(encoding="utf-8"))
              if isinstance(loaded, dict):
                  data = loaded
          except Exception:
              pass

      if data.get("startminimized") is True:
          raise SystemExit(0)

      data["startminimized"] = True
      data.setdefault("autostart", True)
      data.setdefault("realclose", False)
      data.setdefault("visibility", 0)

      fd, tmp = tempfile.mkstemp(dir=str(cfg_path.parent), prefix=".settings.json.")
      try:
          with os.fdopen(fd, "w", encoding="utf-8") as fh:
              json.dump(data, fh, ensure_ascii=False, indent=2)
              fh.write("\n")
          os.chmod(tmp, mode)
          os.replace(tmp, cfg_path)
      except Exception:
          os.unlink(tmp)
          raise
      print(f"Set RQuickShare startminimized=true: {cfg_path}")
      PY
    '';
  };
in
{
  home.activation.fixRQuickShareDesktop = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${fixDesktopScript}/bin/rquickshare-desktop-fix || true
  '';

  home.activation.ensureRQuickShareMinimized = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${ensureMinimizedScript}/bin/rquickshare-ensure-minimized || true
  '';

  systemd.user.services.rquickshare-desktop-fix = {
    Unit = {
      Description = "Rewrite RQuickShare autostart .desktop Exec path to current profile";
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${fixDesktopScript}/bin/rquickshare-desktop-fix";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  systemd.user.services.rquickshare-ensure-minimized = {
    Unit = {
      Description = "Ensure RQuickShare starts minimized to tray";
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${ensureMinimizedScript}/bin/rquickshare-ensure-minimized";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
