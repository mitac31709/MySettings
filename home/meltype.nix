# Meltype AppRules (config.json) — control per-app IME via settings, not fcitx wrappers.
# - Cursor / Ghostty: General (Japanese; Code resets to 英数 on arrow keys)
# - rofi: Wayland IC has empty program → fcitx5-empty-program.patch labels it "_empty";
#   Enabled=false here keeps the filter ASCII-only
{
  config,
  lib,
  pkgs,
  ...
}:

let
  meltypeDir = "${config.home.homeDirectory}/.local/share/Meltype";
  defaultsFile = ./meltype-app-rules-defaults.json;

  ensureAppRules = pkgs.writeShellApplication {
    name = "meltype-ensure-app-rules";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      dir=${lib.escapeShellArg meltypeDir}
      mkdir -p "$dir"
      config="$dir/config.json"
      defaults=${lib.escapeShellArg "${defaultsFile}"}
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT

      if [ ! -f "$config" ]; then
        printf '%s\n' '{"SettingsVersion":10}' >"$config"
      fi

      jq \
        --slurpfile defaults "$defaults" \
        --argjson rules '[
          {"Process":"com.mitchellh.ghostty","Enabled":true,"Profile":"General","Kind":null,"Commit":"Auto","TextInput":false},
          {"Process":"ghostty","Enabled":true,"Profile":"General","Kind":null,"Commit":"Auto","TextInput":false},
          {"Process":"cursor","Enabled":true,"Profile":"General","Kind":null,"Commit":"Auto","TextInput":false},
          {"Process":"_empty","Enabled":false,"Profile":"General","Kind":null,"Commit":"Auto","TextInput":false},
          {"Process":"rofi","Enabled":false,"Profile":"General","Kind":null,"Commit":"Auto","TextInput":false}
        ]' '
        .SettingsVersion = (.SettingsVersion // 10)
        | .ModeIndicator = (.ModeIndicator // "OnSwitchAndFocus")
        | .ZSymbols = true
        | (
            if (.AppRules | type) == "array" and (.AppRules | length) > 0 then .AppRules
            elif ($defaults | length) > 0 and ($defaults[0].AppRules | type) == "array"
            then $defaults[0].AppRules
            else []
            end
          ) as $base
        | .AppRules = (
            reduce $rules[] as $rule (
              $base;
              (map(select((.Process | ascii_downcase) != ($rule.Process | ascii_downcase))) + [$rule])
            )
          )
      ' "$config" >"$tmp"
      mv -f "$tmp" "$config"
      chmod 600 "$config"
    '';
  };
in
{
  home.packages = [ ensureAppRules ];

  home.activation.meltypeAppRules = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe ensureAppRules}
  '';
}
