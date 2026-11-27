# Windows Snipping Tool-style interactive screenshot overlay for Hyprland (GTK4 + layer-shell).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  gtk4,
  gtk4-layer-shell,
  glib,
  gobject-introspection,
  pango,
  harfbuzz,
  graphene,
  gdk-pixbuf,
  grim,
  hyprland,
  coreutils,
}:

let
  py = python3.withPackages (ps: [
    ps.pygobject3
    ps.pycairo
  ]);

  giTypelibPath = lib.makeSearchPath "lib/girepository-1.0" [
    gtk4
    gtk4-layer-shell
    glib.out
    pango.out
    harfbuzz.out
    graphene
    gdk-pixbuf
    gobject-introspection
  ];
in
stdenvNoCC.mkDerivation {
  pname = "snip-overlay";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ py ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    ${py.interpreter} -B -m unittest discover -s . -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/snip-overlay" "$out/bin"

    install -Dm644 snip_core.py "$out/libexec/snip-overlay/snip_core.py"
    install -Dm755 snip_overlay.py "$out/libexec/snip-overlay/snip_overlay.py"
    substituteInPlace "$out/libexec/snip-overlay/snip_overlay.py" \
      --replace-fail "#!/usr/bin/env python3" "#!${py.interpreter}"

    makeWrapper "$out/libexec/snip-overlay/snip_overlay.py" "$out/bin/snip-overlay" \
      --set PYTHONPATH "$out/libexec/snip-overlay" \
      --prefix LD_PRELOAD : "${gtk4-layer-shell}/lib/libgtk4-layer-shell.so" \
      --prefix GI_TYPELIB_PATH : "${giTypelibPath}" \
      --prefix PATH : "${
        lib.makeBinPath [
          grim
          hyprland
          coreutils
        ]
      }"

    runHook postInstall
  '';

  meta = {
    description = "Windows Snipping Tool-style interactive screenshot overlay for Hyprland";
    platforms = lib.platforms.linux;
    mainProgram = "snip-overlay";
  };
}
