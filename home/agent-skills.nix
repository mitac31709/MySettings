# Declarative AI agent skills & Ponytail plugin configuration.
# Sources are pinned via flake inputs (updated together by `flake-update`) and
# fanned out to ~/.agents/skills, Claude Code, Codex, OpenCode, Cursor,
# Antigravity CLI / T3 Code, and Hermes Agent.
{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # Map of <skill-name> -> store path containing SKILL.md.
  # Add new flake-pinned skills here to fan them out to all agents.
  declaredSkills =
    (lib.genAttrs [
      "ponytail"
      "ponytail-audit"
      "ponytail-debt"
      "ponytail-gain"
      "ponytail-help"
      "ponytail-review"
    ] (name: "${inputs.ponytail}/skills/${name}"))
    // (lib.genAttrs [
      "agent-desktop"
      "agent-desktop-linux"
    ] (name: "${inputs.agent-desktop-skills}/skills/${name}"))
    // (lib.genAttrs [
      "afk"
      "better-accessibility"
      "better-colors"
      "better-interface"
      "better-layout"
      "better-motion"
      "better-typography"
      "better-ui"
      "better-writing"
      "break"
      "build-design"
      "explain-interface"
      "interface-review"
      "state-machine"
      "upskill"
      "variant"
    ] (name: "${inputs.jakubkrehel-skills}/skills/${name}"))
    // {
      "ops-advisor" = ./skills/ops-advisor;
    };

  opsAdvisorCollect = pkgs.writeShellApplication {
    name = "ops-advisor-collect";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gawk
      gnugrep
      gnused
      jq
      ripgrep
      sqlite
    ];
    text = builtins.readFile ./skills/ops-advisor/scripts/collect.sh;
  };

  skillNames = builtins.attrNames declaredSkills;

  # Target directories whose entries can be managed directly via home.file.
  skillTargetDirs = [
    ".agents/skills"
    ".config/claude/skills"
    ".gemini/config/skills"
    ".local/share/hermes/skills"
  ];

  skillFiles = lib.foldl' (
    acc: dir:
    acc
    // (lib.mapAttrs' (
      name: src:
      lib.nameValuePair "${dir}/${name}" {
        source = src;
        force = true;
      }
    ) declaredSkills)
  ) { } skillTargetDirs;

  managedDirs = (lib.concatMap (dir: map (name: "${dir}/${name}") skillNames) skillTargetDirs) ++ [
    ".local/share/hermes/plugins/ponytail"
    ".gemini/config/plugins/ponytail"
  ];

  ponytailRoot = "${inputs.ponytail}";

  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  syncScript = pkgs.writeShellApplication {
    name = "agent-skills-sync-declared-config";
    runtimeInputs = [ pythonWithYaml ];
    text = ''
      python3 - \
        ${lib.escapeShellArg ponytailRoot} \
        '${builtins.toJSON skillNames}' <<'PY'
      import glob
      import json
      import os
      import re
      import sys
      import tempfile
      import tomllib
      from pathlib import Path

      import yaml

      ponytail_root = sys.argv[1]
      skill_names = json.loads(sys.argv[2])
      home = Path.home()
      xdg_config = Path(os.environ.get("XDG_CONFIG_HOME") or (home / ".config"))
      xdg_data = Path(os.environ.get("XDG_DATA_HOME") or (home / ".local" / "share"))
      claude_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (xdg_config / "claude"))
      codex_dir = Path(os.environ.get("CODEX_HOME") or (xdg_config / "codex"))
      hermes_dir = Path(os.environ.get("HERMES_HOME") or (xdg_data / "hermes"))
      t3_home = Path(os.environ.get("T3CODE_HOME") or (xdg_data / "t3"))


      def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
          path.parent.mkdir(parents=True, exist_ok=True)
          fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
          try:
              with os.fdopen(fd, "w", encoding="utf-8") as fh:
                  fh.write(content)
              os.chmod(tmp, mode)
              os.replace(tmp, path)
          except Exception:
              os.unlink(tmp)
              raise


      def load_json(path: Path) -> dict:
          if not path.is_file():
              return {}
          raw = path.read_text(encoding="utf-8").strip()
          return json.loads(raw) if raw else {}


      def save_json_if_changed(path: Path, existing: dict, merged: dict) -> None:
          if path.is_symlink():
              return
          if path.is_file() and merged == existing:
              return
          atomic_write(path, json.dumps(merged, indent=2, ensure_ascii=False) + "\n")


      # 1. Cursor hooks (~/.cursor/hooks.json)
      def sync_cursor_hooks() -> None:
          path = home / ".cursor" / "hooks.json"
          if path.is_symlink():
              return
          existing = load_json(path)
          merged = json.loads(json.dumps(existing))
          merged.setdefault("version", 1)
          hooks = merged.setdefault("hooks", {})

          desired = {
              "sessionStart": (
                  "ponytail-activate.js",
                  f'node "{ponytail_root}/hooks/ponytail-activate.js"',
              ),
              "beforeSubmitPrompt": (
                  "ponytail-mode-tracker.js",
                  f'node "{ponytail_root}/hooks/ponytail-mode-tracker.js"',
              ),
          }

          for event, (marker, cmd) in desired.items():
              entries = list(hooks.get(event) or [])
              entries = [
                  e for e in entries
                  if not (isinstance(e, dict) and marker in str(e.get("command", "")))
              ]
              entries.append({"command": cmd, "timeout": 15})
              hooks[event] = entries

          save_json_if_changed(path, existing, merged)


      # 2. OpenCode (~/.config/opencode/opencode.json)
      def sync_opencode_plugin() -> None:
          path = xdg_config / "opencode" / "opencode.json"
          if path.is_symlink():
              return
          existing = load_json(path)
          merged = json.loads(json.dumps(existing))
          plugins = list(merged.get("plugins") or [])
          target = f"{ponytail_root}/.opencode/plugins"
          plugins = [
              p for p in plugins
              if not (
                  isinstance(p, str)
                  and (
                      p == "@dietrichgebert/ponytail"
                      or p.endswith("/.opencode/plugins") and "ponytail" in p
                  )
              )
          ]
          plugins.append(target)
          merged["plugins"] = plugins
          save_json_if_changed(path, existing, merged)


      # 3. Claude Code ($CLAUDE_CONFIG_DIR/settings.json)
      def sync_claude_settings() -> None:
          path = claude_dir / "settings.json"
          if path.is_symlink():
              return
          existing = load_json(path)
          merged = json.loads(json.dumps(existing))
          mkts = merged.setdefault("extraKnownMarketplaces", {})
          mkts["ponytail"] = {
              "source": {
                  "source": "github",
                  "repo": "DietrichGebert/ponytail",
              }
          }
          enabled = merged.setdefault("enabledPlugins", {})
          enabled.setdefault("ponytail@ponytail", True)
          save_json_if_changed(path, existing, merged)


      # 4. Codex ($CODEX_HOME/config.toml)
      def sync_codex_config() -> None:
          path = codex_dir / "config.toml"
          if path.is_symlink():
              return
          raw = path.read_text(encoding="utf-8") if path.is_file() else ""
          data = tomllib.loads(raw) if raw.strip() else {}
          additions = []
          if "ponytail" not in (data.get("marketplaces") or {}):
              additions.append(
                  '\n[marketplaces.ponytail]\n'
                  'source_type = "git"\n'
                  'source = "https://github.com/DietrichGebert/ponytail.git"\n'
              )
          if "ponytail@ponytail" not in (data.get("plugins") or {}):
              additions.append(
                  '\n[plugins."ponytail@ponytail"]\n'
                  'enabled = true\n'
              )
          if additions:
              new_raw = raw.rstrip("\n") + ("\n" if raw.strip() else "") + "".join(additions)
              atomic_write(path, new_raw)


      # 5. Hermes Agent ($HERMES_HOME/config.yaml)
      def sync_hermes_config() -> None:
          path = hermes_dir / "config.yaml"
          if path.is_symlink() or not path.parent.exists():
              return
          raw = path.read_text(encoding="utf-8") if path.is_file() else ""
          data = yaml.safe_load(raw) if raw.strip() else {}
          if not isinstance(data, dict):
              return
          plugins = data.get("plugins")
          if not isinstance(plugins, dict):
              plugins = {}
              data["plugins"] = plugins
          enabled = list(plugins.get("enabled") or [])
          if "ponytail" in enabled:
              return
          enabled.append("ponytail")
          plugins["enabled"] = enabled
          # Append minimal YAML block when no plugins section existed yet to preserve formatting.
          if not re.search(r"(?m)^plugins\s*:", raw):
              new_raw = raw.rstrip("\n") + ("\n" if raw.strip() else "") + "plugins:\n  enabled:\n    - ponytail\n"
              atomic_write(path, new_raw)
          else:
              atomic_write(path, yaml.safe_dump(data, sort_keys=False, allow_unicode=True))


      # 6. T3 Code Antigravity provider skills ($T3CODE_HOME/userdata/providers/antigravity/*/config/skills)
      def sync_t3_antigravity_skills() -> None:
          roots = [t3_home]
          legacy = home / ".t3"
          if legacy != t3_home:
              roots.append(legacy)
          for root in roots:
              pattern = str(root / "userdata" / "providers" / "antigravity" / "*" / "config")
              for cfg_dir in glob.glob(pattern):
                  skills_dir = Path(cfg_dir) / "skills"
                  skills_dir.mkdir(parents=True, exist_ok=True)
                  for name in skill_names:
                      target = home / ".agents" / "skills" / name
                      link = skills_dir / name
                      if link.is_symlink():
                          if os.readlink(link) == str(target):
                              continue
                          link.unlink()
                      elif link.exists():
                          continue
                      link.symlink_to(target)


      sync_cursor_hooks()
      sync_opencode_plugin()
      sync_claude_settings()
      sync_codex_config()
      sync_hermes_config()
      sync_t3_antigravity_skills()
      PY
    '';
  };
in
{
  home.packages = [ opsAdvisorCollect ];

  home.file = skillFiles // {
    # Hermes Agent & Antigravity CLI native plugin directories from the pinned flake input.
    ".local/share/hermes/plugins/ponytail" = {
      source = inputs.ponytail;
      force = true;
    };
    ".gemini/config/plugins/ponytail" = {
      source = inputs.ponytail;
      force = true;
    };
  };

  # Replace pre-existing real directories (from earlier imperative `npx skills` /
  # `git clone` installs) before Home Manager's link check so `.backup` copies
  # don't linger inside plugin/skill scan directories.
  home.activation.cleanupImperativeAgentSkills = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    for rel in ${lib.concatMapStringsSep " " lib.escapeShellArg managedDirs}; do
      target="$HOME/$rel"
      if [ -d "$target" ] && [ ! -L "$target" ]; then
        $DRY_RUN_CMD rm -rf "$target"
      fi
    done
  '';

  home.activation.syncAgentSkillsConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${syncScript}/bin/agent-skills-sync-declared-config || true
  '';
}
