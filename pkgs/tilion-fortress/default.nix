# Tilion Fortress: local stealth Chromium engine + `tilion` / `tilion-mcp` / `tilion-fortress` CLI.
#
# Packages the prebuilt Fortress v3 (Chromium 153) Linux x64 binary with
# autoPatchelfHook and wires the Python 3.13 CLI/MCP stack (`tilion` + `tilion-fortress`)
# directly to the Nix store binary so runtime never downloads unpatched FHS binaries.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  python313,
  bash,
  coreutils,
  curl,
  gnused,
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
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxshmfence,
  libXScrnSaver,
  libXtst,
  mesa,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,
  udev,
  vulkan-loader,
  wayland,
}:

let
  fortressVersion = "153.0.8010.36";
  tilionVersion = "0.1.16";
  pyPkgs = python313.pkgs;

  fortressBrowser = stdenv.mkDerivation {
    pname = "tilion-fortress-browser";
    version = fortressVersion;

    src = fetchurl {
      url = "https://github.com/tiliondev/fortress/releases/download/v${fortressVersion}/fortress-v153-linux-x64.tar.gz";
      hash = "sha256-J6JmHVMbu6sUh1mSukT9phYi0arz7g7l+l1p0NAoY7Y=";
      curlOptsList = [
        "--ipv4"
        "--speed-limit"
        "50000"
        "--speed-time"
        "30"
      ];
    };

    sourceRoot = ".";

    nativeBuildInputs = [
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
      libdrm
      libgbm
      libGL
      libnotify
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxkbcommon
      libxrandr
      libxshmfence
      libXScrnSaver
      libXtst
      mesa
      nspr
      nss
      pango
      pipewire
      stdenv.cc.cc.lib
      systemd
      udev
      vulkan-loader
      wayland
    ];

    runtimeDependencies = [
      libGL
      mesa
      udev
      vulkan-loader
    ];

    autoPatchelfIgnoreMissingDeps = [
      "libQt5Core.so.5"
      "libQt5Gui.so.5"
      "libQt5Widgets.so.5"
      "libQt6Core.so.6"
      "libQt6Gui.so.6"
      "libQt6Widgets.so.6"
    ];

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall

      chromePath="$(find . -maxdepth 3 -name chrome -type f | head -n 1)"
      if [ -z "$chromePath" ]; then
        echo "tilion-fortress: chrome binary not found in archive" >&2
        exit 1
      fi
      srcDir="$(dirname "$chromePath")"

      mkdir -p "$out/lib/tilion-fortress" "$out/bin"
      cp -a "$srcDir/." "$out/lib/tilion-fortress/"

      if [ -f "$out/lib/tilion-fortress/tilion-activate" ]; then
        chmod +x "$out/lib/tilion-fortress/tilion-activate"
        patchShebangs "$out/lib/tilion-fortress/tilion-activate"
        wrapProgram "$out/lib/tilion-fortress/tilion-activate" \
          --prefix PATH : "${
            lib.makeBinPath [
              bash
              coreutils
              python313
            ]
          }"
      fi

      if [ -f "$out/lib/tilion-fortress/tilion" ]; then
        chmod +x "$out/lib/tilion-fortress/tilion"
        patchShebangs "$out/lib/tilion-fortress/tilion"
        wrapProgram "$out/lib/tilion-fortress/tilion" \
          --prefix PATH : "${
            lib.makeBinPath [
              bash
              coreutils
              curl
              gnused
            ]
          }" \
          --prefix LD_LIBRARY_PATH : "$out/lib/tilion-fortress"
        ln -s "$out/lib/tilion-fortress/tilion" "$out/bin/fortress-browser"
      else
        makeWrapper "$out/lib/tilion-fortress/chrome" "$out/bin/fortress-browser" \
          --prefix LD_LIBRARY_PATH : "$out/lib/tilion-fortress"
      fi

      runHook postInstall
    '';
  };

  # tilion 0.1.16 requires `mcp>=1.28,<1.29` (FastMCP under `mcp.server.fastmcp`),
  # while nixpkgs ships mcp 2.x. Pin the pure-Python 1.28.0 wheel cleanly.
  mcpCompat = pyPkgs.buildPythonPackage {
    pname = "mcp";
    version = "1.28.0";
    format = "wheel";

    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/2e/e1/4c1dc1fbb688641a712d34650c3d58bbbdcb314ddb75bc5817bbf33515a4/mcp-1.28.0-py3-none-any.whl";
      hash = "sha256-nB5886kSVVfkGOzU/tjprd3OgbDf2uTWYB1wD1vrcaQ=";
    };

    dependencies = with pyPkgs; [
      anyio
      cryptography
      httpx
      httpx-sse
      jsonschema
      pydantic
      pydantic-settings
      pyjwt
      python-multipart
      sse-starlette
      starlette
      typing-extensions
      typing-inspection
      uvicorn
    ];

    dontCheckRuntimeDeps = true;
    doCheck = false;
  };

  tilionFortressSdk = pyPkgs.buildPythonPackage {
    pname = "tilion-fortress";
    version = "${fortressVersion}.post1";
    format = "wheel";

    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/3f/98/8d71a841562541c2b109f4a0464ef419d4c1d31485f60194bbcccc68153a/tilion_fortress-153.0.8010.36.post1-py3-none-any.whl";
      hash = "sha256-QpmXPBpxpNxjkljtOEGRJ42tVUDCBjPuANgvzgwm8KA=";
    };

    # Resolve the Nix-packaged Fortress launcher first on linux-x64 while keeping
    # `--user-data-dir` writable under `~/.cache/tillion-fortress/profile`.
    postInstall = ''
      ${python313}/bin/python3 - "$out/${python313.sitePackages}/tillion_fortress/__init__.py" "${fortressBrowser}/lib/tilion-fortress/tilion" <<'PY'
      import sys
      from pathlib import Path

      init_py = Path(sys.argv[1])
      nix_launcher = sys.argv[2]
      text = init_py.read_text(encoding="utf-8")
      anchor = "    asset, kind, launcher_name = _ASSETS[plat]\n"
      inject = (
          "    asset, kind, launcher_name = _ASSETS[plat]\n"
          "    env_launcher = os.environ.get(\"FORTRESS_LAUNCHER_PATH\")\n"
          "    if env_launcher and plat == \"linux-x64\" and Path(env_launcher).is_file():\n"
          "        return Path(env_launcher)\n"
          f"    if plat == \"linux-x64\" and Path({nix_launcher!r}).is_file():\n"
          f"        return Path({nix_launcher!r})\n"
      )
      assert anchor in text, "expected anchor in tillion_fortress/__init__.py"
      init_py.write_text(text.replace(anchor, inject, 1), encoding="utf-8")
      PY
    '';

    doCheck = false;
  };
