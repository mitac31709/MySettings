{
  lib,
  stdenv,
  src,
  version,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libappindicator-gtk3,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libsecret,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libXScrnSaver,
  libXtst,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  udev,
  vulkan-loader,
}:

stdenv.mkDerivation {
  pname = "orca-ide";
  inherit version src;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libappindicator-gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
    libuuid
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libXScrnSaver
    libXtst
    mesa
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    udev
    vulkan-loader
  ];

  # ANGLE loads libEGL and @transcribe-cpp loads libvulkan via dlopen.
  runtimeDependencies = [
    libGL
    vulkan-loader
  ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;

  autoPatchelfIgnoreMissingDeps = [
    "libc.musl-x86_64.so.1"
    # Optional Qt shims for KDE detection only.
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin $out/share
    cp -a opt/Orca $out/lib/orca-ide
    cp -a usr/share/. $out/share/

    makeWrapper $out/lib/orca-ide/orca-ide $out/bin/orca-ide \
      --prefix LD_LIBRARY_PATH : "$out/lib/orca-ide" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true --wayland-text-input-version=3}}"

    substituteInPlace $out/share/applications/orca-ide.desktop \
      --replace-fail 'Exec=/opt/Orca/orca-ide %U' 'Exec=orca-ide %U'

    runHook postInstall
  '';

  meta = {
    description = "Next-gen IDE for parallel agentic development";
    homepage = "https://orca.dev";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "orca-ide";
  };
}
