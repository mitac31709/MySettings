{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  woff2,
}:

stdenvNoCC.mkDerivation {
  pname = "cursor-gothic";
  version = "0-unstable-2025-09-24";

  src = fetchFromGitHub {
    owner = "imjac0b";
    repo = "CursorGothic";
    rev = "434ce5d450bffa46a5d5ba292df9b4042fc87380";
    hash = "sha256-HDNzxgEnJKq+D8Q9gZcseltEXObo62MIquGaoyVlNpo=";
  };

  nativeBuildInputs = [ woff2 ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    for f in fonts/*.woff2; do
      woff2_decompress "$f"
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/fonts/opentype/cursor-gothic"
    for f in fonts/*.ttf; do
      # WOFF2 wraps SFNT CFF (OTTO header); install as .otf for fontconfig/apps.
      install -Dm444 "$f" "$out/share/fonts/opentype/cursor-gothic/$(basename "$f" .ttf).otf"
    done
    runHook postInstall
  '';

  meta = {
    description = "Cursor Gothic sans-serif typeface (OpenType extracted from WOFF2)";
    homepage = "https://github.com/imjac0b/CursorGothic";
    license = lib.licenses.unfree;
    platforms = lib.platforms.all;
    hydraPlatforms = [ ];
  };
}
