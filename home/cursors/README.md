# Custom Mouse Cursors

手元または外部配布のマウスカーソルテーマ（XCursor / Hyprcursor / Windows `.cur`・`.ani`）を持ち込むための置き場です。管理方法は 3 通り:

1. リポジトリに同梱する（両端末同期、§1）
2. 外部 URL からパッケージ化する（§2）
3. リポジトリ外で管理する（local-only、§3）— 再配布禁止のパックなど

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

### Windows カーソル（`.cur` / `.ani`）を変換する

Windows 用 `.cur` / `.ani` は XCursor 形式ではないため、`win2xcur` で変換します。変換後は §1 で同梱するか、§3 でリポジトリ外に置きます（現行例: `HutaoPointer` → §3）。

```bash
nix shell nixpkgs#win2xcur -c win2xcur *.cur *.ani -o ./converted
```

- 出力ファイル名は元のファイル名のままなので、XCursor の標準名（`left_ptr` / `hand2` / `xterm` / `watch` / `left_ptr_watch` / `size_ver` / `size_hor` / `size_fdiag` / `size_bdiag` / `fleur` / `crossed_circle` / `question_arrow` など）にリネームする。
- ツールキットが要求する別名（`default`・`pointer`・`text`・`wait`・`progress`・`grab`・`grabbing`・CSS リサイズ名など）は標準名へのシンボリックリンクで補う。
- `.ani` はアニメーション付き XCursor になる（ビジー系 `watch` / `wait` に使うとよい）。
- 元の nominal size は `nix shell nixpkgs#win2xcur -c inspectcur <file>.cur` で確認し、`cursor.size` に合わせる（例: 32）。

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

## 3. リポジトリ外で管理する（local-only）

再配布禁止（二次配布禁止）のカーソルパックなどは、バイナリを Git に入れずユーザースペースで管理します。現行の `HutaoPointer`（胡桃ちゃんぽいんた 2023リメイク、原本: `~/Downloads/【2023リメイク】胡桃ちゃんぽいんた.7z`）がこの方式です。

1. 変換済みテーマ（§1 の「Windows カーソルを変換する」参照）を `~/.local/share/icons/<Name>/` に置く（`cursors/` + `index.theme`）。
2. `lib/theme.nix` の `cursor` で `package = null;` を指定する:
   ```nix
   cursor = {
     name = "HutaoPointer";
     size = 32;
     package = null; # local-only: ~/.local/share/icons/<name> を使う
     hyprcursor = false;
   };
   ```
3. `rebuild` で反映。

挙動と注意:

- `home.pointerCursor` は store パッケージが必須で、`~/.local/share/icons/<name>` を store へのシンボリックリンクで上書きしてしまう。そのため `package = null` のときは無効化し、`home/programs.nix` が同等の設定（`XCURSOR_THEME` / `XCURSOR_SIZE` / `XCURSOR_PATH`、GTK settings.ini + dconf、`default/index.theme` の `Inherits`）を直接生成する。
- ログイン画面（ReGreet）は greeter ユーザーで動き `/home/mitac` を読めないため、Adwaita にフォールバックする。
- テーマ実体は restic のホームバックアップ対象（`~/.local/share/icons` は除外指定なし）。再インストール後はバックアップから復元するか、原本から再変換する。
- 別端末（vaio など）でも使うには、その端末の同じパスにテーマを置く。

## 4. 再ビルドなしで手元カーソルを仮テストする

`~/.local/share/icons/<ThemeName>/` に展開して次を実行すると、現在の Hyprland セッションで即確認できます:

```bash
hyprctl setcursor <ThemeName> 24
```
