# Startup sounds

ランダム起動音（`home/startup-sound.nix` / `startup-sound` コマンド）に追加する音声ファイルの置き場です。

## 2つの追加方法（どちらも対象になります）

1. **ローカルフォルダ（再ビルド不要・即反映）**
   `~/.local/share/startup-sounds/` に音声ファイルを置いてください。
   （`~/.local/share/startup-sounds/nix` は Nix プリセットへの読み取り専用リンクです）
2. **このディレクトリ（宣言管理・両端末自動同期）**
   この `home/startup-sounds/` に音声ファイルを置いて `git add` し、`rebuild` してください。

対応拡張子: `.wav`, `.mp3`, `.ogg`, `.oga`, `.opus`, `.flac`, `.m4a`, `.aac`, `.wma`, `.aiff`, `.aif`, `.webm`, `.mka`
