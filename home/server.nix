# Minimal headless Home Manager profile for server hosts (e.g. ubuntu).
# Keeps flake-tools (`secrets`, `flake-update`), agenix user links, bash, git,
# and gh without pulling in any desktop stack.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  repoPath = config.mitac.repoPath;
  defaultHost = config.mitac.flakeHost;
in
{
  imports = [
    ./flake-tools.nix
    ./secrets.nix
  ];

  home.username = "mitac";
  home.homeDirectory = "/home/mitac";
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  # Preserve Ubuntu server PATH additions (Hermes wrappers, uv, ~/bin scripts).
  home.sessionPath = [
    "$HOME/bin"
    "$HOME/.local/bin"
  ];

  programs.git = {
    enable = true;
    settings.user = {
      name = "mitac";
      email = "mitac31709@gmail.com";
    };
  };

  # Wires `gh auth git-credential` into git config (matching existing ~/.gitconfig).
  programs.gh = {
    enable = true;
    settings.git_protocol = "https";
  };

  programs.bash = {
    enable = true;
    historySize = 20000;
    historyFileSize = 20000;
    shellAliases = {
      ll = "ls -la";
      bcat = "bat";
      batcat = "bat";
      generations = "nixos-rebuild list-generations";
      flake-update = lib.getExe config.mitac.scripts.flakeUpdate;
      flake-update-cursor = lib.getExe config.mitac.scripts.flakeUpdateCursor;
    };
    initExtra = ''
      # Share history across interactive shells (ported from Ubuntu ~/.bashrc).
      shopt -s histappend
      share_history() {
        history -a
        history -c
        history -r
      }
      PROMPT_COMMAND="share_history''${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

      rebuild() {
        local defaultTarget=${lib.escapeShellArg defaultHost}
        local target="''${1:-$defaultTarget}"
        local flakeUri=${lib.escapeShellArg repoPath}"#$target"
        sudo -v || return $?
        if command -v nom >/dev/null 2>&1; then
          sudo nixos-rebuild switch --flake "$flakeUri" |& nom
          return "''${PIPESTATUS[0]}"
        fi
        sudo nixos-rebuild switch --flake "$flakeUri"
      }

      nix-eval-low() {
        nice -n 19 ionice -c3 nix eval "$@"
      }
    '';
  };

  home.packages = with pkgs; [
    nix-output-monitor
  ];
}
