# Hermes Agent CLI (Nous Research) for T3 Code Local ACP and interactive use.
# Gateway / Hermes Desktop stay off; UI is T3, state lives in ~/.local/share/hermes.
{ config, inputs, ... }:

{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  programs.hermes-agent.enable = true;

  services.hermes-agent.hermesHome = "${config.xdg.dataHome}/hermes";
  # Export HERMES_HOME to systemd --user / GUI apps (e.g. T3 Code launching `hermes acp`).
  systemd.user.sessionVariables.HERMES_HOME = config.services.hermes-agent.hermesHome;

  # ACP extra so `hermes acp` / `hermes-acp` work with T3 Code.
  services.hermes-agent.extraDependencyGroups = [ "acp" ];
}
