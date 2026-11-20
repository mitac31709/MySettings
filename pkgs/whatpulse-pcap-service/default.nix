# WhatPulse External PCap Service (companion daemon for Linux AppImage network stats).
# Upstream binary links against Debian's libpcap.so.0.8; rewrite NEEDED to nixpkgs'
# libpcap.so.1 during autoPatchelf.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  patchelf,
  libpcap,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "whatpulse-pcap-service";
  version = "1.5.2";

  src = fetchurl {
    url = "https://github.com/whatpulse/linux-external-pcap-service/releases/download/v${finalAttrs.version}/whatpulse-pcap-service-${finalAttrs.version}-linux-amd64";
    hash = "sha256-Wugbe/eyRyl+Jhh+SWzZT7yCeRpiEwZnp7HnfauxKzs=";
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs = [
    autoPatchelfHook
    patchelf
  ];

  buildInputs = [
    libpcap
    stdenv.cc.cc.lib
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/whatpulse-pcap-service"
    patchelf --replace-needed libpcap.so.0.8 libpcap.so.1 "$out/bin/whatpulse-pcap-service"
    runHook postInstall
  '';

  meta = {
    description = "External PCap companion daemon for WhatPulse Linux network statistics";
    homepage = "https://github.com/whatpulse/linux-external-pcap-service";
    license = lib.licenses.mit;
    mainProgram = "whatpulse-pcap-service";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
