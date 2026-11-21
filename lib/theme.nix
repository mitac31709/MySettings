# Unified visual design system for the Hyprland desktop ("Nocturne Slate").
# Shared across Hyprland, Waybar, Hyprlock, Hyprpaper, Mako, Rofi, ReGreet,
# Ghostty, Satty, and Fcitx5 (Meltype).
let
  palette = {
    # Surfaces
    bg = "#0d1117";
    bgRgb = "13, 17, 23";
    bgHex = "0d1117";

    surface = "#131922";
    surfaceRgb = "19, 25, 34";
    surfaceHex = "131922";

    surfaceAlt = "#1a2330";
    surfaceAltRgb = "26, 35, 48";
    surfaceAltHex = "1a2330";

    surfaceHover = "#222e3f";
    surfaceHoverHex = "222e3f";

    # Borders
    border = "#263344";
    borderHex = "263344";
    borderStrong = "#35475e";

    # Typography
    fg = "#e8eef5";
    fgRgb = "232, 238, 245";
    fgHex = "e8eef5";

    fgSecondary = "#a3b1c2";
    fgSecondaryRgb = "163, 177, 194";
    fgSecondaryHex = "a3b1c2";

    fgMuted = "#637286";
    fgMutedRgb = "99, 114, 134";
    fgMutedHex = "637286";

    # Accents (Glacial Teal -> Arctic Sky gradient)
    accent = "#56d4c8";
    accentRgb = "86, 212, 200";
    accentHex = "56d4c8";

    accentAlt = "#4ea8de";
    accentAltRgb = "78, 168, 222";
    accentAltHex = "4ea8de";

    accentSoft = "#16333a";
    accentSoftRgb = "22, 51, 58";
    accentSoftHex = "16333a";

    # Semantic status colors
    success = "#6ee7b7";
    successHex = "6ee7b7";
    warning = "#f2b866";
    warningHex = "f2b866";
    danger = "#f07178";
    dangerRgb = "240, 113, 120";
    dangerHex = "f07178";
    dangerSoft = "#3b1c24";
  };

  font = {
    mono = "JetBrainsMono Nerd Font";
    monoBold = "JetBrainsMono Nerd Font Bold";
  };

  radius = {
    window = 10;
    bar = 10;
    popup = 12;
    control = 8;
    pill = 7;
  };

  # Procedural 1920x1080 minimal slate-aurora wallpaper (pure Python stdlib,
  # deterministic, smooth atmospheric glow + subtle ordered dither to avoid banding).
  mkWallpaper =
    pkgs:
    pkgs.runCommand "nocturne-slate-wallpaper.png"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 - "$out" <<'PY'
        import math
        import struct
        import sys
        import zlib

        out_path = sys.argv[1]
        # Render at 960x540 (smooth radial gradients upscale cleanly with zero banding)
        # or 1920x1080 via fast bytearray row synthesis. 1280x720 gives crisp arcs + fast build.
        W, H = 1280, 720

        # Precompute 1D coordinate tables for speed.
        xs = [x / (W - 1) for x in range(W)]
        ys = [y / (H - 1) for y in range(H)]

        # 4x4 Bayer matrix normalized to [-0.5, 0.5] for subtle anti-banding dither.
        bayer4 = (
            (0, 8, 2, 10),
            (12, 4, 14, 6),
            (3, 11, 1, 9),
            (15, 7, 13, 5),
        )
        bayer = [[(v / 16.0) - 0.5 for v in row] for row in bayer4]

        # Base deep slate RGB (13, 17, 23)
        base_r, base_g, base_b = 11.0, 15.0, 22.0

        raw = bytearray()
        inv_w = 1.0 / (W - 1)
        inv_h = 1.0 / (H - 1)
        exp = math.exp
        sin = math.sin

        # Precompute x-dependent terms for three atmospheric light pools.
        dx1_sq = [(x - 0.18) ** 2 * 1.15 for x in xs]
        dx2_sq = [(x - 0.84) ** 2 * 1.05 for x in xs]
        dx3_sq = [(x - 0.52) ** 2 * 0.70 for x in xs]

        # Subtle architectural horizon ribbon curve.
        ribbon_y = [0.56 + 0.08 * sin(x * 3.8 + 0.6) - 0.05 * x for x in xs]
        ribbon2_y = [0.49 + 0.06 * sin(x * 3.2 - 0.8) + 0.04 * x for x in xs]

        for y in range(H):
            ny = ys[y]
            dy1 = (ny - 0.80) ** 2 * 1.85
            dy2 = (ny - 0.16) ** 2 * 1.65
            dy3 = (ny - 0.52) ** 2 * 2.20
            brow = bayer[y & 3]

            # Subtle vertical tonal gradient (slightly darker top-left, lifted bottom-center).
            vr = base_r + 3.0 * ny
            vg = base_g + 5.0 * ny
            vb = base_b + 8.0 * ny

            row = bytearray(1 + W * 3)
            row[0] = 0  # PNG filter type: None
            idx = 1
            for x in range(W):
                # Pool 1: glacial teal glow (bottom-left)
                g1 = exp(-(dx1_sq[x] + dy1) * 4.2)
                # Pool 2: arctic sky blue glow (top-right)
                g2 = exp(-(dx2_sq[x] + dy2) * 3.6)
                # Pool 3: deep slate-cyan mist (center)
                g3 = exp(-(dx3_sq[x] + dy3) * 3.2)

                # Two delicate translucent aurora contour bands
                dr1 = ny - ribbon_y[x]
                b1 = exp(-(dr1 * dr1) * 420.0) * (0.35 + 0.65 * (1.0 - abs(xs[x] - 0.48)))
                dr2 = ny - ribbon2_y[x]
                b2 = exp(-(dr2 * dr2) * 260.0) * (0.25 + 0.75 * xs[x])

                d = brow[x & 3] * 1.2

                r = vr + g1 * 18.0 + g2 * 16.0 + g3 * 10.0 + b1 * 24.0 + b2 * 14.0 + d
                g = vg + g1 * 64.0 + g2 * 44.0 + g3 * 28.0 + b1 * 62.0 + b2 * 40.0 + d
                b = vb + g1 * 68.0 + g2 * 76.0 + g3 * 44.0 + b1 * 66.0 + b2 * 64.0 + d

                row[idx] = 0 if r < 0 else (255 if r > 255 else int(r))
                row[idx + 1] = 0 if g < 0 else (255 if g > 255 else int(g))
                row[idx + 2] = 0 if b < 0 else (255 if b > 255 else int(b))
                idx += 3
            raw.extend(row)

        def chunk(tag: bytes, data: bytes) -> bytes:
            crc = zlib.crc32(tag)
            crc = zlib.crc32(data, crc) & 0xFFFFFFFF
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

        ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
        idat = zlib.compress(bytes(raw), level=6)
        png = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", idat)
            + chunk(b"IEND", b"")
        )
        with open(out_path, "wb") as f:
            f.write(png)
        PY
      '';

  # Package an unpacked XCursor / Hyprcursor theme folder under home/cursors/<name>/.
  # Copies with writable permissions and synthesizes index.theme if absent.
  mkLocalCursor =
    pkgs: name:
    pkgs.runCommand "cursor-theme-${name}" { } ''
      mkdir -p "$out/share/icons/${name}"
      cp -a --no-preserve=mode "${../home/cursors}/${name}/." "$out/share/icons/${name}/"
      if [ ! -f "$out/share/icons/${name}/index.theme" ]; then
        printf '[Icon Theme]\nName=%s\nComment=Local cursor theme\n' "${name}" \
          > "$out/share/icons/${name}/index.theme"
      fi
    '';

  # Active mouse cursor theme shared across Hyprland, GTK, X11/XWayland,
  # Hyprcursor, and ReGreet. See home/cursors/README.md to switch to a custom
  # local or externally packaged cursor theme.
  # package = null: local-only theme managed outside the repo under
  # ~/.local/share/icons/<name> (e.g. packs that forbid redistribution).
  # The greeter falls back to Adwaita (it cannot read the user's home).
  # HutaoPointer: 胡桃ちゃんぽいんた 2023リメイク (Windows .cur/.ani → win2xcur).
  cursor = {
    name = "HutaoPointer";
    size = 32;
    package = null;
    # Set true when the package provides a Hyprcursor theme (`hyprcursors/` + `manifest.hl`).
    hyprcursor = false;
  };
in
{
  inherit
    palette
    font
    radius
    mkWallpaper
    mkLocalCursor
    cursor
    ;
}
