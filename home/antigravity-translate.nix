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

  agyJa = pkgs.writeShellApplication {
    name = "agy-ja";
    runtimeInputs = [
      pkgs.antigravity
      pkgs.coreutils
      pkgs.findutils
      pkgs.ncurses
      pkgs.tmux
      agyTranslateWatch
      plamoTranslate
    ];
    text = ''
      export AGY_BIN=${lib.getExe' pkgs.antigravity "agy"}
      export AGY_TRANSLATE_WATCH_BIN=${lib.getExe agyTranslateWatch}
      export PLAMO_TRANSLATE_BIN=${lib.getExe plamoTranslate}
      exec ${pkgs.bash}/bin/bash ${../scripts/agy-ja.sh} "$@"
    '';
  };
in
{
  home.packages = [
    plamoTranslate
    agyTranslateWatch
    agyJa
  ];
}
