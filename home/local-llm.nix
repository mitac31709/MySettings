# On-demand llama.cpp local LLM backend and CLI (`local-llm`, Qwen3.5-4B Q4_K_M).
{
  lib,
  pkgs,
  ...
}:

let
  localLlmPy = pkgs.writers.writePython3Bin "local-llm-py" {
    libraries = [ ];
    doCheck = false;
  } (builtins.readFile ../scripts/local-llm.py);

  localLlm = pkgs.writeShellApplication {
    name = "local-llm";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.llama-cpp
      pkgs.xdg-utils
    ];
    text = ''
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export LOCAL_LLM_LLAMA_SERVER=${lib.getExe' pkgs.llama-cpp "llama-server"}
      export LOCAL_LLM_LLAMA_CLI=${lib.getExe' pkgs.llama-cpp "llama-cli"}
      exec ${lib.getExe localLlmPy} "$@"
    '';
  };
in
{
  home.packages = [
    pkgs.llama-cpp
    localLlm
  ];

  xdg.dataFile."applications/local-llm.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Local LLM (Qwen3.5-4B)
    GenericName=llama.cpp WebUI
    Comment=Start Qwen3.5-4B via llama-server and open WebUI
    Exec=${lib.getExe localLlm} web
    Icon=utilities-terminal
    Terminal=false
    Categories=Development;Utility;
    StartupNotify=false
  '';
}
