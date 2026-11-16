# Hermes Agent CLI (Nous Research) for T3 Code Local ACP and interactive use.
# Gateway / Hermes Desktop stay off; UI is T3, state lives in ~/.hermes.
{ inputs, ... }:

{
  imports = [ inputs.hermes-agent.homeManagerModules.default ];

  programs.hermes-agent.enable = true;

  # ACP extra so `hermes acp` / `hermes-acp` work with T3 Code.
  services.hermes-agent.extraDependencyGroups = [ "acp" ];
}
