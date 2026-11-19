# agent-desktop: computer use CLI for AI agents via OS accessibility trees.
#
# Ships `agent-desktop` and `agent-desktop-linux-clipboard-owner` together in
# `$out/bin` (required by the Linux backend for X11 clipboard ownership).
#
# Do not autoPatchelf: binaries are built against glibc and run via NixOS
# /lib64/ld-linux-x86-64.so.2 (nix-ld), same approach as opencode/antigravity.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "agent-desktop";
  version = "1.3.1";

  src = fetchurl {
    url = "https://github.com/vercel-labs/agent-desktop/releases/download/v${finalAttrs.version}/agent-desktop-v${finalAttrs.version}-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-yne2t1A07rEuU33YwKTyo0JBGSU/OLfmvXm6DS/vEmQ=";
  };

  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 agent-desktop $out/bin/agent-desktop
    install -Dm755 agent-desktop-linux-clipboard-owner $out/bin/agent-desktop-linux-clipboard-owner
    runHook postInstall
  '';

  meta = {
    description = "Computer use CLI for AI agents via OS accessibility trees";
    homepage = "https://agent-browser.dev/desktop";
    changelog = "https://github.com/vercel-labs/agent-desktop/releases";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "agent-desktop";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
