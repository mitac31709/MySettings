# Wallpapers

Colorshell（`Super+W` / `colorshell runner -t "#"`）と `hyprpaper` で切り替える壁紙の置き場です。

## 2つの追加方法（どちらも `Super+W` に並びます）

1. **ローカルフォルダ（再ビルド不要・即反映）**
   `~/wallpapers/` に画像ファイルを直接置いてください。
2. **このディレクトリ（宣言管理・両端末自動同期）**
   この `home/wallpapers/` に画像ファイルを置いて `git add` し、`rebuild` してください。
   `~/wallpapers/<ファイル名>` に自動リンクされます（既存の `nocturne-slate.png` も同梱）。

対応拡張子: `.png`, `.jpg`, `.jpeg`, `.webp`, `.avif`, `.bmp`, `.gif`
（選択した壁紙は `~/.config/hypr/hyprpaper.conf` に永続化され、Colorshell の `pywal16` 配色も自動で追従します）
