# On-demand PLaMo 3 Translate 0.8B backend and Antigravity (`agy`) live watcher.
{
  lib,
  pkgs,
  ...
}:

let
  pyBin =
    name: file:
    pkgs.writers.writePython3Bin name {
      libraries = [ ];
      doCheck = false;
    } (builtins.readFile file);

  plamoTranslatePy = pyBin "plamo-translate-py" ../scripts/plamo-translate.py;
  agyTranslateWatchPy = pyBin "agy-translate-watch-py" ../scripts/agy-translate-watch.py;

  plamoTranslate = pkgs.writeShellApplication {
    name = "plamo-translate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.llama-cpp
    ];
    text = ''
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export PLAMO_LLAMA_SERVER=${lib.getExe' pkgs.llama-cpp "llama-server"}
      exec ${lib.getExe plamoTranslatePy} "$@"
    '';
  };

  agyTranslateWatch = pkgs.writeShellApplication {
    name = "agy-translate-watch";
    runtimeInputs = [
      pkgs.coreutils
      plamoTranslate
    ];
    text = ''
      export PLAMO_TRANSLATE_BIN=${lib.getExe plamoTranslate}
      exec ${lib.getExe agyTranslateWatchPy} "$@"
    '';
  };

  commonRuntime = [
    pkgs.antigravity
    pkgs.coreutils
    pkgs.findutils
    pkgs.ncurses
    pkgs.procps
    pkgs.tmux
    agyTranslateWatch
    plamoTranslate
  ];

  agyPaneToggle = pkgs.writeShellApplication {
    name = "agy-ja-pane-toggle";
    runtimeInputs = commonRuntime;
    text = ''
      export AGY_BIN=${lib.getExe' pkgs.antigravity "agy"}
      export AGY_TRANSLATE_WATCH_BIN=${lib.getExe agyTranslateWatch}
      export PLAMO_TRANSLATE_BIN=${lib.getExe plamoTranslate}
      exec ${pkgs.bash}/bin/bash ${../scripts/agy-ja.sh} _pane-toggle "$@"
    '';
  };

  mkAgyLauncher =
    { name, launcherName }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = commonRuntime;
      text = ''
        export AGY_BIN=${lib.getExe' pkgs.antigravity "agy"}
        export AGY_TRANSLATE_WATCH_BIN=${lib.getExe agyTranslateWatch}
        export PLAMO_TRANSLATE_BIN=${lib.getExe plamoTranslate}
        export AGY_PANE_TOGGLE_BIN=${lib.getExe agyPaneToggle}
        export AGY_LAUNCHER_NAME=${lib.escapeShellArg launcherName}
        exec ${pkgs.bash}/bin/bash ${../scripts/agy-ja.sh} "$@"
      '';
    };

  agyJa = mkAgyLauncher {
    name = "agy-ja";
    launcherName = "agy-ja";
  };

  agyWrappedCli = mkAgyLauncher {
    name = "agy-wrapped";
    launcherName = "agy";
  };

  # Wrap `agy` transparently so interactive TTY sessions open the 2-pane PLaMo
  # translator automatically (when enabled), while keeping `antigravity` / `agy-raw` un-wrapped.
  antigravityWrapped =
    pkgs.runCommand "antigravity-wrapped"
      {
        meta = {
          inherit (pkgs.antigravity.meta)
            description
            homepage
            license
            platforms
            ;
          mainProgram = "agy";
        };
      }
      ''
        mkdir -p $out/bin
        ln -s ${lib.getExe agyWrappedCli} $out/bin/agy
        ln -s ${pkgs.antigravity}/bin/antigravity $out/bin/antigravity
        ln -s ${pkgs.antigravity}/bin/antigravity $out/bin/agy-raw
      '';
in
{
  home.packages = [
    antigravityWrapped
    plamoTranslate
    agyTranslateWatch
    agyJa
  ];

  # Persistent headless daemon for Antigravity Remote Control (https://antigravity.google.com)
  systemd.user.services.antigravity-cli-daemon = {
    Unit = {
      Description = "antigravity remote-control daemon";
      After = [ "network.target" ];
      StartLimitIntervalSec = 0;
    };

    Service = {
      Type = "simple";
      ExecStart = "${pkgs.antigravity}/bin/antigravity remote-control serve";
      # user@.service overrides PATH before Sway updates activation env; supply system/profile bins for boot-time linger
      Environment = [
        "PATH=/run/wrappers/bin:%h/.nix-profile/bin:/nix/profile/bin:%h/.local/state/nix/profile/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
      ];
      Restart = "on-failure";
      RestartSec = "10s";
      RestartPreventExitStatus = 3;
      TimeoutStopSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
