# Screenpipe desktop app (official Linux x86_64 AppImage, wrapped with appimageTools).
# Captures screen + audio locally with OCR/transcription and searchable timeline.
{
  lib,
  fetchurl,
  appimageTools,
}:
let
  pname = "screenpipe";
  version = "2.7.145";

  src = fetchurl {
    url = "https://releases.screenpipe.com/releases/${version}/x86_64-unknown-linux-gnu/screenpipe_${version}_amd64.AppImage";
    hash = "sha256-l1MspoWSn+wr8CqQ88vFrHJvFt+FLcHE7PB5AxApufA=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraPkgs =
    pkgs: with pkgs; [
      webkitgtk_4_1
      libayatana-appindicator
      pipewire
      ffmpeg
      tesseract
      xdg-desktop-portal
    ];

  extraInstallCommands = ''
    for d in ${appimageContents}/*.desktop ${appimageContents}/usr/share/applications/*.desktop; do
      if [ -f "$d" ]; then
        install -Dm444 "$d" "$out/share/applications/screenpipe.desktop"
        sed -i 's|^Exec=.*|Exec=screenpipe %U|' "$out/share/applications/screenpipe.desktop"
        break
      fi
    done

    if [ -d "${appimageContents}/usr/share/icons" ]; then
      cp -r "${appimageContents}/usr/share/icons" "$out/share/"
    fi
    for icon in ${appimageContents}/*.png ${appimageContents}/*.svg; do
      if [ -f "$icon" ]; then
        ext="''${icon##*.}"
        install -Dm444 "$icon" "$out/share/pixmaps/screenpipe.$ext"
        break
      fi
    done
  '';

  meta = {
    description = "Local-first 24/7 screen and audio capture with OCR and searchable timeline";
    homepage = "https://screenpipe.com/";
    license = lib.licenses.unfree;
    mainProgram = "screenpipe";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
