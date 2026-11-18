# Capsomnia reproduction for NixOS/Sway: Caps Lock physical keep-awake switch,
# closed-lid display dimming/sleep, auto-off timer, hotspot keepalive, GTK4 settings,
# Rofi menu, and cpsm CLI.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  gtk4,
  glib,
  gobject-introspection,
  pango,
  harfbuzz,
  graphene,
  gdk-pixbuf,
  sway,
  swaylock,
  brightnessctl,
  rofi,
  libnotify,
  iproute2,
  iputils,
  procps,
  systemd,
  coreutils,
}:

let
  py = python3.withPackages (ps: [
    ps.evdev
    ps.pygobject3
  ]);

  giTypelibPath = lib.makeSearchPath "lib/girepository-1.0" [
    gtk4
    glib.out
    pango.out
    harfbuzz.out
    graphene
    gdk-pixbuf
    gobject-introspection
  ];
in
stdenvNoCC.mkDerivation {
  pname = "capsomnia";
  version = "4.3.5-nixos.1";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ py ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    GI_TYPELIB_PATH="${giTypelibPath}" ${py.interpreter} -B -m unittest discover -s . -v
    runHook postCheck
  '';

  installPhase = ''
        runHook preInstall

        mkdir -p "$out/libexec/capsomnia" "$out/bin" "$out/share/applications"

        for f in \
          capsomnia_core.py \
          capsomnia_helperd.py \
          capsomniad.py \
          cpsm.py \
          capsomnia_menu.py \
          capsomnia_settings.py
        do
          install -Dm644 "$f" "$out/libexec/capsomnia/$f"
        done

        for f in \
          capsomnia_helperd.py \
          capsomniad.py \
          cpsm.py \
          capsomnia_menu.py \
          capsomnia_settings.py
        do
          chmod 755 "$out/libexec/capsomnia/$f"
          substituteInPlace "$out/libexec/capsomnia/$f" \
            --replace-fail "#!/usr/bin/env python3" "#!${py.interpreter}"
        done

        makeWrapper "$out/libexec/capsomnia/capsomnia_helperd.py" "$out/bin/capsomnia-helperd" \
          --set PYTHONPATH "$out/libexec/capsomnia" \
          --prefix PATH : "${
            lib.makeBinPath [
              systemd
              coreutils
            ]
          }"

        makeWrapper "$out/libexec/capsomnia/capsomniad.py" "$out/bin/capsomniad" \
          --set PYTHONPATH "$out/libexec/capsomnia" \
          --prefix GI_TYPELIB_PATH : "${giTypelibPath}" \
          --prefix PATH : "$out/bin:${
            lib.makeBinPath [
              sway
              swaylock
              brightnessctl
              iproute2
              iputils
              procps
              systemd
              coreutils
            ]
          }"

        makeWrapper "$out/libexec/capsomnia/cpsm.py" "$out/bin/cpsm" \
          --set PYTHONPATH "$out/libexec/capsomnia" \
          --prefix PATH : "$out/bin:${
            lib.makeBinPath [
              systemd
              coreutils
            ]
          }"

        makeWrapper "$out/libexec/capsomnia/capsomnia_menu.py" "$out/bin/capsomnia-menu" \
          --set PYTHONPATH "$out/libexec/capsomnia" \
          --prefix PATH : "$out/bin:${
            lib.makeBinPath [
              rofi
              libnotify
              systemd
              coreutils
            ]
          }"

        makeWrapper "$out/libexec/capsomnia/capsomnia_settings.py" "$out/bin/capsomnia-settings" \
          --set PYTHONPATH "$out/libexec/capsomnia" \
          --prefix GI_TYPELIB_PATH : "${giTypelibPath}" \
          --prefix PATH : "$out/bin:${
            lib.makeBinPath [
              systemd
              coreutils
            ]
          }"

        ln -s "$out/bin/capsomnia-settings" "$out/bin/capsomnia"

        cat > "$out/share/applications/capsomnia.desktop" << EOF
    [Desktop Entry]
    Type=Application
    Name=Capsomnia
    Comment=Caps Lock physical keep-awake switch for closed-lid work
    Exec=$out/bin/capsomnia-settings
    Icon=preferences-system-power
    Terminal=false
    Categories=Utility;Settings;
    EOF

        runHook postInstall
  '';

  meta = {
    description = "Caps Lock physical keep-awake switch for closed-lid Linux/Sway laptops (Capsomnia clone)";
    platforms = lib.platforms.linux;
    mainProgram = "cpsm";
  };
}