in
pyPkgs.buildPythonApplication {
  pname = "tilion-fortress";
  version = tilionVersion;
  format = "wheel";

  # Upstream ships cp313 bytecode (.pyc) inside `tilion-0.1.16-cp313-none-any.whl`.
  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/ed/2d/f9c08308d10767c8dc3a492276ec5c5006556139abc28ee0c46d77025340/tilion-0.1.16-cp313-none-any.whl";
    hash = "sha256-AA5EI1eZ8UE3yWc7EdRW4/9hHAXviy7NXkGxjoZISjU=";
  };

  dependencies = with pyPkgs; [
    aiohttp
    beautifulsoup4
    boto3
    cryptography
    mcpCompat
    pyjwt
    pyotp
    pyyaml
    tilionFortressSdk
    uvloop
    xlib
  ];

  dontStrip = true;
  dontCheckRuntimeDeps = true;
  doCheck = false;

  makeWrapperArgs = [
    "--set-default"
    "TILLION_ENGINE_BINARY"
    "${fortressBrowser}/lib/tilion-fortress/chrome"
    "--set-default"
    "FORTRESS_LAUNCHER_PATH"
    "${fortressBrowser}/lib/tilion-fortress/tilion"
  ];

  postInstall = ''
    for script in tilion-fortress tilion-activate; do
      if [ -f "${tilionFortressSdk}/bin/$script" ]; then
        install -m755 "${tilionFortressSdk}/bin/$script" "$out/bin/$script"
      fi
    done
    ln -s "${fortressBrowser}/bin/fortress-browser" "$out/bin/fortress-browser"
  '';

  passthru = {
    browser = fortressBrowser;
  };

  meta = {
    description = "Tilion Fortress stealth Chromium engine, CLI, and local MCP server";
    homepage = "https://fortress.tilion.com/";
    changelog = "https://github.com/tiliondev/fortress/releases";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [
      binaryNativeCode
      binaryBytecode
    ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "tilion";
  };
}
