# disktui: TUI disk & partition manager wrapped with its runtime CLI dependencies.
#
# Upstream spawns `pkexec <exe_dir>/disktui-helper` via `std::env::current_exe()`
# (which resolves /proc/self/exe symlinks). Copy both binaries as real files into
# `$out/bin` and wrap them with `--suffix PATH` (keeping `/run/wrappers/bin/pkexec`
# first) so neither `pkexec` nor `sudo` strips `parted`, `cryptsetup`, `mkfs.*`,
# or `smartctl`.
{
  lib,
  stdenvNoCC,
  makeBinaryWrapper,
  disktui,
  parted,
  util-linux,
  coreutils,
  which,
  e2fsprogs,
  dosfstools,
  ntfs3g,
  exfatprogs,
  btrfs-progs,
  xfsprogs,
  cryptsetup,
  smartmontools,
}:

let
  runtimePath = lib.makeBinPath [
    parted
    util-linux
    coreutils
    which
    e2fsprogs
    dosfstools
    ntfs3g
    exfatprogs
    btrfs-progs
    xfsprogs
    cryptsetup
    smartmontools
  ];
in
stdenvNoCC.mkDerivation {
  pname = "disktui";
  inherit (disktui) version;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ${disktui}/bin/disktui $out/bin/disktui
    install -Dm755 ${disktui}/bin/disktui-helper $out/bin/disktui-helper
    wrapProgram $out/bin/disktui --suffix PATH : ${lib.escapeShellArg runtimePath}
    wrapProgram $out/bin/disktui-helper --suffix PATH : ${lib.escapeShellArg runtimePath}
    runHook postInstall
  '';

  meta = disktui.meta // {
    description = "${
      disktui.meta.description or "TUI for disk management on Linux"
    } (wrapped with parted/cryptsetup/mkfs/smartctl)";
  };
}
