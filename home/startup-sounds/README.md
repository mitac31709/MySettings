# Startup sounds

ランダム起動音（`home/startup-sound.nix` / `startup-sound` コマンド）に追加する音声ファイルの置き場です。

## 2つの追加方法（どちらも対象になります）

1. **ローカルフォルダ（再ビルド不要・即反映）**
   `~/.local/share/startup-sounds/` に音声ファイルを置いてください。
   （`~/.local/share/startup-sounds/nix` は Nix プリセットへの読み取り専用リンクです）
2. **このディレクトリ（宣言管理・両端末自動同期）**
   この `home/startup-sounds/` に音声ファイルを置いて `git add` し、`rebuild` してください。

対応拡張子: `.wav`, `.mp3`, `.ogg`, `.oga`, `.opus`, `.flac`, `.m4a`, `.aac`, `.wma`, `.aiff`, `.aif`, `.webm`, `.mka`

## お風呂が沸きましたチャイム

`bath-*.ogg` は給湯器リモコンの「お湯はり完了メロディー」をミュージックボックス調に合成したものです（いずれもパブリックドメインのクラシック旋律）。

- `bath-noritz.ogg` — ノーリツ「人形の夢と目覚め」第2部（テオドール・エステン）
- `bath-rinnai-canon.ogg` — リンナイ「カノン」（パッヘルベル）
- `bath-rinnai-elise.ogg` — リンナイ「エリーゼのために」（ベートーヴェン）
- `bath-paloma-spring.ogg` — パロマ「春」（ヴィヴァルディ『四季』より）
