# WhatPulse Linux desktop client (official AppImage, wrapped with appimageTools).
#
# Keystroke & mouse counting on Wayland requires membership in the `input` group
# (configured in modules/nixos/common.nix). Network traffic stats require the
# companion `whatpulse-pcap-service` systemd unit.
{
  lib,
  fetchurl,
  appimageTools,
}:
let
  pname = "whatpulse";
  version = "7.0.1";

  src = fetchurl {
    url = "https://releases.whatpulse.org/archives/${version}/linux/whatpulse-linux-${version}_amd64.AppImage";
    hash = "sha256-cn55n97RMDk0kbCiV7/v61qBJcy0k/ecc1q4ZDWaAIY=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraPkgs =
    pkgs: with pkgs; [
      libpcap
      libxkbcommon
      wayland
    ];

  extraInstallCommands = ''
    for d in ${appimageContents}/*.desktop ${appimageContents}/usr/share/applications/*.desktop; do
      if [ -f "$d" ]; then
        install -Dm444 "$d" "$out/share/applications/whatpulse.desktop"
        sed -i 's|^Exec=.*|Exec=whatpulse %U|' "$out/share/applications/whatpulse.desktop"
        break
      fi
    done

    if [ -d "${appimageContents}/usr/share/icons" ]; then
      cp -r "${appimageContents}/usr/share/icons" "$out/share/"
    fi
    for icon in ${appimageContents}/*.png ${appimageContents}/*.svg; do
      if [ -f "$icon" ]; then
        ext="''${icon##*.}"
        install -Dm444 "$icon" "$out/share/pixmaps/whatpulse.$ext"
        break
      fi
    done
  '';

  meta = {
    description = "Keyboard, mouse, application, uptime, and network activity tracker";
    homepage = "https://whatpulse.org/";
    license = lib.licenses.unfree;
    mainProgram = "whatpulse";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
