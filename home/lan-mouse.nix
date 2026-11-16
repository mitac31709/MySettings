# Lan Mouse: software KVM across Windows (galleria-mitac) and vaio -> chromebook.
#
# This home-manager pin has no programs.lan-mouse module, and runtime pairing
# writes ~/.config/lan-mouse/config.toml (authorized_fingerprints / clients).
# Per-host private keys (lan-mouse.pem) live in agenix (`secrets/lan-mouse-<host>.pem.age`)
# and are symlinked via home/secrets.nix; activation ensures the declared
# authorized_fingerprints and [[clients]] entries exist while keeping config.toml
# writable for GUI adjustments.
{
  config,
  lib,
  pkgs,
  flakeTarget ? "chromebook",
  ...
}:

let
  lanMouse = import ../lib/lan-mouse.nix;
  desiredFingerprints = lanMouse.authorizedFingerprints;
  desiredClients = lanMouse.clientsByHost.${flakeTarget} or [ ];

  ensureScript = pkgs.writeShellApplication {
    name = "lan-mouse-ensure-config";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/lan-mouse/config.toml"
      desired_fps='${builtins.toJSON desiredFingerprints}'
      desired_clients='${builtins.toJSON desiredClients}'
      python3 - "$cfg" "$desired_fps" "$desired_clients" <<'PY'
      import json
      import os
      import re
      import sys
      import tempfile
      import tomllib
      from pathlib import Path

      cfg_path = Path(sys.argv[1])
      desired_fps = json.loads(sys.argv[2])
      desired_clients = json.loads(sys.argv[3])

      text = cfg_path.read_text(encoding="utf-8") if cfg_path.is_file() else ""
      try:
          parsed = tomllib.loads(text) if text.strip() else {}
      except tomllib.TOMLDecodeError:
          parsed = {}

      lines = text.splitlines()
      section_re = re.compile(r"^\s*\[+([^\]]+)\]+\s*(?:#.*)?$")
      key_re = re.compile(r'^\s*"([^"]+)"\s*=')

      existing_fps = set()
      raw_fps = parsed.get("authorized_fingerprints")
      if isinstance(raw_fps, dict):
          existing_fps.update(str(k).lower() for k in raw_fps.keys())

      section_start = None
      section_end = len(lines)
      cur_section = None
      for idx, line in enumerate(lines):
          m = section_re.match(line)
          if m:
              if cur_section == "authorized_fingerprints" and section_end == len(lines):
                  section_end = idx
              cur_section = m.group(1).strip()
              if cur_section == "authorized_fingerprints" and section_start is None:
                  section_start = idx
              continue
          if cur_section == "authorized_fingerprints":
              km = key_re.match(line)
              if km:
                  existing_fps.add(km.group(1).lower())

      missing_fps = [
          f'"{fp}" = {json.dumps(name)}'
          for fp, name in desired_fps.items()
          if fp.lower() not in existing_fps
      ]

      if missing_fps:
          if section_start is None:
              if lines and lines[-1].strip():
                  lines.append("")
              lines.append("[authorized_fingerprints]")
              lines.extend(missing_fps)
          else:
              insert_at = section_end
              while insert_at > section_start + 1 and not lines[insert_at - 1].strip():
                  insert_at -= 1
              lines = lines[:insert_at] + missing_fps + lines[insert_at:]

      existing_clients = parsed.get("clients")
      if not isinstance(existing_clients, list):
          existing_clients = []

      def client_matches(existing: dict, target: dict) -> bool:
          if not isinstance(existing, dict):
              return False
          t_host = target.get("hostname")
          if t_host and existing.get("hostname") == t_host:
              return True
          t_ips = set(target.get("ips") or [])
          e_ips = set(existing.get("ips") or [])
          return bool(t_ips and (t_ips & e_ips))

      def format_toml_value(val) -> str:
          if isinstance(val, bool):
              return "true" if val else "false"
          if isinstance(val, int):
              return str(val)
          if isinstance(val, str):
              return json.dumps(val)
          if isinstance(val, list):
              return "[ " + ", ".join(format_toml_value(item) for item in val) + " ]"
          raise TypeError(f"Unsupported TOML value: {type(val)}")

      client_order = ("hostname", "position", "ips", "port", "activate_on_startup")
      missing_clients = [
          c for c in desired_clients
          if not any(client_matches(ec, c) for ec in existing_clients)
      ]

      for client in missing_clients:
          if lines and lines[-1].strip():
              lines.append("")
          lines.append("[[clients]]")
          for key in client_order:
              if key in client:
                  lines.append(f"{key} = {format_toml_value(client[key])}")
          for key, val in client.items():
              if key not in client_order:
                  lines.append(f"{key} = {format_toml_value(val)}")

      new_text = "\n".join(lines) + ("\n" if lines else "")
      if new_text == text:
          raise SystemExit(0)

      cfg_path.parent.mkdir(parents=True, exist_ok=True)
      fd, tmp = tempfile.mkstemp(dir=str(cfg_path.parent), prefix=".config.toml.")
      try:
          with os.fdopen(fd, "w", encoding="utf-8") as fh:
              fh.write(new_text)
          os.chmod(tmp, 0o600)
          os.replace(tmp, cfg_path)
      except Exception:
          os.unlink(tmp)
          raise
      PY
    '';
  };
in
{
  home.packages = [ pkgs.lan-mouse ];

  home.activation.ensureLanMouseConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${ensureScript}/bin/lan-mouse-ensure-config || true
  '';

  systemd.user.services.lan-mouse = {
    Unit = {
      Description = "Lan Mouse (software KVM)";
      After = [ "graphical-session.target" ];
      BindsTo = [ "graphical-session.target" ];
      StartLimitIntervalSec = 30;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${pkgs.lan-mouse}/bin/lan-mouse daemon";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
