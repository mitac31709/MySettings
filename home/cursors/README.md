# Custom Mouse Cursors

手元または外部配布のマウスカーソルテーマ（XCursor / Hyprcursor / Windows `.cur`・`.ani`）を持ち込むための置き場です。

## 1. 手元のカーソルフォルダをそのまま同梱する（両端末同期）

XCursor（`cursors/` を含む）または Hyprcursor（`hyprcursors/` + `manifest.hl` を含む）の展開済みフォルダをこのディレクトリに置きます。

```text
home/cursors/
  MyCursor/
    index.theme    # 省略時はビルド時に自動生成
    cursors/
    hyprcursors/   # Hyprcursor 対応テーマの場合のみ
    manifest.hl    # Hyprcursor 対応テーマの場合のみ
```

1. `git add home/cursors/MyCursor`
2. `lib/theme.nix` の `cursor` を書き換えて `rebuild`:
   ```nix
   cursor = {
     name = "MyCursor";
     size = 24;
     package = pkgs: mkLocalCursor pkgs "MyCursor";
     hyprcursor = false; # hyprcursors/ + manifest.hl がある場合は true
   };
   ```

※ `home/cursors/` に複数テーマを置いて `rebuild` すると、アクティブ以外のテーマも `XCURSOR_PATH` に登録されるため、`hyprctl setcursor <ThemeName> 24` で即座に比較できます。

## 2. 外部配布（GitHub / tar.gz / zip / Windows `.cur`・`.ani`）をパッケージ化する

Git リポジトリに大容量バイナリを入れず URL から取得・変換したい場合は、`pkgs/<pkg-name>/default.nix` を作って `flake.nix` の overlay に登録し、`lib/theme.nix` から `package = pkgs: pkgs.<pkg-name>;` を指定します。

Windows カーソル（`.cur` / `.ani`）を XCursor へ変換する最小例:

```nix
{ stdenvNoCC, fetchurl, unzip, win2xcur }:
stdenvNoCC.mkDerivation {
  pname = "my-win-cursor";
  version = "1.0";
  src = fetchurl {
    url = "https://example.com/cursor.zip";
    hash = "sha256-...";
  };
  nativeBuildInputs = [ unzip win2xcur ];
  installPhase = ''
    mkdir -p "$out/share/icons/MyWinCursor/cursors"
    win2xcur *.cur *.ani -o "$out/share/icons/MyWinCursor/cursors"
    printf '[Icon Theme]\nName=MyWinCursor\n' > "$out/share/icons/MyWinCursor/index.theme"
  '';
}
```

## 3. 再ビルドなしで手元カーソルを仮テストする

`~/.local/share/icons/<ThemeName>/` に展開して次を実行すると、現在の Hyprland セッションで即確認できます:

```bash
hyprctl setcursor <ThemeName> 24
```
