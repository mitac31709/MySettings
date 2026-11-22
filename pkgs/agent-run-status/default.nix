# Small user service that speaks t3code 0.1.8's orchestration v2 RPC and writes
# $XDG_RUNTIME_DIR/agent-run-status.json for the Colorshell agent-run card.
# The protocol is pinned: home/hyprland.nix refuses to evaluate when
# pkgs.t3code.version is not 0.1.8.
{
  lib,
  stdenvNoCC,
  nodejs,
  makeWrapper,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "agent-run-status";
  version = "0.1.8";

  src = ./src;

  nativeBuildInputs = [
    nodejs
    makeWrapper
  ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node --test ./*.test.mjs
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/agent-run-status"
    cp aggregate.mjs rpc.mjs discover.mjs fixtures.mjs bridge.mjs "$out/lib/agent-run-status/"
    makeWrapper ${lib.getExe nodejs} "$out/bin/agent-run-status" \
      --add-flags "$out/lib/agent-run-status/bridge.mjs"
    runHook postInstall
  '';

  meta = {
    description = "T3 Code run-status bridge for the Colorshell agent card";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = "agent-run-status";
    platforms = nodejs.meta.platforms;
  };
})
