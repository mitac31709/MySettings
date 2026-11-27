# Scripts that used to be started as ~/MySettings/scripts/... are installed
# into the Nix store. Commands that must edit or build the checkout receive
# mitac.repoPath (default: lib/machine.nix).
{
  config,
  inputs,
  lib,
  pkgs,
  flakeTarget ? null,
  ...
}:
let
  machine = import ../lib/machine.nix;
  repoPath = config.mitac.repoPath;
  agenixPkg = inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default;

  pyBin =
    name: file:
    pkgs.writers.writePython3Bin name {
      libraries = [ ];
      # These scripts already run on the machine. flake8 (line length and
      # friends) is not a reason for nixos-rebuild to fail.
      doCheck = false;
    } (builtins.readFile file);

  flakeUpdateCheckPy = pyBin "flake-update-check-flake" ../scripts/flake-update-check-flake.py;

  wrapWithEnv =
    extraEnv: name: runtimeInputs: script:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = ''
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export FLAKE_CHECK_PY=${lib.escapeShellArg (lib.getExe flakeUpdateCheckPy)}
        ${extraEnv}
        exec ${pkgs.bash}/bin/bash ${script} ${lib.escapeShellArg repoPath} "$@"
      '';
    };

  wrap = wrapWithEnv "";

  netTools = [
    pkgs.cacert
    pkgs.coreutils
    pkgs.curl
    pkgs.gawk
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nix
    pkgs.python3
  ];

  flakeUpdateCursor = wrap "flake-update-cursor" [
    pkgs.coreutils
    pkgs.nix
  ] ../scripts/flake-update-cursor.sh;
  flakeUpdateCheck = wrap "flake-update-check" (
    netTools
    ++ [
      pkgs.libnotify
      pkgs.procps
    ]
  ) ../scripts/flake-update-check.sh;
  flakeUpdate =
    wrapWithEnv
      ''
        export MITAC_FLAKE_HOST=${lib.escapeShellArg config.mitac.flakeHost}
        export MITAC_HIRAGINO_DIR=${lib.escapeShellArg machine.hiraginoDir}
        export MITAC_FLAKE_UPDATE_CHECK=${lib.escapeShellArg (lib.getExe flakeUpdateCheck)}
      ''
      "flake-update"
      (
        netTools
        ++ [
          pkgs.nix-output-monitor
          pkgs.procps
        ]
      )
      ../scripts/flake-update.sh;
  secretsTool = wrap "secrets" [
    agenixPkg
    pkgs.age
    pkgs.coreutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nix
    pkgs.python3
    pkgs.rbw
  ] ../scripts/secrets-tool.sh;
  restoreOnNixos = pkgs.writeShellApplication {
    name = "restore-on-nixos";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.pinentry-curses
      pkgs.pinentry-qt
      pkgs.python3
      pkgs.rbw
      pkgs.rclone
      pkgs.restic
      pkgs.util-linux
    ];
    text = ''
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
      exec ${pkgs.bash}/bin/bash ${../scripts/restore-on-nixos.sh} "$@"
    '';
  };
in
{
  options.mitac.repoPath = lib.mkOption {
    type = lib.types.str;
    default = machine.repoPath;
    description = ''
      Working copy of this flake. rebuild and flake-update run Nix against
      this directory. Change the default in lib/machine.nix.
    '';
  };

  options.mitac.flakeHost = lib.mkOption {
    type = lib.types.str;
    default = if flakeTarget != null then flakeTarget else machine.flakeHost;
    description = "nixosConfigurations name appended by rebuild.";
  };

  options.mitac.scripts = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    default = { };
    description = "Checkout scripts packaged into the Nix store.";
  };

  config = {
    mitac.scripts = {
      inherit
        flakeUpdate
        flakeUpdateCursor
        flakeUpdateCheck
        secretsTool
        restoreOnNixos
        ;
    };

    home.packages = [
      flakeUpdate
      flakeUpdateCursor
      flakeUpdateCheck
      secretsTool
      restoreOnNixos
    ];
  };
}
