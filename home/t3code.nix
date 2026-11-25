# Declarative overrides for T3 Code writable settings.json.
# Keeps $T3CODE_HOME/userdata/settings.json writable so in-app Settings changes work
# without EROFS, while reproducing declared provider binary paths.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  syncScript = pkgs.writeShellApplication {
    name = "t3code-sync-declared-config";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      t3_home="''${T3CODE_HOME:-${config.xdg.dataHome}/t3}"
      if [ ! -d "$t3_home" ] && [ -d "$HOME/.t3" ]; then
        t3_home="$HOME/.t3"
      fi
      settings_file="$t3_home/userdata/settings.json"
      python3 - "$settings_file" <<'PY'
      import json
      import os
      import sys
      import tempfile
      from pathlib import Path

      path = Path(sys.argv[1])
      if path.is_symlink():
          sys.exit(0)

      existing: dict = {}
      if path.is_file():
          raw = path.read_text(encoding="utf-8").strip()
          if raw:
              existing = json.loads(raw)

      merged = json.loads(json.dumps(existing))
      # Usage-limit stops should auto-continue when the provider reports a reset time.
      merged["autoResumeLimitedThreads"] = True
      instances = merged.setdefault("providerInstances", {})
      ag = instances.setdefault("antigravity", {})
      ag["driver"] = "antigravity"
      ag.setdefault("enabled", True)
      cfg = ag.setdefault("config", {})
      # Point T3 Code at the native `antigravity` CLI (v1.5+) instead of the
      # downloaded 1.4.5 `agy_acp_server.par` bundle, which omits Orchestrator models.
      cfg["binaryPath"] = "antigravity"

      if path.is_file() and merged == existing:
          sys.exit(0)

      path.parent.mkdir(parents=True, exist_ok=True)
      fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
      try:
          with os.fdopen(fd, "w", encoding="utf-8") as fh:
              fh.write(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")
          os.chmod(tmp, 0o600)
          os.replace(tmp, path)
      except Exception:
          os.unlink(tmp)
          raise
      PY
    '';
  };
in
{
  home.activation.syncT3CodeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${syncScript}/bin/t3code-sync-declared-config || true
  '';
}
