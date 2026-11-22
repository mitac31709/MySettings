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

`bath-*.ogg` は [お風呂のメロディー集【新新版】](https://youtu.be/alRIEBuUcKk)（AotonTV）から各メーカーのチャイム部分を切り出し、音量を揃えたものです。動画の表示順に 1 回分ずつ抽出しています。

- `bath-noritz-old/new.ogg` — ノーリツ「人形の夢と目覚め」（旧／新）
- `bath-rinnai-canon-old/new.ogg` — リンナイ「カノン」（古／新）
- `bath-paloma-old/new.ogg` — パロマ（古／新）
- `bath-purpose.ogg` — パーパス
- `bath-national-old.ogg` — ナショナル（旧）
- `bath-panasonic-old/new.ogg` — パナソニック（古／新）
- `bath-mitsubishi-old.ogg` — 三菱（旧）
- `bath-corona.ogg` / `bath-corona-voice.ogg` — コロナ（ふろauto／音声案内）
- `bath-hitachi.ogg` — 日立（音声案内）
- `bath-morita.ogg` — モリタ（旧型）
- `bath-toto.ogg` — トートー
- `bath-takara-a/b/c.ogg` — タカラスタンダード メロディー A／B／C
- `bath-daikin.ogg` — ダイキン
- `bath-chofu.ogg` — 長府
