# UniClipboard: sync clipboard with Windows (and other devices).
# Pair once in the GUI (`uniclipboard`); uniclipd keeps syncing in the background.
#
# uniclipd must remain an unwrapped binary named exactly `uniclipd` — the GUI
# rejects Nix makeWrapper names (`.uniclipd-wrapped`) as a mismatched daemon.
#
# Needs an unlocked org.freedesktop.secrets (gnome-keyring). KWallet's ksecretd
# rejects UniClipboard's binary integrity probe.
{
  lib,
  pkgs,
  flakeTarget ? "chromebook",
  ...
}:

let
  ensureDeviceNameScript = pkgs.writeShellApplication {
    name = "uniclipboard-ensure-device-name";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      cfg="''${XDG_DATA_HOME:-$HOME/.local/share}/app.uniclipboard.desktop/settings.json"
      target_name=${lib.escapeShellArg flakeTarget}
      python3 - "$cfg" "$target_name" <<'PY'
      import json
      import os
      import stat
      import sys
      import tempfile
      from pathlib import Path

      cfg_path = Path(sys.argv[1])
      target_name = sys.argv[2]
      if not cfg_path.is_file() or cfg_path.is_symlink():
          raise SystemExit(0)

      try:
          data = json.loads(cfg_path.read_text(encoding="utf-8"))
      except Exception:
          raise SystemExit(0)

      if not isinstance(data, dict):
          raise SystemExit(0)
      general = data.get("general")
      if not isinstance(general, dict):
          raise SystemExit(0)

      cur = general.get("device_name")
      # Replace generic/cloned host defaults while preserving custom user names.
      if cur not in (None, "", "NixOS", "chromebook", "vaio") or cur == target_name:
          raise SystemExit(0)

      general["device_name"] = target_name
      mode = stat.S_IMODE(cfg_path.stat().st_mode)
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
      PY
    '';
  };
in
{
  home.packages = [
    pkgs.uniclipboard
    pkgs.seahorse # unlock Default Keyring when PAM did not (engine 1223)
  ];

  home.activation.ensureUniClipboardDeviceName = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${ensureDeviceNameScript}/bin/uniclipboard-ensure-device-name || true
  '';

  # Start secrets component for this user session (PAM also unlocks at login).
  services.gnome-keyring = {
    enable = true;
    components = [ "secrets" ];
  };

  systemd.user.services.uniclipd = {
    Unit = {
      Description = "UniClipboard sync daemon";
      After = [ "graphical-session.target" ];
      BindsTo = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${pkgs.uniclipboard}/bin/uniclipd";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
