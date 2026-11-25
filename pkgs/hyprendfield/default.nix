{
  lib,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  wayland-scanner,
  wlr-protocols,
  qt6,
  kdePackages,
  libpulseaudio,
  libvterm-neovim,
  wayland,
  libsecret,
  linux-pam,
  libzip,
  glib,
  ffmpeg,
  ffmpegthumbnailer,
  wl-clipboard,
  makeWrapper,
  src,
}:

stdenv.mkDerivation {
  pname = "hyprendfield";
  version = "0-unstable-${src.shortRev or "dirty"}";

  inherit src;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    wayland-scanner
    qt6.wrapQtAppsHook
    makeWrapper
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtwayland
    qt6.qtshadertools
    qt6.qtmultimedia
    qt6.qtwebsockets
    qt6.qtwebengine
    qt6.qtimageformats
    kdePackages.layer-shell-qt
    libpulseaudio
    libvterm-neovim
    wayland
    libsecret
    linux-pam
    libzip
    glib
  ];

  cmakeFlags = [
    "-DBUILD_TESTING=OFF"
    "-DWLR_DATA_CONTROL_PROTOCOL=${wlr-protocols}/share/wlr-protocols/unstable/wlr-data-control-unstable-v1.xml"
  ];

  # Limit parallel jobs slightly to avoid OOM on Qt/QML shader + C++20 builds.
  ninjaFlags = [ "-j4" ];

  qtWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      ffmpeg
      ffmpegthumbnailer
      wl-clipboard
    ])
  ];

  meta = {
    description = "Arknights: Endfield inspired animated HUD overlay for Hyprland (Linux port of EndfieldHUD)";
    homepage = "https://github.com/OctoberPrayRain/HyprEndfield";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "HyprEndfield";
  };
}
