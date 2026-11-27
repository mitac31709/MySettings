# MySettings — NixOS flake（mitac）

ホスト／ユーザー `mitac` 向けの Flakes + Home Manager 構成。ログインは **greetd + ReGreet（最小 Hyprland 上＋`lan-mouse` 受信）**、デスクトップは **Hyprland（UWSM）のみ**。**VAIO（Intel 第8世代以降）** と **Chromebook（ASUS CX5500FE / delbin）** の両対応です。

## ブランチ

| ブランチ | 用途 |
|----------|------|
| `main` | **作業・適用の既定**。VAIO（`.#vaio`）および delbin Chromebook（`.#chromebook`、レガシー別名 `.#mitac`）向け設定を含む |
| `chromebook` | レガシー。新規作業には使わない |

## セッション（greetd + ReGreet）

起動後は最小構成 Hyprland 上で **ReGreet**（`modules/nixos/greetd.nix`）と受信専用の **Lan Mouse** が起動します（他端末からログイン入力可能、提供セッションは **Hyprland (UWSM)** のみ）。

起動時から lan-mouse でログイン入力するには Wayland compositor（ここでは greeter 用 Hyprland）が必須のため、TTY 直の **tuigreet** とは同じ段階では両立できません。純 tuigreet にする場合は greeter 中の lan-mouse を諦める必要があります。

| セッション | 内容 |
|------------|------|
| **Hyprland (UWSM)** | キーボード中心のタイル WM（Lua 設定＋**Colorshell** GTK4/Astal デスクトップシェル）。`pywal16` による壁紙連動の動的配色（枠色同期あり）、hyprpaper / hyprsunset / hyprlock / hypridle。ランチャーは **Colorshell Runner**（Super+D / Super+Space / Alt+Space）。キーボード配列は **jp** |

### 操作感

**Ctrl+Super+Space** は Fcitx5 の IME 有効/無効（グループは Meltype のみ）。

| 操作 | キー | 動作 |
|------|------|------|
| 検索／ランチャー | **Super+D** / **Super+Space** / **Alt+Space** | **Colorshell Runner**（アプリ検索 / `>` クリップボード / `#` 壁紙 / 計算 / コマンド） |
| アプリ一覧 | **Win+Shift** / **Super+Shift+D** | **Colorshell Apps Drawer** |
| 壁紙切替・動的配色 | **Super+W** | **Colorshell Runner** 壁紙ピッカー（`#`、`~/wallpapers`、pywal16 動的配色） |
| コントロールセンター | **Super+I** | **Colorshell Control Center**（Wi-Fi / Bluetooth / 音量 / ナイトライト） |
| 通知・カレンダー・メディア | **Super+M** | **Colorshell Center Window** |
| 電源・ログアウトメニュー | **Super+X** | **Colorshell Logout Menu** |
| コマンド実行（一時） | **Super+P** | **rofi**（`-show run`：Enter で即実行／Shift+Enter で端末実行） |
| 端末 | **Ctrl+Alt+T** / **Super+Return** | **Ghostty** |
| 新規仮想デスクトップ | **Super+N** | 未使用最小番号の空きワークスペースへ移動 |
| ファイルマネージャ | **Super+E** | **Yazi**（Ghostty 内） |
| ロック | **Super+L** | **hyprlock**（Colorshell 標準テーマ・pywal16 連動） |
| クリップボード履歴 | **Super+V** | **cliphist** + rofi（Colorshell Runner の `>` からも検索可） |
| タブグループ | **Super+G** / **Super+Tab** | ウィンドウのグループ化／タブ切替 |
| スクラッチパッド | **Super+S** / **Super+Alt+S** | special ワークスペース（`magic`）表示切替／送り込み |
| スクショ | **Super+Shift+S** / **Shift+Print** / **Print** / **Super+Print** | **hyprshot** + **satty**（画面停止して範囲選択／全画面／ウィンドウ → 注釈・切り抜き・クリップボード・`~/Pictures/Screenshots/` 保存。`screenshot` CLI） |
| チートシート | **Super+/** | **rofi** 検索・実行メニュー（サービス管理・JQuake・起動音・Capsomnia・NTP 同期等） |
| マウス／ジェスチャ | **Super+左/右ドラッグ** / **3本指左右スワイプ** | ウィンドウ移動・リサイズ / ワークスペース切替 |
| タッチパッド | — | 自然スクロール off・タップクリック on・入力中もポインタ有効 |

電源ボタン（`power-chords`）: 短押し=suspend / 長押し≈2.5s=poweroff / **電源+F1（Chromebook は 電源+Back）=強制ログアウト** / **電源+F2（Chromebook は 電源+Refresh）=再起動**。

Colorshell / Polkit（`cmd-polkit` + `rofi-polkit`）/ Fcitx5 / cliphist / hyprpaper / hyprsunset / hypridle（systemd user）を起動時に起動。音量は PulseAudio（Chromebook）または PipeWire / `pipewire-pulse`（VAIO）経由で `pactl` 操作、輝度は `brightnessctl` 経由。バー・通知・OSD・ランチャー・ロック画面は **Colorshell**（`pywal16` 動的配色＋初期壁紙は `lib/theme.nix` の Nocturne Slate を `~/wallpapers/nocturne-slate.png` へ配置）で統一管理。

## 世代とコミットの対応

NixOS の世代番号はマシン固有です。コミットとの対応はビルド時の **`system.nixos.tags` / `system.configurationRevision`** で追います（`gen/NN-*` の Git タグ運用は廃止済み。既存タグは履歴として残っていてよい）。

| 場所 | 何がわかるか |
|------|----------------|
| ブートメニュー / `nixos-rebuild list-generations` | `system.nixos.label`（`tags` + NixOS バージョン）。例: `rofi-cheatsheet-26.11....` |
| `nixos-version --json` の `configurationRevision` | その世代をビルドした git コミット（フル SHA） |

任意でブートメニュー用スラッグを変えるときは `modules/nixos/release.nix` の `system.nixos.tags` を更新してから rebuild してください。

ブートメニュー（`Limine`）は `maxGenerations = 10` で世代を 10 件に絞っています（`modules/nixos/common.nix`）。Phoenix UEFI（VAIO）で `systemd-boot` の矢印キー操作が数秒固まる問題を避けるため、UEFI テキストコンソールに依存しない Limine を採用しています。反映には rebuild と再起動が必要です。

## 前提条件

- Flakes が有効な NixOS マシン（この flake でも有効化します）
- 初回 rebuild の**前に**、対象ホストの `hosts/<target>/hardware-configuration.nix` を実機で生成したファイルに差し替えること（`hosts/vaio/hardware-configuration.nix` は汎用テンプレート、`hosts/chromebook/hardware-configuration.nix` は delbin 実機設定）
- 非フリーパッケージ（`code-cursor`、`cursor-cli`、`jquake`、`parsec-bin`、`screenpipe`、`steam`、`virtualboxExtpack`、`vivaldi`、`whatpulse`）は `flake.nix` で許可済み。`affinity-v3` は未導入（戻し方は下記）
- Chromebook: MrChromebox（または同等）の UEFI／WP 無効を想定。ファームウェアの書き込みはこのリポジトリの範囲外

## USB からの新規インストールと初回設定

新しい PC や空の SSD へ NixOS Live USB から導入する手順です。この flake は `Limine`（UEFI 専用、`modules/nixos/common.nix`）と `zramSwap`（RAM 100% / `zstd`、`modules/nixos/laptop/power.nix`）を使うため、**UEFI ブート有効（セキュアブート無効）**・GPT（ESP + root、swap パーティション不要）を前提とします。

> **初回設定は Graphical ISO の日本語 LXQt 環境で行うのがおすすめ**: `ja_JP.UTF-8` と `Asia/Tokyo`・日本語キーボードを選べば日本語表示（フォント）・Firefox・GUI 端末（QTerminal）・クリップボードが初期状態から使えるため、GitHub 認証・Bitwarden（`rbw` + GUI `pinentry-qt`）・Google Drive OAuth の操作や長い文字列の扱いが格段に楽になります（日本語入力 IME の Meltype はこの flake 適用後に有効になります）。Minimal ISO 等の GUI 無しコンソール（TTY）を直接使う場合のみ、コンソールフォントに日本語グリフが無いため ISO 既定の英語（`en_US.UTF-8`）のままで進めてください。なお、この flake は Calamares が生成する `/etc/nixos/configuration.nix`（一時的な **LXQt / LightDM 設定**）を import しないため、設定取得・復元後に `nixos-rebuild switch --flake` と再起動を行えばクリーンに **greetd（ReGreet）+ Hyprland 専用環境**へ切り替わります。

### 0. USB メディアの作成と起動

1. [NixOS ダウンロードページ](https://nixos.org/download/) から **Graphical ISO**（GUI インストーラ＆Live デスクトップ付き・推奨）または **Minimal ISO**（CLI のみ）を取得し、USB メモリへ書き込む。
2. 対象機の UEFI 設定で Secure Boot を無効にし、USB から **UEFI モード**で起動する（Chromebook は事前に MrChromebox 等の UEFI ファームウェアを導入しておく）。

### 1. NixOS の導入（2 パターン）

#### パターン A: Graphical ISO（日本語・LXQt）で導入してから復元・適用（推奨）

既存バックアップを `./scripts/restore-on-nixos.sh` で復元する場合（`mitac` ユーザーで実機 NixOS 上から実行する設計）や、ブラウザー／GUI 端末／`pinentry-qt` を使いながら初期設定を進めたい場合はこの手順が最も楽です。

1. Live 環境で Wi-Fi 等へ接続し、**Install NixOS**（Calamares）を起動する。
2. インストーラで以下を設定してインストールする：
   - 言語／ロケール（Welcome / Location）: **日本語**（`ja_JP.UTF-8`）、タイムゾーン **Asia/Tokyo**
   - キーボード（Keyboard）: **Japanese** を選択
   - ユーザー名: **`mitac`**（`lib/machine.nix` の `/home/mitac/MySettings`・各種設定と一致させる）＋ 任意のパスワード
   - デスクトップ環境: **LXQt** を選択（軽量でありながら日本語表示・GUI 端末 QTerminal・Firefox・Qt ベースの `pinentry-qt` が使える。後の flake 適用＋再起動で **greetd + Hyprland** へ置き換わります）
   - パーティション: ディスク消去（UEFI / GPT）を選択。swap は **No swap**（`zramSwap` を使用）でも問題ない
3. 完了後に USB を抜いて再起動し、日本語 **LXQt** デスクトップへ `mitac` でログインする。
4. 端末（QTerminal 等）を開き、作業コピーを `~/MySettings` へ取得する（初回環境のため `nix-shell` で `git` を一時利用）：
   ```bash
   nix-shell -p git --run \
     'git clone -b main https://github.com/mitac31709/MySettings.git ~/MySettings'
   cd ~/MySettings
   ```
5. **（既存バックアップまたは agenix 鍵を復元する場合）** OS ビルドの前に「[OS ビルド前に実機へ復元](#os-ビルド前に実機へ復元)」の手順で `./scripts/restore-on-nixos.sh`（別端末のバックアップや初期化後の新端末構築では `--from <chromebook|vaio|mitac> --new-device`）を実行する。不足ツール（`restic` / `rclone` / `jq` / `python3` / `rbw` / `pinentry-qt`）を自動取得し、**`rbw` で Bitwarden（`restic-home` および登録済みなら `agenix-master-key`）を自動読込**して Google OAuth・暗号化パスワード・`/etc/agenix/master.key` を自動配置します（`/home` バックアップを使わず **agenix マスター鍵だけを復元**する場合は `./scripts/restore-on-nixos.sh --agenix-only`）。初回は `rbw` 設定・ログインのみ案内に従います（`restic-home` 未登録なら対話入力・ブラウザー OAuth へフォールバック）。バックアップ内の `/home/mitac`（`/home/mitac/.local/share/fonts/hiragino-otf/` を含む）およびシステム状態が**元の位置へ復元**されます（`/etc/agenix/master.key` やシステム状態の反映時のみ `sudo` パスワード入力が必要。今回新規取得・更新した `~/.config/rclone/rclone.conf` は保持され、`--new-device` 指定時は既存の `~/MySettings`・`rbw`・`rclone.conf` を保持したうえで Tailscale/WARP/Bluetooth・各種端末 ID/トークン・Wi-Fi の NIC 名縛りを初期化し、複数端末の同時稼働で競合しない状態にします）。展開確認のみしたい場合は `./scripts/restore-on-nixos.sh --new-device /var/tmp/restore-check` のように展開先を引数指定します。
6. 実機の `hardware-configuration.nix` を生成し、flake を適用する（対象は `vaio` または `chromebook`）：
   ```bash
   # VAIO の場合（Chromebook は hosts/chromebook/hardware-configuration.nix と .#chromebook）
   sudo nixos-generate-config --show-hardware-config > hosts/vaio/hardware-configuration.nix

   # 適用（~/.local/share/fonts/hiragino-otf が既にある場合は `--impure` を追加）
   sudo NIX_CONFIG='experimental-features = nix-command flakes' \
     nixos-rebuild switch --flake .#vaio
   ```
7. 完了後、カーネル／bootvine／`greetd`／Hyprland セッションへクリーンに切り替えるため `sudo reboot` する。
   （※ この flake は一時的な LXQt を含まないため、再起動後は `ReGreet` + Hyprland のみになります。後で旧世代の LXQt ストアパスを掃除したい場合は `sudo nix-collect-garbage -d` を実行できます）

#### パターン B: Live USB（CLI）から `nixos-install --flake` で直接導入

GUI インストーラを経由せず、USB のターミナルから直接この flake の環境を書き込む手順です（Graphical ISO の GUI 端末でも、Minimal ISO の TTY コンソールでも実行できます。Live 環境上には `/home/mitac/.local/share/fonts/hiragino-otf` が無いため、初回は Noto CJK でビルドされます）。

1. Minimal ISO の TTY を使う場合だけ、文字化け防止のためロケールは ISO 既定の英語（`en_US.UTF-8`）のまま（Graphical ISO の端末なら日本語のまま可）、必要なら日本語配列とネットワークを設定する：
   ```bash
   loadkeys jp106
   nmtui                        # Wi-Fi / 有線ネットワーク接続
   ```
2. `lsblk` で対象ディスクを確認し、GPT パーティション作成・フォーマット・マウントを行う（**対象ディスクの全データが消去されます**。例: NVMe の `/dev/nvme0n1` — eMMC なら `/dev/mmcblk0`、SATA なら `/dev/sda` に読み替え）：
   ```bash
   sudo parted /dev/nvme0n1 -- mklabel gpt
   sudo parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
   sudo parted /dev/nvme0n1 -- set 1 esp on
   sudo parted /dev/nvme0n1 -- mkpart root ext4 1GiB 100%

   sudo mkfs.fat -F 32 -n boot /dev/nvme0n1p1
   sudo mkfs.ext4 -L nixos /dev/nvme0n1p2

   sudo mount /dev/nvme0n1p2 /mnt
   sudo mkdir -p /mnt/boot
   sudo mount -o umask=0077 /dev/nvme0n1p1 /mnt/boot
   ```
3. ハードウェア設定生成と作業用リポジトリの用意を行う（`/mnt/home/mitac` は `nixos-install` 時に正しい所有者で作成させるため、ここでは `/tmp/MySettings` へ clone します）：
   ```bash
   sudo nixos-generate-config --root /mnt

   nix-shell -p git --run '
     sudo git clone -b main https://github.com/mitac31709/MySettings.git /tmp/MySettings
   '

   # 生成した実機構成を対象ホストへコピー（Chromebook の場合は chromebook に読み替え）
   sudo cp /mnt/etc/nixos/hardware-configuration.nix \
     /tmp/MySettings/hosts/vaio/hardware-configuration.nix
   ```
4. （任意・`secrets/*.age` を利用済みの場合）`rbw` または USB メディアから共通マスター鍵を `/mnt/etc/agenix/master.key`（`0400` / `root:root`）へ先行配置しておくと、次の `nixos-install` 直後から Wi-Fi・Tailscale・GitHub・SSH・backup 用シークレットが有効になります（再起動後に `./scripts/restore-on-nixos.sh --agenix-only` または `secrets bootstrap` で配置して `rebuild` することも可能です）。
   ```bash
   # 例: USB 等から手動配置する場合
   sudo install -d -m 0700 -o root -g root /mnt/etc/agenix
   # sudo install -m 0400 -o root -g root /path/to/master.key /mnt/etc/agenix/master.key
   ```
5. flake でインストールする（対象は `#vaio` または `#chromebook`）：
   ```bash
   sudo NIX_CONFIG='experimental-features = nix-command flakes' \
     nixos-install --flake /tmp/MySettings#vaio
   ```
   プロンプトに従って `root` パスワードを設定する。
5. **【必須】再起動前に作業コピーの配置・`mitac` のパスワード設定・所有者変更を行う**（`modules/nixos/common.nix` に初期パスワードが無いため、未設定だと `ReGreet` でログインできません）：
   ```bash
   sudo cp -a /tmp/MySettings /mnt/home/mitac/MySettings
   sudo nixos-enter --root /mnt
   passwd mitac
   chown -R mitac:users /home/mitac/MySettings
   exit
   ```
6. アンマウントして USB を抜き、再起動する：
   ```bash
   sudo umount -R /mnt
   sudo reboot
   ```

### 2. 初回ログイン後の設定チェックリスト

再起動後の `ReGreet` でユーザー `mitac` を選んでログインすると **Hyprland (UWSM)** が起動します（端末: **Ctrl+Alt+T** / **Super+Return**、IME トグル: **Ctrl+Super+Space**、英数⇔日本語: **半角/全角**、ランチャー: **Super+D** / **Super+Space** / **Alt+Space**）。秘密情報はこのリポジトリ内の **`secrets/*.age`（agenix）+ Bitwarden（`agenix-master-key`）** で宣言的に管理できます。未展開または未移行の項目のみ実機で設定します。

1. **宣言的シークレットの展開（`secrets/*.age` を利用している場合）**:
   - `/etc/agenix/master.key` をまだ配置していない場合は、まず `secrets bootstrap`（または `cd ~/MySettings && ./scripts/restore-on-nixos.sh --agenix-only`）を実行して Bitwarden の `agenix-master-key` を配置し、`rebuild` を実行します（`/run/agenix/*`・Wi-Fi プロファイル・`gh` 認証・SSH 鍵・backup 鍵・ユーザー環境変数が一括展開されます）。
2. **GitHub 認証（`gh`）**:
   - `gh-hosts.yml.age` を登録済みなら `~/.config/gh/hosts.yml` に自動展開済み（`gh auth status` で確認）。未登録・再認証時は `gh auth login` を実行し（`programs.gh` の `gitCredentialHelper` が有効なため、以降の `~/MySettings` での `git push` / `pull` にも使われます）、必要なら `secrets import-gh` で `.age` 化します。
3. **VPN（Tailscale / Cloudflare WARP）**:
   - Tailscale: `tailscale-authkey.age` が有効なら自動認証されます（自宅外でのみ必要な場合は `ts-home-routes off` のまま維持）。手動認証またはキー失効時は `sudo tailscale up --operator=mitac`
   - Cloudflare WARP: `warp-cli registration new` → `warp-cli connect`
4. **暗号化バックアップの復元または新規設定**:
   - **別機体の既存バックアップから復元する場合**: 「[OS ビルド前に実機へ復元](#os-ビルド前に実機へ復元)」のとおり `./scripts/restore-on-nixos.sh --from <chromebook|vaio|mitac> --new-device` を実行し（`rbw` で Bitwarden の `restic-home` と `agenix-master-key` を自動取得・**新しい鍵を作らないこと**）、既存の `~/MySettings`・`rbw`・一時 `rclone.conf` を保持しつつ `/home/mitac` を復元する（端末 ID 衝突防止のため Bluetooth/WARP・P2P・トークン系ログインは新端末で初回サインイン。Wi-Fi と Tailscale は `/etc/agenix/master.key` 導入＋`rebuild` で自動展開）。各端末の自動バックアップ先はホスト別リポジトリ（`chromebook-home` / `vaio-home`）へ分離されているため、既存端末と同時運用しても互いにロックやスナップショットを上書きしません。`/etc/agenix/master.key` が配置され `rebuild` 済みであれば、日次バックアップおよび `backup` CLI は追加の `rbw` 解錠不要で動作します。
   - **新規でバックアップを初期構築する場合**: 「`/home の暗号化バックアップ` → `初回セットアップ`」に従い、GCP OAuth クライアント作成 → `backup setup` を実行して `secrets/rclone-conf.age` と `secrets/restic-home-password.age` を agenix へ登録し、`rebuild` 後 `backup run` を実行する。
5. **ヒラギノフォント（任意）**:
   `/home/mitac/.local/share/fonts/hiragino-otf/` に OTF ファイルを配置し、`rebuild` を実行する（ディレクトリが存在すると `rebuild` が自動で `--impure` を付けて同梱します）。
6. **その他の任意設定と実機確認**:
   - **リモートビルダー**（`modules/nixos/remote-builder.nix`）: `id-wsl-builder.age` を登録済みなら `/run/agenix/id-wsl-builder-root`（`nix-daemon` 用）と `/run/agenix/id-wsl-builder-user`（`ssh` / `~/.ssh/id_wsl_builder`）が自動展開されます（公開鍵は `galleria-mitac` 側へ登録）。未配置でもタイムアウト後にローカルビルドへフォールバック。待ち時間を省くなら `sudo nixos-rebuild switch --flake .#vaio --option builders ""` を実行。
   - **dsh-TUI**: `npm i -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui`
   - **ハードウェア確認**: 下記「VAIO オーディオ確認」「Chromebook オーディオ確認」「VA-API / Parsec 確認」を実行する。

### Chromebook を btrfs 透過圧縮でクリーン再インストール

Chromebook（delbin）を既存の `ext4` から `btrfs`（`compress=zstd:1`）へ安全に切り替える手順です。`modules/nixos/common.nix` は `fileSystems` 内の `btrfs` を自動検出し、有効化された環境でのみ `compsize` と月次の `services.btrfs.autoScrub` を組み込みます（現在の `hosts/chromebook/hardware-configuration.nix` は `ext4` のままなので、実機を入れ替える前の既存環境にも影響しません）。

#### 事前準備（移行前の現在の Chromebook 上）

1. **最新のバックアップを取得・確認する**：
   ```bash
   backup run
   backup log
   backup snapshots
   ```
2. `~/MySettings` に未プッシュの変更があれば確認して GitHub へプッシュする（`git status`）。`secrets/*.age` もコミット・プッシュ済みか確認する（`secrets check --decrypt`）。
3. 再インストール後に `./scripts/restore-on-nixos.sh` が `rbw` で自動取得できるよう、Bitwarden に **`agenix-master-key`** と緊急復旧用 **`restic-home`**（暗号化パスワード + OAuth 情報）が保存されていることを確認しておく。あわせて、必要に応じて **別の USB メモリ等へ `/etc/agenix/master.key` を退避**しておくこともできます（Git には絶対に含めない；`sudo cat /etc/agenix/master.key` 等で退避しておけば Bitwarden 経由なしでも即展開可能）。

#### Live USB からの `btrfs` 導入（CLI 手順）

Calamares（Graphical ISO）で `btrfs` を選ぶと初回導入時は `compress=zstd:1` が付かないため、**Live USB のターミナル（Graphical ISO の GUI 端末、または Minimal ISO の CLI）から下記手順で最初からマウントオプション付きで導入する**のが確実です（最初の `nixos-install` 時点から `/nix/store` も圧縮されます）。

1. Live USB を UEFI 起動し、ネットワーク等を接続する（Minimal ISO の TTY を使う場合のみ、`en_US.UTF-8` のまま `loadkeys jp106` と `nmtui` を実行）：
   ```bash
   loadkeys jp106
   nmtui
   ```
2. `lsblk` で内蔵ストレージを確認し、GPT パーティション作成・フォーマットを行う（delbin は個体により NVMe の `/dev/nvme0n1` または eMMC の `/dev/mmcblk0`。以下は `nvme0n1` の例、eMMC なら `/dev/mmcblk0p1`・`p2` に読み替え。**既存 ext4 データは消去されます**）：
   ```bash
   sudo parted /dev/nvme0n1 -- mklabel gpt
   sudo parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1GiB
   sudo parted /dev/nvme0n1 -- set 1 esp on
   sudo parted /dev/nvme0n1 -- mkpart root btrfs 1GiB 100%

   sudo mkfs.fat -F 32 -n boot /dev/nvme0n1p1
   # 既存の ext4 署名を上書きするため -f を指定
   sudo mkfs.btrfs -f -L nixos /dev/nvme0n1p2
   ```
3. サブボリューム（`@` / `@home` / `@nix` / `@log`）を作成し、`compress=zstd:1,noatime` でマウントする（同一プール上のため各領域の空き容量を柔軟に共有できます）：
   ```bash
   sudo mount /dev/nvme0n1p2 /mnt
   sudo btrfs subvolume create /mnt/@
   sudo btrfs subvolume create /mnt/@home
   sudo btrfs subvolume create /mnt/@nix
   sudo btrfs subvolume create /mnt/@log
   sudo umount /mnt

   sudo mount -o subvol=@,compress=zstd:1,noatime /dev/nvme0n1p2 /mnt
   sudo mkdir -p /mnt/{home,nix,var/log,boot}
   sudo mount -o subvol=@home,compress=zstd:1,noatime /dev/nvme0n1p2 /mnt/home
   sudo mount -o subvol=@nix,compress=zstd:1,noatime /dev/nvme0n1p2 /mnt/nix
   sudo mount -o subvol=@log,compress=zstd:1,noatime /dev/nvme0n1p2 /mnt/var/log
   sudo mount -o umask=0077 /dev/nvme0n1p1 /mnt/boot
   ```
4. `hardware-configuration.nix` を生成して `#chromebook` をインストールする：
   ```bash
   sudo nixos-generate-config --root /mnt

   nix-shell -p git --run '
     sudo git clone -b main https://github.com/mitac31709/MySettings.git /tmp/MySettings
   '

   sudo cp /mnt/etc/nixos/hardware-configuration.nix \
     /tmp/MySettings/hosts/chromebook/hardware-configuration.nix

   sudo NIX_CONFIG='experimental-features = nix-command flakes' \
     nixos-install --flake /tmp/MySettings#chromebook
   ```
5. （任意・USB 等に `master.key` を退避している場合）`/mnt/etc/agenix/master.key` を `0400` で配置し、`MySettings` の配置・`mitac` パスワード設定・所有者変更を行ってから再起動する：
   ```bash
   # 例: master.key を先行配置する場合
   # sudo install -d -m 0700 -o root -g root /mnt/etc/agenix
   # sudo install -m 0400 -o root -g root /path/to/master.key /mnt/etc/agenix/master.key

   sudo cp -a /tmp/MySettings /mnt/home/mitac/MySettings
   sudo nixos-enter --root /mnt
   passwd mitac
   chown -R mitac:users /home/mitac/MySettings
   exit

   sudo umount -R /mnt
   sudo reboot
   ```

#### 再起動後の復元と圧縮確認

1. `ReGreet` で `mitac` にログインする（日本語 Hyprland 環境が起動します。端末は **Ctrl+Alt+T**）。
2. `cd ~/MySettings && ./scripts/restore-on-nixos.sh --from <vaio|chromebook|mitac> --new-device` を実行する（VAIO 側の最新環境を戻すなら `--from vaio --new-device`、旧来の単一バックアップから戻すなら `--from mitac --new-device`）。`rbw` の設定・ロック解除・同期を経て Bitwarden の `restic-home` から暗号化パスワードと Google OAuth 情報が自動取得され、Bitwarden に **`agenix-master-key`** がある場合は `/etc/agenix/master.key` も同時に配置されます。
3. 上記コマンド（`--new-device` 付き）により、新しく生成済みの `~/MySettings`（新しい Btrfs UUID の `hosts/chromebook/hardware-configuration.nix`）や現在の `rbw` / `rclone.conf` を壊さずに `/home/mitac` が復元され、Bluetooth / WARP・P2P 鍵・トークン系認証は他端末と競合しないよう初期状態にリセットされます。その後 `rebuild` を実行すると、`/run/agenix/*` の各種シークレット・`restic`/`rclone` 設定・保存済み Wi-Fi・GitHub CLI 認証・SSH 鍵・Tailscale 鍵が agenix から宣言的に展開されます。
4. 圧縮率と scrub タイマーを確認する：
   ```bash
   sudo compsize / /nix/store /home
   systemctl list-timers 'btrfs-scrub*'
   ```
5. `gh auth status` を確認し（`gh-hosts.yml.age` 未設定時のみ `gh auth login`）、`~/MySettings/hosts/chromebook/hardware-configuration.nix`（新しい Btrfs UUID / サブボリューム構成）をコミット・プッシュする。

## 適用手順

新しく USB から環境を構築する場合は、先に「[USB からの新規インストールと初回設定](#usb-からの新規インストールと初回設定)」を参照してください。既存バックアップからデータを戻す場合は、先に「[OS ビルド前に実機へ復元](#os-ビルド前に実機へ復元)」を実行してください。

```bash
# NixOS マシン上で、このリポジトリから:
git checkout main

# 1) VAIO（Intel 第8世代以降）の場合 — 初回はハードウェア設定の差し替えが必須:
sudo nixos-generate-config --show-hardware-config > hosts/vaio/hardware-configuration.nix
sudo nixos-rebuild switch --flake .#vaio

# 2) Chromebook（ASUS CX5500FE / delbin）の場合（別個体では再生成）:
# sudo nixos-generate-config --show-hardware-config > hosts/chromebook/hardware-configuration.nix
sudo nixos-rebuild switch --flake .#chromebook
# ※ 後方互換エイリアス `.#mitac` も `.#chromebook` を指します

# Home Manager 適用後は、どのディレクトリからでも:
#   rebuild                                           # 現在のホストターゲット（vaio / chromebook）を再ビルド
#   rebuild vaio                                      # 引数でターゲット明示も可能
#   rebuild --restore                                 # バックアップを事前検証し、次回 OS 再起動時に自動復元
#   rebuild --restore --from vaio --new-device        # 別端末バックアップから新端末向けに次回再起動時復元を予約
#   rebuild --restore --reboot                        # 予約・再ビルド完了後にそのまま再起動
#   rebuild --restore-status / --restore-cancel       # 予約状態の確認／キャンセル

# 必要なら:
passwd mitac
```

`flake.lock` はリポジトリに含まれます。シェル関数 `rebuild`（既定ターゲットは各ホストの `flakeTarget`／未指定時のフォールバックは `lib/machine.nix` の `flakeHost`、引数で `.#vaio` / `.#chromebook` の切り替え可。先に `sudo` 認証、通常表示のままビルド中だけ `nom` ETA）とエイリアス `generations` は `home/shell.nix` で定義されます。flake の作業コピーは `lib/machine.nix` の `repoPath`（既定 `/home/mitac/MySettings`）だけです。Home Manager の `mitac.repoPath` / `mitac.flakeHost` で上書きできます。`rebuild` / `flake-update` はそのパスの `flake.nix` を使います。スクリプト本体は Nix ストアのコマンドで、チェックアウトの `scripts/` を直接実行しません。

## flake の更新

`flake-update`（チートシート `Super+/` からも起動）は端末内のほぼすべてのソフトウェアをまとめて更新します（**JQuake のみ 1.8.4 固定**）。実行すると順番に次を行います。

1. `flake.nix` の pinned `.deb` URL 更新（UniClipboard / ChatGPT / Grok Bot）
2. `pkgs/` の独自パッケージ更新（**Meltype** / **OpenCode** / **Antigravity** / **wol-pc**。`nix store prefetch-file` でハッシュ再計算）
3. `nix flake update` により `flake.lock` の全入力更新（`nixpkgs` / `nixpkgs-cursor` / `colorshell` / `bootvine` / `home-manager` 等）
4. `~/.local/share/npm-global` に導入済みの場合、`@deepseek-ai/dsh` / `@deepseek-harness-tui/dsh-tui` の `npm` 更新
5. `rebuild`（`nixos-rebuild switch`）をそのまま実行するかの対話確認

Cursor（`code-cursor` / `cursor-cli`）だけ先行更新したいときは `flake-update-cursor`（または `nix flake update nixpkgs-cursor`）も引き続き使えます。

```bash
flake-update          # 一括チェック & 更新 → rebuild 確認
flake-update-cursor   # Cursor (nixpkgs-cursor) だけ更新
```

## 同梱ソフトウェア

- **Neovim** — **LazyVim**（`home/nvim`）。コアプラグインと treesitter のパーサは nixpkgs から同梱し、起動時に git clone しない
- **Cursor** — `code-cursor`（GUI）／`cursor-cli`（ターミナル Agent: `cursor-agent` / `agent`）
- **Zed** — `zed-editor`（起動: `zeditor`、アプリメニュー: Zed）
- **OpenCode** — ターミナル AI コーディングエージェント（`opencode`、nixpkgs `opencode`）
- **Claude Code** — Anthropic のターミナルエージェント（`claude`、nixpkgs `claude-code`）
- **T3 Code** — 複数コーディングエージェントを束ねるデスクトップ／CLI（`pkgs/t3code` で **0.1.11** へオーバーライド + Antigravity 1.5 クォータ自動再開パッチ適用、`t3` / `t3code-desktop`）。Claude・Cursor・OpenCode・Antigravity を PATH に載せて起動し、`home/t3code.nix` で `~/.local/share/t3/userdata/settings.json` の `antigravity.config.binaryPath` を `"antigravity"` に同期（同梱ランタイム 1.4.5 ではなく CLI 1.5+ を使い Orchestrator モデル表示・Antigravity 1.5 サブエージェント表示・制限到達時の自動再開に対応）。Colorshell の右上に実行中のカードが出る（`pkgs/agent-run-status` が `~/.local/share/t3/userdata/server-runtime.json` のサーバへ RPC でつなぎ、`$XDG_RUNTIME_DIR/agent-run-status.json` を書く）。対象は `pkgs/t3code` の **0.1.11** だけ。版が変わると評価が止まるので、橋を合わせてから上げる。T3 を起動せず見た目だけ確認するときは `systemctl --user stop agent-run-status` のあと `agent-run-status mock running`（`approval` / `done` / `multi`）。消すときは `agent-run-status mock clear` して `systemctl --user start agent-run-status`
- **Hermes** — Nous Research のエージェント（`hermes` / `hermes-acp`）。flake 入力 `hermes-agent` + `home/hermes.nix`（CLI + ACP。gateway / Desktop は無し）。状態は `~/.local/share/hermes`。初回は `hermes setup` でプロバイダ認証し、T3 の Providers で Hermes / Local ACP を有効化。ACP 確認は `hermes acp --check`
- **Antigravity** — Google のターミナルエージェント（`agy` / `antigravity`、`pkgs/antigravity` で CLI バイナリをピン留め）
- **Local LLM (`llama.cpp` + `Qwen3.5-4B`)** — `home/local-llm.nix` により `pkgs.llama-cpp`（`llama-cli` / `llama-server` / `llama-bench`）とオンデマンドランチャー `local-llm`（`scripts/local-llm.py`）を導入。初回に `unsloth/Qwen3.5-4B-GGUF`（`Q4_K_M`、約 2.55 GiB、SHA-256 検証付き）を `~/.cache/local-llm/` へ自動取得し、CPU 物理コア数・`ctx=8192`・KV 量子化 `q8_0`・思考モード既定 OFF（`--thinking` で切替可）で `127.0.0.1:18922` に OpenAI 互換 API（`/v1`）と内蔵 WebUI を起動し、無通信 600 秒で自動停止して RAM を解放する。`local-llm web`（アプリメニュー `Local LLM (Qwen3.5-4B)`）/ `chat` / `ask` / `status` / `stop` に加え、`local-llm acp` で **T3 Code** 向け ACP v1（プローブ時は RAM 0、`qwen3.5:4b` / `qwen3.5:4b-thinking`、`code` / `ask` モード、`/clear` / `/stop` / `/status`）を提供
- **dsh-TUI** — DeepSeek Harness の TUI（`dsh-tui` / `dst`）。Node のグローバル npm（`~/.local/share/npm-global`、`~/.config/npm/npmrc` の `prefix`）へ `npm i -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui`。初回起動でプロファイルを初期化（`pnpm` 必須）。モデル利用は `DEEPSEEK_API_KEY` または `/auth`
- **ChatGPT** — 公式 Linux デスクトップ（Codex 含む、nixpkgs `chatgpt`）。アプリメニュー / `chatgpt`
- **Node.js / pnpm** — `node` / `npm` / `pnpm`（グローバル npm は `~/.local/share/npm-global`）
- **Parsec** — `parsec-bin`（Intel VA-API / `intel-media-driver` でハードウェアエンコード）。ホテル等で `-6023/-11010` になるときは Tailscale 経由（下記）
- **Steam** — `programs.steam.enable`
- **VirtualBox** — `virtualisation.virtualbox.host.enable`（Extension Pack 有効、`mitac` を `vboxusers` グループへ追加）
- **ActivityWatch** — `home/activitywatch.nix` で `aw-server`（Web UI: `http://127.0.0.1:5600`）と Hyprland 向け Wayland watcher（`awatcher`、`graphical-session.target` 起動）を常駐
- **WhatPulse** — `pkgs/whatpulse`（7.0.1 AppImage ラッパー）＋ `pkgs/whatpulse-pcap-service`（通信量計測用 systemd サービス）。`home/whatpulse.nix` の `whatpulse.service` でログイン時にトレイ常駐（`--minimized`）し、打鍵・マウス計測のため `mitac` を `input` グループへ追加済み
- **Screenpipe** — `pkgs/screenpipe`（2.7.145 AppImage ラッパー）。画面キャプチャ + OCR + 音声文字起こしのローカル検索タイムライン
- **Bottles** — Wine プレフィックス管理（一般の Windows アプリ用）。`home.packages`
- **Vivaldi** — `vivaldi`
- **Firefox** — `firefox`
- **Tor Browser** — `tor-browser`
- **Tilion Fortress** — ローカル版ステルス Chromium エンジン + CLI / MCP（`pkgs/tilion-fortress`：`tilion` / `tilion-mcp` / `tilion-fortress` / `fortress-browser`）。v3 機能を有効化する場合は `tilion activate` でライセンスを取得
- **Qalculate!** — 高機能関数電卓（Qt GUI `qalculate-qt` + CLI `qalc` / `libqalculate`）
- **JQuake** — `JQuake` / `jquake`（1.8.4 + `pkgs/jquake` ラッパー。Hyprland/XWayland AWT 修正・更新ダイアログ無効化）。ログイン時に `jquake.service` で常駐し、Hyprland では offscreen `stalonetray` にトレイを保持しつつ `jquake-open` / `jquake-toggle` / `jquake-menu`（チートシート `Super+/` やランナーから起動可）で表示・管理。Colorshell の JQuake ボタンはトグルで、表示中に押すとトレイへ戻す（サービスは常駐）。表示時・警報時はトップバーを残したままワークスペース領域いっぱいに最大化（フルスクリーンにしないため画面暗転なし）＋警報時は `hyprlock` 解除。Ctrl/Alt が押しっぱなしになるのを防ぐため、JQuake への強制フォーカス（Java/AWT の X キーボードグラブと競合して修飾キーの keyup を取りこぼす原因）をやめ、`alter_zorder` で前面化するだけにしている（`home/jquake.nix` / `home/hyprland.nix`）
- **ONLYOFFICE** — `onlyoffice-desktopeditors`（文書・表計算・プレゼン）
- **Affinity** — 未導入（`affinity-v3` なし。flake 入力も overlay も外してある）。戻すときは次の 3 箇所です。
  1. `flake.nix` の `inputs` に `affinity-nix.url = "github:mrshmllow/affinity-nix";` を足し、`nixpkgs.overlays` の先頭に `inputs.affinity-nix.overlays.default` を戻す
  2. `home/programs.nix` の `home.packages` に `affinity-v3` を足す
  3. `modules/nixos/common.nix` の `nix.settings` に `cache.forall.systems` の substituter と公開鍵を戻す（コメントに残してある）
  Wine ビルドはキャッシュが外れると数時間かかることがあります。RTC が NTP より遅れていると、このキャッシュの証明書エラーで他の取得まで止まります
- **LocalSend** — LAN ファイル転送（`programs.localsend`、ファイアウォール 53317）
- **RQuickShare** — Google Quick Share / Nearby Share の Linux クライアント（`rquickshare`）
- **wol-pc** — Wake-on-LAN クライアント（`pkgs/wol-pc` により `github:mitac-31709/wol-pc` をパッケージ化し、`wake-pc` / `wake-pc-relay` / `.desktop` を同梱。依存 `sshpass` / `zenity` 等をラップ済み）。設定は `WOL_PC_CONFIG` → `/run/agenix/wol-pc-env`（`secrets import-wol`）→ `~/.config/wol-pc/config.env` → `~/Projects/wol-pc/config.env` の順に読み込み、秘密値はストアへ含めない
- **7-Zip** — `_7zip-zstd`（コマンド `7z` / `7zz`、Zstd ほか対応）+ GUI `peazip`（PeaZip）
- **tmux** — `runbtop <cmd>` で上部に実行出力（約 10 行）、下部に `btop`
- **Meltype** — Fcitx5 エンジン（日本語／英語の自動打ち分け。縦型候補・意味/翻訳ペイン付き。IME は Meltype のみ）
- **フォント** — JetBrainsMono Nerd Font（ターミナル／等幅の既定）、Adwaita Sans / Mono（Colorshell・Hyprlock 用）
- **シークレット管理（agenix × Bitwarden）** — `secrets/*.age` を NixOS（`modules/nixos/secrets.nix`）で `/run/agenix/*` へ復号し、共通マスター鍵 `agenix-master-key` のみを Bitwarden（`rbw`）で保持。`secrets` コマンド（`scripts/secrets-tool.sh`）で管理
- **暗号化バックアップ** — `restic` + `rclone` で `/home` を Google Drive へ。`agenix` 移行時は `/run/agenix/` 経由で自動無監視実行（未移行時・他端末リカバリ時は Bitwarden `rbw`）。詳細は下記。
- **デスクトップ** — greetd + ReGreet（Hyprland (UWSM) + **Colorshell**。ログイン画面も受信専用 Lan Mouse 待機）
- **bootvine** — 起動コンソールに systemd ジョブの依存ツリーを表示（[bootvine](https://codeberg.org/wvhulle/bootvine)、`services.bootvine.enable`）。反映には `rebuild` のあと再起動が必要
- **起動音（`startup-sound`）** — ログイン時に `startup-sound.service` が歴代 Windows（3.1 / 95 / 98 / 2000 / XP / 7 / 11）・Mac・GameCube・Nintendo Wii・Wii Sports・ブルーアーカイブ・マリオカート8・お風呂が沸きましたチャイム（[お風呂のメロディー集【新新版】](https://youtu.be/alRIEBuUcKk)から抽出した新バージョン中心のノーリツ／リンナイ／パロマ／パーパス／パナソニック／コロナ／日立／トートー／タカラスタンダード／ダイキン／長府の計14種）・原神メインテーマ曲と `~/.local/share/startup-sounds/`（または `home/startup-sounds/`）の音声からランダム再生（`home/startup-sound.nix`）。チートシート `Super+/` や CLI から `startup-sound --list` / `--menu` / `--toggle` が利用可能
- **gui** — ディスプレイ無し時は `cage` で単一 GUI アプリを起動（`gui firefox` など）。引数なしは `apps` を起動
- **apps** — `fzf` アプリ一覧（`gui` 経由起動）。TTY やシェルから利用可。Hyprland の Super+D は Colorshell Runner

## 日本語入力（Meltype / Fcitx5）

[Meltype](https://github.com/yksr-melt/Meltype)（Linux プレビュー）を **Fcitx5** アドオンとして入れています（Hyprland Wayland 向け）。IME グループは **Meltype のみ**（`fcitx5-mozc` / `keyboard-jp` は入れない）。ローマ字の日本語と英語を自動で打ち分けます。

- **Ctrl+Super+Space**: Fcitx Trigger（IME 有効 ⇔ 無効。**Super+Space** は Hyprland の Colorshell Runner 用）。グループが Meltype だけなので、どちらもエンジンは Meltype のまま
- Meltype 内の英数 ⇔ 日本語: **半角/全角**（Fcitx の Trigger には割り当てない。ChatGPT 等 Electron で直接入力に落ちて戻せなくなるのを防ぐ）
- **z + 記号 / hjkl**: `zl`→`→`、`zh`→`←`、`zj`→`↓`、`zk`→`↑`、`z/`→`・`、`z.`→`…` など（Meltype 1.4+、既定 ON）
- 学習・設定: `~/.local/share/Meltype`（`home/meltype.nix` が **AppRules** を upsert。エンジンパッチではなくアプリ別設定で制御）
  - Cursor → **General**（矢印でも日本語維持。Code だと英数に戻る）
  - Ghostty（`com.mitchellh.ghostty`）→ **General** を指定（本家が `Terminal` トレイトを AppRules より優先するため、agy はまだ Code 相当のままになることがある）
  - rofi → Wayland では `program` が空のため、Meltype アドオンが `app="_empty"` とラベルし、AppRules で `Enabled: false`（英語のみ）
- 詳細設定: `meltype-settings`（または **Fcitx5 設定** `fcitx5-configtool`）
- プロファイル／config／ClassicUI: NixOS モジュールが生成する INI を、Home Manager が `~/.config/fcitx5/{profile,config,conf/classicui.conf}` へシンボリックリンクする（ClassicUI は本家準拠のダークテーマ `meltype-dark` と縦型候補、パッチ済み `pkgs/meltype` の注記・折り返し意味/翻訳ペインと empty-program ラベルを有効化）。Fcitx は `~/.config` を `/etc/xdg` より先に読むので、古いユーザコピー（`keyboard-jp` や半角/全角 Trigger）が勝たない。リンク先はストアで読み取り専用。変更は `modules/nixos/common.nix` の `i18n.inputMethod.fcitx5.settings`
- **rofi**: 英語のみ（AppRules `_empty`）+ `wayland-layer = top`
- **Cursor / ChatGPT** など Electron: `NIXOS_OZONE_WL=1` と Wayland IME フラグ。`ShareInputState=All` でフォーカス間の active/inactive ずれを抑える。適用後はアプリを**完全終了**してから開き直す
- 適用後: `rebuild` してから **fcitx5 再起動**（例: `fcitx5 -d --replace`）かセッション再ログイン

## フォント

比例フォントの第一候補はヒラギノです。fontconfig の既定は家族名のリストで、入っていない名前は飛ばします。ヒラギノが無い評価（他のマシン、`nix flake check`、`--impure` なし）では次のフォントが使われます。

- sans / 等幅の日本語: `Noto Sans CJK JP`（`noto-fonts-cjk-sans`）
- serif: `Noto Serif CJK JP`（`noto-fonts-cjk-serif`）
- 等幅のラテン: `JetBrainsMono Nerd Font`（Ghostty も 12pt）
- Cursor Gothic: `Cursor Gothic`（`pkgs/cursor-gothic`、Regular / Italic / Bold / BoldItalic の OTF を `fonts.packages` に同梱）

ヒラギノは flake input にしていません。`path:` 入力は、そのディレクトリが無いマシンで flake 全体の評価が失敗するためです。

有効にする手順:

1. OTF を ASCII 名で `/home/mitac/.local/share/fonts/hiragino-otf/` に置く（`~/Documents/ヒラギノ.zip` を展開。パスは `lib/machine.nix` の `hiraginoDir`）
2. `--impure` でビルドする。`rebuild` はこのディレクトリがあるときだけ `--impure` を付けます

仕組み: `builtins.pathExists` は pure 評価では flake の外の絶対パスを読めず、結果は false です。`--impure` のときだけ実在を見て、ある場合だけ `builtins.path` でストアへコピーし `fonts.packages` に足します。第一候補は sans `Hiragino Kaku Gothic ProN` / serif `Hiragino Mincho ProN` のままです。

waybar の CSS が名指しするのは `JetBrainsMono Nerd Font` だけです。日本語の字形は CSS では指定せず、fontconfig の既定（ヒラギノ、無ければ `Noto Sans CJK JP`）が埋めます。waybar のためだけに CJK フォントは足していません。

Nerd Font のアイコンが空白に見える場合: `fc-cache -rf` を実行し、ログアウトして再ログインします。

## ターミナル

既定は **Ghostty**（`programs.ghostty`）。**Ctrl+Alt+T** / **Super+Return** で開きます。
`TERMINAL=ghostty` も Home Manager で設定しています。

## タッチパッド

ナチュラルスクロールはオフ（従来型: 指を上 → 内容が上）。キーボード入力中もタッチパッドは有効（`disable_while_typing = false`）。右クリックは **2本指タップ／2本指押し**（`tap_to_click = true` + `clickfinger_behavior = true`）。端を押すソフトボタン領域は使わない。3本指左右スワイプでワークスペースを切り替えられる。VAIO（`.#vaio`）のみ `scroll_factor = 0.6` でスクロール速度をやや抑えている。Hyprland の `input.touchpad`（`home/hyprland.nix`）。

## クリップボード履歴

`cliphist`（systemd user の `wl-paste --watch`）+ `clipboard-history`（rofi → 選択で貼り付け）。呼び出しは **Super+V**。

## シークレット管理

`secrets/` 配下の暗号化ファイル（`.age`）と Bitwarden（`rbw`）を組み合わせた宣言的シークレット管理（`github:ryantm/agenix`）を採用しています。

### 設計（単一マスター鍵 + NixOS / Home Manager 連携）

- **全端末共通のマスター鍵**: Bitwarden の **`agenix-master-key`** 項目に保存した 1 本の `age` 秘密鍵を、各機体の `/etc/agenix/master.key`（`root:root` / `0400`）へ配置します（`age.identityPaths = [ "/etc/agenix/master.key" ]`）。新端末や SSD 再構築時も `secrets/agenix-rules.nix` の追記・`rekey` なしでそのまま複号できます。
- **インメモリ複号と権限分離**: `modules/nixos/secrets.nix` が NixOS 起動時に `/run/agenix/*`（`tmpfs`）へ複号します。平文は Nix ストアにも永続ディスクにも書き出されません。ユーザー領域向けの鍵・認証・環境変数は `home/secrets.nix`（Home Manager `osConfig` 参照）が `/run/agenix/*` へ安全にシンボリックリンク／ロードするため、`/etc/agenix/master.key` は **`root` 専用** のまま維持されます。
- **新規フォーク時のブートストラップ安全性**: `builtins.pathExists`（`hasSecretFile`）で宣言しているため、`secrets/*.age` をまだ生成していない初期フォークでもシステム評価が失敗しません。

| 暗号化ファイル (`secrets/`) | 展開先（ランタイム） | 用途 |
|-----------------------------|----------------------|------|
| `restic-home-password.age` | `/run/agenix/restic-home-password` | `restic-backups-home` 用の唯一のリポジトリ暗号化パスワード（緊急復旧用に Bitwarden `restic-home` にも同一値を保存可） |
| `rclone-conf.age` | `/run/agenix/rclone-conf` | `rclone` 用 Google Drive 設定（実行時に書き込み可能な `/run/restic-backups-home/rclone.conf` 等へコピーし OAuth 自動更新に対応） |
| `nm-connections.age` | `/run/agenix/nm-connections` | NetworkManager Wi-Fi プロファイル群（`nm-agenix-profiles.service` が `interface-name=` / `mac-address=` を除いて `/run/NetworkManager/system-connections/agenix-*.nmconnection` へ展開し、重複する `/etc/NetworkManager/system-connections/*.nmconnection` の Wi-Fi を自動削除。さらに `nm-agenix-sync.{path,service}` と `secrets sync-wifi` が `nmcli` / `nmtui` で追加・編集された Wi-Fi を既存プロファイルを保持したまま自動マージ同期） |
| `tailscale-authkey.age` | `/run/agenix/tailscale-authkey` | Tailscale 事前認証／OAuth キー（`services.tailscale.authKeyFile`） |
| `id-wsl-builder.age` | `/run/agenix/id-wsl-builder-{root,user}` | `nix-daemon` 用ビルド鍵（`nix.buildMachines[0].sshKey`）兼 `~/.ssh/id_wsl_builder`（`secrets/id-wsl-builder.pub` があれば `~/.ssh/id-wsl-builder.pub` もリンク） |
| `id-ed25519.age` | `/run/agenix/id-ed25519` | 個人用 SSH 秘密鍵 `~/.ssh/id_ed25519`（`secrets/id_ed25519.pub` があれば `.pub` もリンク） |
| `gh-hosts.yml.age` | `/run/agenix/gh-hosts.yml` | GitHub CLI 認証 `~/.config/gh/hosts.yml` |
| `user-env.age` | `/run/agenix/user-env` | `export KEY=...` 形式の API トークン等（`bash` 初期化時読込 + `mitac-agenix-user-env.service` で `systemd --user` へ反映） |
| `wol-pc-env.age` | `/run/agenix/wol-pc-env` | Wake-on-LAN 設定（`wake-pc` が `/run/agenix/wol-pc-env` または `$WOL_PC_CONFIG` を参照） |
| `adbkey.age` | `/run/agenix/adbkey` | ADB USB デバッグ秘密鍵 `~/.android/adbkey`（`secrets/adbkey.pub` があれば `~/.android/adbkey.pub` もリンク） |
| `opencode-service.json.age` | `/run/agenix/opencode-service.json` | OpenCode ローカルサービスパスワード `~/.config/opencode/service.json` |
| `lan-mouse-{chromebook,vaio}.pem.age` | `/run/agenix/lan-mouse-{,greeter-}pem` | 端末別 Lan Mouse TLS 秘密鍵（`mitac` `~/.config/lan-mouse/lan-mouse.pem` と `greeter` 用で同一ホスト鍵を共有） |

### 初回セットアップ・日常運用（`secrets` CLI）

`scripts/secrets-tool.sh` が PATH 上の **`secrets`** コマンドとして同梱されています。

```bash
# 1. 初回のみ: マスター age 鍵を生成し Bitwarden (agenix-master-key) と /etc/agenix/master.key へ登録
secrets init

# 2. 現在のマシン上の秘密情報から .age を対話的に一括作成
secrets import
# 個別に取り込む場合:
#   secrets import-restic / import-rclone [FILE] / import-ssh / import-gh / import-wifi
#   secrets import-wol / import-adb / import-opencode / sync-wifi
#   secrets set-tailscale-key

# 3. 暗号化ファイルをステージして複号検証し、OS に反映
git add secrets/
secrets check --decrypt
rebuild
```

- **新端末／再インストール時の展開**:
  - `./scripts/restore-on-nixos.sh --agenix-only`（または既存バックアップ復元と同時の `./scripts/restore-on-nixos.sh --from ... --new-device`）
  - すでに環境適用後なら `secrets bootstrap`（インストーラ等の `/mnt` 配下には `secrets bootstrap /mnt`）→ `rebuild`
- **個別編集・Wi-Fi 自動同期・鍵ローテーション・状態確認**:
  - `secrets edit <name>`（例: `secrets edit user-env`、`name` は `secrets/agenix-rules.nix` の定義名または `.age` ファイル名）
  - `secrets sync-wifi`（`nmcli` / `nmtui` 変更を既存 `secrets/nm-connections.age` へ非破壊マージ同期；通常は `nm-agenix-sync.path` が自動実行）
  - `secrets status` / `secrets rekey` / `secrets check [--decrypt]`
- **リポジトリ公開設定・セキュリティ注意**:
  - 平文鍵ファイル（`secrets/*.key`, `secrets/*.plain`, `secrets/*.tmp`, `secrets/*~`）は `.gitignore` で除外しています。
  - `.age` 自体はマスター鍵なしでは複号できませんが、ファイル名と暗号文が Git 履歴に残るため GitHub リポジトリの可視設定（Private 推奨）や公開鍵ファイルの扱いに注意してください。
  - 緊急リカバリ（OS ビルド前の `restore-on-nixos.sh`）用に、Bitwarden の `agenix-master-key`（および任意で `restic-home`）も保持できます。

## /home の暗号化バックアップ

`modules/nixos/backup.nix` は、ユーザーのホームと**非シークレットのシステム状態**を暗号化して **Google Drive** へバックアップします。

- **restic** — `/home/mitac`（PlatformIO/Arduino/npm/pnpm store や Electron/browser キャッシュ、`.cache`、Steam ランタイム、agenix で管理している秘密情報・`.backup` 残骸等は `modules/nixos/backup.nix` で除外）に加え、agenix で表現できない端末固有状態（Bluetooth ペアリング・Cloudflare WARP 状態）の一時コピー（staged）を暗号化・重複排除してスナップショット保存します（Wi-Fi と Tailscale 鍵は `agenix` に一元化したためバックアップ対象外）。
  なお、起動・編集で都度書き換わる Writable アプリ設定の一部（Cursor `settings.json` / `argv.json`、Lan Mouse 承認済み指紋、JQuake 設定既定値など）は Flake でも宣言的に再現されるため、`restic` バックアップは「日々の未反映変更や動的状態の保険」として機能します。
- **rclone** — Google Drive バックエンド（ホスト別 restic リポジトリ: `rclone:gdrive:restic/<host>-home` — `.#chromebook` は `chromebook-home`、`.#vaio` は `vaio-home`。旧単一構成の移行前バックアップは `mitac-home` に残ります）。各端末は共通の `gdrive:` リモートと暗号化鍵を agenix 経由で共有しつつリポジトリ自体が分かれているため、複数端末を同時起動してもロック競合や世代削除（`forget`）の干渉は起きません。
- **agenix 一元管理** — `services.restic.backups.home` と `backup` CLI は `/run/agenix/restic-home-password` と `/run/agenix/rclone-conf` のみを参照して動作するため、**タイマー実行・CLI ともに `rbw` 解錠や `~/.config/rclone/rclone.conf` の平文保存を要しません**（平文は `/run` のみで、`rclone.conf` は OAuth リフレッシュ対応のため実行時一時ファイルへコピーして使用）。`backup reconnect` で OAuth 再認証した場合も自動で `secrets import-rclone` 経由で `secrets/rclone-conf.age` を更新します。

日次の `systemd` タイマー（`restic-backups-home.timer`）がバックアップを実行し、古いスナップショットを整理します（`--keep-daily 7 --keep-weekly 5 --keep-monthly 12`）。グラフィカルセッションへのログイン中は **Hyprland の waybar** に進捗（`バックアップ N%`、`$XDG_RUNTIME_DIR/restic-home-status` 経由）が表示され、開始・完了（または失敗）が mako 通知で知らされます。

`backup status` はサービス／タイマーの状態と次回実行、Google Drive の使用量とリポジトリ容量（重複排除・圧縮後の実データ）、直近スナップショットの日時・処理時間・ファイル増減・追加データをまとめて表示します。`backup status --full` で systemd 詳細と直近ログも確認できます。

### バックアップの削除（空き容量の回収）

restic は個別ファイルを削除できず、**スナップショット単位**で削除します。`forget` はスナップショットを一覧から外すだけなので、容量を回収するには **`--prune`（または後続の `backup prune`）が必要**です。日次バックアップ後の保持ポリシー適用は自動で行われます。

```bash
backup snapshots                              # まず ID を確認
backup forget <ID> --prune                    # 指定スナップショットを削除して回収
backup forget --keep-last 3 --prune           # 直近3世代だけ残す
backup forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune  # 既定の保持ポリシー
backup prune                                  # 参照されなくなったデータだけ回収

# 破壊的なので事前に対象を確認（推奨）
backup forget --keep-last 3 --prune --dry-run
```

リポジトリ全体を消す場合は、agenix の設定を**書き込み可能な一時ファイル**へコピーしてから `rclone purge` します。素の `rclone` は `~/.config/rclone/rclone.conf` を探すため、`gdrive` セクションが見つからず失敗します。

```bash
tmp_conf="$(mktemp)"
install -m 600 /run/agenix/rclone-conf "$tmp_conf"
RCLONE_CONFIG="$tmp_conf" rclone purge gdrive:restic/mitac-home   # 全世代が消えるので要注意
# OAuth トークンが更新された場合は: secrets import-rclone "$tmp_conf"
rm -f "$tmp_conf"
```

他ホストのリポジトリを restic 系コマンドで操作する場合は `RESTIC_REPOSITORY=rclone:gdrive:restic/chromebook-home backup …` を付けます。

### 初回セットアップ（秘密情報は平文で git / Nix ストアに含めない）

1. 必要に応じて識別子・設定を確認します。
   - `home/programs.nix`: `programs.rbw.settings.email` → 自分の Bitwarden メールアドレス。
   - `modules/nixos/backup.nix`（任意）: `repository`、`paths`。
2. **rebuild**: `sudo nixos-rebuild switch --flake .#vaio`（または `.#chromebook`）。
3. **自分専用の Google Drive OAuth クライアントを作成**（必須: rclone 共有の `client_id` は 2026 年に廃止予定であり、共有クォータでは復元が極端に遅くなるため）。[Making your own client_id](https://rclone.org/drive/#making-your-own-client-id) も参照してください。
   1. [Google Cloud Console](https://console.cloud.google.com/) → 新規プロジェクトを作成（例: `rclone-mitac`）。
   2. **APIs & Services → Library**（API とサービス → ライブラリ）→ **Google Drive API** を有効化。
   3. **OAuth consent screen**（OAuth 同意画面）→ User type で **External**（外部）を選択 → アプリ名とメールアドレスを設定。
   4. **Data Access**（データアクセス）→ 次のスコープを追加:
      - `https://www.googleapis.com/auth/docs`
      - `https://www.googleapis.com/auth/drive`
      - `https://www.googleapis.com/auth/drive.metadata.readonly`
   5. **Audience**（対象）→ **+ Add users** → テストユーザーに自分の Google アカウントを追加。
   6. **Clients → Create OAuth client**（クライアント → OAuth クライアントを作成）→ Application type で **Desktop app**（デスクトップ アプリ）を選択して作成。
      表示された **Client ID** と **Client secret** を控えます（秘密情報のため絶対にコミットしない）。
   7. **Audience → Publish app**（対象 → アプリを公開、Testing から移行）。**無人バックアップには必須です** — Testing 状態のままだとリフレッシュトークンが約 **7 日ごと** に失効します（`invalid_grant` / `rclone config reconnect gdrive:`）。個人利用（単一ユーザー）であれば公開にあたって Google の審査（Verification）は不要です（再接続時に一度「未確認のアプリ」警告が出ますがそのまま進めて問題ありません）。
      **Publish** がグレーアウトされている場合、Google は**自身が所有するドメイン**（Search Console で所有権確認済み）でのブランディング設定を要求します。`github.io` は拒否されることが多いため、次のように設定します。
      - アプリ名（完全一致）: `restic Home Backup`
      - ホームページ: https://restic-oauth.mitac.f5.si/
      - プライバシーポリシー: https://restic-oauth.mitac.f5.si/privacy.html
      - 承認済みドメイン: `mitac.f5.si`（GCP プロジェクトと同じ Google アカウントで [Search Console](https://search.google.com/search-console) のドメインプロパティとして所有権を確認）
      保存後、所有権確認直後の場合は最大 24 時間待ち、ブランディング再審査を **「問題は修正した」** でリクエストしてください（指摘事項は実際の設定不備によるものなので、「指摘に誤りがある」は選ばないこと）。その後 **Audience → Publish** を押します。
      参考: [rclone: Making your own client_id](https://rclone.org/drive/#making-your-own-client-id)
4. **対話式セットアップを実行**（rclone `gdrive` OAuth → Bitwarden 鍵 → 初回バックアップ）:
   ```bash
   backup setup          # restic-home-setup と同じ
   ```
   rclone から `client_id` / `client_secret` を尋ねられたら、手順 3 で取得した値を貼り付けます（**空欄のままにしないこと**）。手動で設定／再接続する場合は次のとおりです。
   ```bash
   # 新規リモート作成
   rclone config
   # n → name: gdrive → storage: drive
   # client_id>   <自分の Client ID>
   # client_secret> <自分の Client secret>
   # scope> 1 (full drive) → ブラウザで OAuth 認証

   # トークン失効 / 週次の invalid_grant 時（OAuth アプリ公開後に実施）:
   backup reconnect
   backup about          # 疎通確認

   # 既存リモートが共有 client_id のままの場合:
   backup reconnect
   ```
   `backup setup` および `backup reconnect` を実行すると一時設定ファイル上で対話認証し、`secrets import-rclone` を自動実行して **`secrets/rclone-conf.age` を直接更新**します（`~/.config/rclone/rclone.conf` は生成しません）。その後 `git add secrets/rclone-conf.age && rebuild` を実行すると `/run/agenix/rclone-conf` へ反映されます（緊急リカバリ用に Bitwarden `restic-home` のメモ欄に OAuth 情報を控えておくことも任意で可能です）。

   手動で agenix 連携の初回セットアップを行う場合は次のとおりです。
   ```bash
   secrets init
   secrets import-restic
   secrets import-rclone /path/to/tmp-rclone.conf
   git add secrets/ && rebuild
   backup run
   backup log
   ```

### OS ビルド前に実機へ復元

既存バックアップを実機の NixOS（日本語 LXQt 初期環境など）へ戻すときは、`mitac` ユーザー（`sudo` を付けず）でこのリポジトリから次を実行します。OS の再ビルド前でも実行できます。

```bash
# 同一端末の復元（ホスト名に応じた rclone:gdrive:restic/<host>-home を自動選択）:
./scripts/restore-on-nixos.sh

# 別端末のバックアップから新端末・再初期化後の環境へクリーン復元する場合:
./scripts/restore-on-nixos.sh --from vaio --new-device
# （旧単一リポジトリ mitac-home や Chromebook 側から戻す場合は --from mitac / --from chromebook）

# 中身の事前確認や別ディスクへの取り出しのみ行う場合（親は作成済み・展開先自体は未作成）:
./scripts/restore-on-nixos.sh --from vaio --new-device /mnt/restore-disk/mitac-restored
```

不足するツール（`restic` / `rclone` / `jq` / `python3` / `rbw`、`pinentry` 未導入時は GUI で `pinentry-qt`・非 GUI で `pinentry-curses`）は自動で `nix shell` から取得します。

`gdrive:` リモートまたは暗号化パスワードが未設定の場合は、対話確認（`[Y/n]`）のうえで **Bitwarden（`rbw`）からの自動取得**を行います（`RESTORE_NO_RBW=1` で `rbw` を使わず最初から手動入力にすることもできます）。

1. **Bitwarden（`rbw`）の自動構成・ログイン／ロック解除・同期**
   - `rbw` が未設定ならメールアドレス（`RBW_EMAIL`、既定 `mitac31709@gmail.com`）、公式 EU クラウドのエンドポイント（`home/programs.nix` と同一、`RBW_BASE_URL` 等で変更可）、および `pinentry`（GUI は `pinentry-qt`、非 GUI は `pinentry-curses`）を自動設定してから `rbw login && rbw unlock` と `rbw sync` を実行します（端末初回登録が必要な場合は回復メニューの `[r]` で `rbw register` → Personal API Key を入力可能）。
2. **`restic-home`（環境変数 `RBW_ITEM` で変更可）からの自動読込**
   - **暗号化パスワード**: パスワード欄を自動取得し、そのまま restic リポジトリの検証に使用します。
   - **Google Drive OAuth**: カスタムフィールド（優先）またはメモ欄（`key: value` / `key = value` 形式）から `client_id`・`client_secret`・`refresh_token`（または `token` JSON）を読み取ります。3 項目すべてが揃っていれば復元用 `rclone.conf`（権限 `0600`）を無操作で自動生成します。
3. **不足・失敗時の対話フォールバック**
   - Bitwarden 側に一部の項目しか無い場合は取得できた値を既定値（`[Enter で維持]`）として残りの項目だけ入力でき、`refresh_token` を空 Enter にすると対話式ブラウザ OAuth（`rclone config reconnect gdrive:`）へ進みます。
   - `rclone about gdrive:` の接続確認に失敗した場合は `[b]Bitwarden (rbw) を同期して再読込 / [r]値を手動入力 / [o]OAuth ブラウザ再接続 / [t]再試行 / [q]中止`、パスワード取得に失敗／不一致の場合は `[b]Bitwarden (rbw) を同期して再試行 / [m]パスワードを手動入力（非表示） / [q]中止` からそのままやり直せます。

固定値（リモート名 `gdrive`、`type = drive`、`scope = drive`、既定リポジトリ `rclone:gdrive:restic/<host>-home`）の入力は不要です。取得・入力した OAuth 設定は OS 再ビルド前の復元処理でそのまま再利用されます（`rebuild` 後は agenix `/run/agenix/rclone-conf` のみが使われるため、復旧後に平文ファイルが残った場合は削除してください）。

`RCLONE_CONFIG`（または既存の `~/.config/rclone/rclone.conf` / `~/.rclone.conf`）に有効な `gdrive:` がある場合や、`RESTIC_PASSWORD` / `RESTIC_PASSWORD_FILE` / `RESTIC_PASSWORD_COMMAND` が設定済みの場合はそちらを優先してプロンプトを省略します。復元には**元の暗号化パスワード**が必要です。新しい鍵の生成や `backup setup` は行わないでください。

メッセージ・プロンプトは日本語で表示されます（GUI 端末・LXQt・Hyprland 上での利用を想定。非 CJK TTY コンソールでは表示できない文字があります）。最新スナップショットを固定し、必要容量と空き容量を確認してから、`restic restore --verify` で検証後に次のとおり復元します（検証が失敗した場合は元のファイルを変更せず一時展開先を保持して終了します）。

- **既定（`EXTRACT_DIR` なし）**: `/home/mitac` と同一ファイルシステム上の一時領域（`/var/tmp` が同一 FS なら `/var/tmp/restore-mitac-XXXXXXXX`、`/home/mitac` が別パーティションまたは Btrfs 別サブボリュームなら `/home/mitac/.restore-mitac-XXXXXXXX`）で検証後、進捗を表示しながら**元の位置へ高速に反映**し、成功時に一時ディレクトリを削除します（`復元と検証が完了しました。` を表示）。
  - ホーム: `/home/mitac/`（`~/MySettings`・`/home/mitac/.local/share/fonts/hiragino-otf/` を含む。今回の実行中に Bitwarden 反映・手動入力・OAuth 再接続で新規取得／更新した `$RCLONE_CONFIG` は保持）
  - システム状態（空でないディレクトリのみ自動で `sudo` 実行）: `/var/lib/bluetooth`・`/var/lib/cloudflare-warp`（`root:root` 所有に変更し、稼働中のサービスを再起動）。※ Wi-Fi と Tailscale は `agenix` 一元管理のためシステム状態からは復元しません。
- **`--from HOST` / `--repo REPO`（リポジトリ指定）**: 別のホスト用リポジトリ（`rclone:gdrive:restic/<HOST>-home`）やローカルコピーしたリポジトリ URI を指定します。未指定時は環境変数 `RESTIC_REPOSITORY`、次に `RESTORE_HOST`／現在ホスト名に基づく `<host>-home`（`nixos` / `localhost` の場合は `mitac-home`）を使います。
- **`--new-device`（複数端末の同時運用・初期化後クリーン構築向け）**: 同一アカウント内の別端末や再インストール後の環境で衝突・競合が起きないよう、次の処理を行います：
  - **保持**: GNOME Keyring・個人データ・エディタ/IME 設定・ブラウザのブックマーク/ノート、および現在の **`~/MySettings`（既存チェックアウト・新規生成済み `hardware-configuration.nix`）**・**`rbw`（端末別 `device_id`）**・**`$RCLONE_CONFIG`**
  - **初期化（新端末で初回サインイン／agenix 再展開）**: `bluetooth` / `cloudflare-warp`（および旧スナップショットに残る `tailscale` / `nm-connections`）ステージ領域、UniClipboard・Lan Mouse 鍵・LocalSend・RQuickShare・Parsec 端末認証、Vivaldi Sync / Cookie / アカウント状態（`Bookmarks` 等は保持）、Cursor 認証/秘密情報/テレメトリ ID（`User/settings.json` 等は保持）、Codex / ChatGPT・Grok Bot・Discord・Steam・AGY/OpenCode インストール ID 等のトークン系ログイン状態、`SingletonLock`
- **引数 `[EXTRACT_DIR]` 指定時**: `/home`・`/etc`・`/var/lib` には一切触れず、`EXTRACT_DIR`（`home/mitac/`・`run/restic-backups-home/system/`・`.restored-snapshot-id`）へ展開と検証のみを行います（`--new-device` 併用時はそのステージ領域内で初期化済み状態を検査できます）。

バックアップ対象には `~/MySettings`（`.git` や未コミットの作業を含む）も含まれますが、再生成可能な大容量キャッシュ／ゲーム本体（Steam `common` 等）・agenix 管理済みシークレット・`/etc/shadow` は含まれません。ヒラギノ（`/home/mitac/.local/share/fonts/hiragino-otf`）が復元された場合は、直後の OS ビルドで `--impure`（`rebuild` 導入後は自動付与）を指定してください（未配置時の既定は Noto CJK）。使い方は `./scripts/restore-on-nixos.sh --help` でも確認できます。

### 復元・確認（適用済みの環境）

このモジュールはセットアップ、systemd ユニット、rclone 確認、および restic（agenix のパスフレーズ／rclone 設定を読み込み済み）をまとめて扱う `backup` CLI を導入します（`restic-home-setup` も `backup setup` のエイリアスとして利用できます）。

すべてのファイルを元の位置へ一括復元する場合は、**起動中のデスクトップアプリや常駐サービス（ActivityWatch / WhatPulse / Vivaldi / Cursor 等）との競合を避けるため**、次の **2 段階方式（`rebuild --restore`）** が推奨です：

```bash
# 同一ホストのバックアップを事前ステージング・検証し、次回再起動時に自動反映を予約
rebuild --restore

# 別端末のバックアップから新端末向けに予約（完了後にそのまま再起動するなら --reboot）
rebuild --restore --from vaio --new-device

# 予約状態の確認 / キャンセル
rebuild --restore-status
rebuild --restore-cancel
```

`rebuild --restore` は現行の `/home/mitac` に触れず一時領域へ展開・`--verify`・`--new-device` 初期化と agenix 鍵／ヒラギノフォントの先行配置を行い、`nixos-rebuild switch` 成功後に `/var/lib/mitac-restore/pending.json` を確定します。次回起動時に `mitac-restore-apply.service`（`Type=oneshot`）が `home-manager-mitac.service`・`greetd`・`bluetooth`・`cloudflare-warp` より先に数秒でステージを反映し、直後の `home-manager-mitac.service` がシンボリックリンクの整合も自動修復します（既存の agenix `/run/agenix/restic-home-password`・`/run/agenix/rclone-conf` がある環境では `rbw` 解錠も不要です）。

初回 OS ビルド前や即時上書きを行いたい場合は引き続き `cd ~/MySettings && ./scripts/restore-on-nixos.sh`（別端末からは `--from <host> --new-device`）を使えます。一部ファイルだけ別ディレクトリへ取り出して確認・手動反映する場合は `backup restore latest --target /tmp/restore` を使います。他ホストのリポジトリを `backup` CLI から確認したい場合は `RESTIC_REPOSITORY=rclone:gdrive:restic/chromebook-home backup snapshots` のように環境変数で指定できます。

```bash
backup                 # 使い方
backup setup
backup run && backup log
backup snapshots
backup restore latest --target /tmp/restore
```

`--target /tmp/restore` で抽出した場合、非シークレットのシステム状態は `/tmp/restore/run/restic-backups-home/system/` 配下に展開されます（Wi-Fi と Tailscale は `agenix` + `rebuild` で自動展開されます）。

```bash
# Bluetooth ペアリング情報
sudo cp -a /tmp/restore/run/restic-backups-home/system/bluetooth/. \
  /var/lib/bluetooth/
sudo chown -R root:root /var/lib/bluetooth
sudo systemctl restart bluetooth

# Cloudflare WARP デバイス登録情報
sudo cp -a /tmp/restore/run/restic-backups-home/system/cloudflare-warp/. \
  /var/lib/cloudflare-warp/
sudo chown -R root:root /var/lib/cloudflare-warp
sudo systemctl restart cloudflare-warp 2>/dev/null || true
```

Google Drive からの復元でレート制限にかかる場合は、先にリポジトリをローカルへコピーしてからディスクから復元します。

```bash
rclone copy gdrive:restic/chromebook-home /var/tmp/restic-chromebook-home \
  --fast-list --transfers 4 --checkers 8 --tpslimit 8 --drive-chunk-size 64M
./scripts/restore-on-nixos.sh --repo /var/tmp/restic-chromebook-home --new-device
# または部分抽出:
restic restore latest \
  --repo /var/tmp/restic-chromebook-home \
  --password-file /run/agenix/restic-home-password \
  --target /tmp/restore
```

### 注意事項

- **`agenix` 一元管理**: `restic-backups-home.timer` および `backup` コマンドは `/run/agenix/restic-home-password`・`/run/agenix/rclone-conf` のみを使って動作するため、`rbw` のアンロック状態や `~/.config/rclone/rclone.conf` の平文コピーを一切必要としません（`/etc/agenix/master.key` 未配置時のみ `secrets bootstrap && rebuild` を実行してください）。
- root のみ読める非シークレット領域（Bluetooth、Cloudflare WARP）は root 権限の `ExecStartPre` で `/run/restic-backups-home/system/…` へ一時コピーされ、停止時に削除されます（Wi-Fi プロファイル・Tailscale 鍵・各種 API/SSH/gh/ADB/WOL 秘密情報は `agenix` 管理のため restic バックアップから除外済み）。`/etc/shadow`（ログインパスワード）は**バックアップされません**。`~/MySettings`（`.git` や未コミットの作業を含む flake チェックアウト一式）は `/home/mitac` の他のファイルと**一緒に含まれ**、同一端末向けの `./scripts/restore-on-nixos.sh` では `~/MySettings` へそのまま上書き復元されますが、`--new-device` 指定時かつ既存の `~/MySettings`（`.git` または `hosts/`）がある場合はそちら（新規生成した `hardware-configuration.nix` 等）を保持して上書きしません（`backup restore … --target /tmp/restore` 時は `/tmp/restore/home/mitac/MySettings`）。
- 再生成可能な大容量データは除外されます（Steam クライアント／ランタイムとゲーム本体 ※ `userdata` / `compatdata` のセーブデータは保持、Cursor の agent-worker バイナリとキャッシュ、Vivaldi のキャッシュ／WebStorage、Firefox の `storage`）。Vivaldi の `Default/Extensions` は Preferences のインストール記録と対になるため**含めます**（除外すると復元後に拡張が壊れる）。
- `/home` **全体**（複数ユーザー）をバックアップしたい場合は、サービスの実行ユーザーを `root` に変更し、`agenix` の秘密ファイル所有者を確認してください。
- OAuth トークンや SSH/gh 秘密鍵などのシークレットは平文でホームやリポジトリに残さず、`secrets/*.age`（agenix）で一元管理します（リポジトリ内には暗号化済み `.age` のみをコミット）。

## Neovim 設定

[LazyVim](https://github.com/LazyVim/LazyVim) スターター構成（NixOS 向けに調整）。

| パス | 役割 |
|------|------|
| `home/nvim/init.lua` | `config.lazy` の読み込み |
| `home/nvim/lua/config/` | options / keymaps / autocmds / lazy セットアップ |
| `home/nvim/lua/plugins/` | 追加・上書き用のプラグイン仕様（`nix.lua` で Mason 無効化） |

- **lazy.nvim** と LazyVim のコアプラグインは `pkgs.vimPlugins` を `linkFarm` したディレクトリ（`home/lazy-plugins.nix`）。lazy の `dev.path` がそこを見る。`dev.fallback` はオフ、`install.missing` もオフなので、起動時に git clone しない
- バージョンは nixpkgs のピン（`flake.lock`）で決まる。`lazy-lock.json` はローカルプラグインを記録しない。パスは読み取り専用の `~/.config/nvim` を避けて `~/.local/state/nvim/lazy-lock.json` のまま
- treesitter のパーサは `nvim-treesitter.withPlugins` の `parser/*.so` を `install_dir`（`~/.local/share/nvim/nix/treesitter`）に置く。LazyVim はそこにある言語を `TS.install` しない。言語を足すときは `home/lazy-plugins.nix` のリストを変える
- LSP / formatter は Mason ではなく `programs.neovim.extraPackages`（`lua-language-server`、`stylua`、`ripgrep`、`fd`）。Mason は無効のまま

## VAIO（Intel 第8世代以降）

| 項目 | 詳細 |
|------|------|
| Flake ターゲット | `.#vaio`（`hosts/vaio/default.nix`。ホスト名 `vaio` / バックアップ先 `vaio-home`） |
| CPU / GPU | Intel 第8世代以降（Core i / Core Ultra iGPU）。`intel-media-driver` + `LIBVA_DRIVER_NAME=iHD` + `sof-firmware`（`modules/nixos/laptop/graphics.nix`） |
| オーディオ | **PipeWire + WirePlumber**（ALSA / 32bit ALSA / `pipewire-pulse` / JACK 互換）+ Bluetooth（`modules/nixos/vaio/audio.nix`）。Chromebook 用の PulseAudio / `hw:0,0` 固定・`max98373` ミキサは不使用 |
| キーボード・OOM | `keyd` により **Ctrl+Alt+Del**（**Ctrl+Alt+Backspace** も可）で手動 OOM killer（SysRq-f）＋ libinput 内部キーボード扱い。Chromebook 用 `cros` 最上段変換は適用しないため、`F1`–`F12` は通常のファンクションキーとして動作（`modules/nixos/laptop/input.nix`） |
| 電源・コード | `zram`（100% / zstd）・`thermald`・`auto-cpufreq`・`power-chords`（全 `"Power Button"` ACPI ノードを監視: 短押し=suspend / 長押し≈2.5s=poweroff / **電源+F1=強制ログアウト** / **電源+F2=再起動**）。Ice Lake eDP は `i915.enable_psr=0` `i915.enable_dc=0`（flip 張り付き＝偽 iowait 回避）。Chromebook 専用 `/dev/cros_ec` Type-C 制御はロードしない |
| バックライト | Waybar `backlight` はデバイス名固定なし（`intel_backlight` 等を自動検出） |
| 指紋認証 | ELAN `04f3:0c46` 対応パッチ適用済み `libfprint` + `fprintd`（`modules/nixos/vaio/fingerprint.nix`）。`sudo`（PAM）および `hyprlock`（D-Bus 併用）で利用可。`greetd`/`login`（`gnome-keyring` 自動解錠維持）と Polkit（`cmd-polkit` 非対応）はパスワード認証を維持。登録は `fprintd-enroll`（小型センサーのためタッチ／ゆっくりスワイプ） |

### VAIO オーディオ確認

```bash
pactl info | grep 'Server Name'
# "Server Name: PulseAudio (on PipeWire ...)" を期待

pactl list short sinks
# スピーカー／HDMI／Bluetooth シンクが見えること

# 緊急停止（ミュート + PipeWire / WirePlumber 再起動）:
audio-panic
```

## Chromebook — ASUS CX5500FE / delbin

| 項目 | 詳細 |
|------|------|
| Flake ターゲット | `.#chromebook`（`hosts/chromebook/default.nix`。後方互換エイリアス `.#mitac` も同一。ホスト名 `chromebook` / バックアップ先 `chromebook-home`） |
| ボード | `delbin`（`DELBIN_XHVI`） |
| プラットフォーム | `volteer`（Intel Tiger Lake） |
| GPU | Iris Xe（i3-1115G4）。`intel-media-driver` + `LIBVA_DRIVER_NAME=iHD`（`modules/nixos/laptop/graphics.nix`） |
| オーディオ | SOF + `sof-rt5682` / `max98373`（`alsa-ucm-conf-cros` + `sof-firmware`） |
| キーボード | [cros-keyboard-map](https://github.com/WeirdTreeThing/cros-keyboard-map) 相当の `keyd`（delbin physmap）。最上段は ChromeOS キー。**Search+最上段**で F1–F10。**Ctrl+Alt+Del**（内蔵は **Ctrl+Alt+Backspace**）で手動 OOM killer。電源コード: 短押し=suspend / 長押し≈2.5s=poweroff / **電源+Back=強制ログアウト** / **電源+Refresh=再起動**（`power-chords`） |
| Flip | タブレットモード向け libinput quirk `ModelTabletModeNoSuspend=1` |
| USB-C 電力 | `chromebook-typec-prefer-sink`: 空きポートは FORCE_SINK（壁充電器／モババッ受電）、スマホ(UFP)→ source、AC給電中の他ポート→ source。udev は partner 追加時のみ（typec CHANGE はループ防止で除外） |
| ストレージ / Btrfs | 既定の `hardware-configuration.nix` は `ext4`。`btrfs`（`compress=zstd:1`）へ切り替える場合は「[Chromebook を btrfs 透過圧縮でクリーン再インストール](#chromebook-を-btrfs-透過圧縮でクリーン再インストール)」を参照 |

### Chromebook オーディオ確認

```bash
aplay -l
# sof-rt5682 / SOF 関連のカード名のような表示を期待

pactl list short sinks
pactl info | grep 'Default Sink'
# speaker がデフォルトシンクであること
```

SOF（Tiger Lake）では PipeWire の ALSA バックエンドが `Broken pipe` になり、スピーカーが最後の音をループし続ける既知不具合があります（WeirdTreeThing/chromebook-linux-audio#2）。

対策:

- **音声は PulseAudio**（PipeWire はデスクトップ用のみ）。設定は `modules/nixos/chromebook/audio.nix`
- sof-rt5682 は UCM Mic/DMIC 探索で `module-alsa-card` が落ちるため、**`hw:0,0`（Speaker）/ `hw:0,1`（Headset mic）を直接**バインド（`module-udev-detect` は無効）
- `chromebook-alsactl-init` / レジュームに `ALSA_CONFIG_UCM2`（cros マージ + `sofrt5682` エイリアス）を明示。これがないと `alsactl init` が毎回 -2 になる
- 起動／レジューム時に `alsactl init` + `chromebook-speaker-levels apply`（max98373 Digital/Spk）
- 緊急停止: `audio-panic`（`chromebook-speaker-levels mute`）

```bash
pactl list short sinks   # speaker が見えること
speaker-test -c 2 -t wav -l 1
```

dmesg の `DMIC16kHz` IPC `-22` は NHLT に DMIC が無い場合の既知ノイズで、スピーカー不具合とは別件です。

### Chromebook キーボード確認

最上段キーは Back / Forward / Refresh / Fullscreen / Brightness / Volume として動作するはずです（単なる F1–F10 ではありません）。

## VA-API / Parsec 確認（Chromebook / VAIO 共通）

```bash
vainfo
# iHD ドライバと H.264 の EncSlice / VLD が出ることを期待
```

Parsec を開き直してハードウェアエンコーダーが選べるか確認します。

### Parsec over Tailscale（ホテル等で -6023 のとき）

Parsec は Tailscale の `100.64/10` を LAN とみなさないことが多い。ホスト（Windows / `galleria-mitac` = `100.102.102.53`）側で接続先 IP を強制する。

**1. ホスト（一度だけ）** — Parsec を完全終了し、`%AppData%\Parsec\config.txt` に次を追加してから再起動（自動で `config.json` へ移行される）:

```text
app_custom_address = 100.102.102.53
```

**2. クライアント（このマシン）**

```bash
parsec-ts                 # WARP 切断 → galleria-mitac へ ping → Parsec 起動
# またはホスト名指定: parsec-ts galleria-mitac
```

外出先で自宅 LAN（`192.168.1.0/24`）そのものへも行きたいときだけ:

```bash
ts-home-routes on         # galleria が広告するサブネットを受け取る
# …作業…
ts-home-routes off        # 帰宅後は必ず off（オンのまま自宅 Wi-Fi に繋がると LAN が壊れる）
```

常時 `--accept-routes` は入れない（自宅で同じ `192.168.1.0/24` を受けて Wi-Fi が死ぬため）。

## 構成

```
flake.nix
lib/machine.nix                   # 作業コピー・フォールバックホスト・ヒラギノパス設定
lib/lan-mouse.nix                 # Lan Mouse 公開指紋・端末間クライアント配置（vaio → chromebook）
lib/theme.nix                     # Nocturne Slate 統一デザインシステム（配色・フォント・角丸・決定論的壁紙生成）
secrets/                          # agenix 暗号化ファイル（*.age）、公開鍵（*.pub / master-pubkey.txt）、agenix-rules.nix
hosts/chromebook/                 # delbin Chromebook エントリ + hardware-configuration.nix
hosts/vaio/                       # VAIO エントリ + hardware-configuration.nix（要実機生成）
modules/nixos/common.nix          # locale、ユーザー、Meltype/Fcitx5、フォント
modules/nixos/secrets.nix         # agenix 複号設定、nm-agenix-profiles、Tailscale authKeyFile
modules/nixos/remote-builder.nix  # wsl-builder リモートビルダー設定（agenix 経由）
modules/nixos/desktop.nix         # hyprland + greetd + console-gui + portals + XKB/印刷
modules/nixos/hyprland.nix        # Hyprland (UWSM) システム側（セッション変数・hyprlock・greetd 既定セッション等）
modules/nixos/greetd.nix          # ReGreet + 受信専用 Lan Mouse（最小 Hyprland 上）
modules/nixos/console-gui.nix     # gui / apps（cage 単一アプリ起動・CLI ランチャー等）
modules/nixos/laptop.nix          # ノート PC 共通ハードウェア集約（./laptop/*）
modules/nixos/laptop/             # graphics（Intel iHD + SOF + i915.enable_psr=0/dc=0）/ input（keyd OOM）/ power（zram + thermald + auto-cpufreq + power-chords）
modules/nixos/vaio.nix            # VAIO 固有集約（./vaio/*）
modules/nixos/vaio/               # audio（PipeWire + WirePlumber + Bluetooth）/ fingerprint（ELAN 04f3:0c46 用 libfprint パッチ + fprintd）/ power
modules/nixos/chromebook.nix      # delbin Chromebook 固有集約（./chromebook/*）
modules/nixos/chromebook/         # audio（PulseAudio + UCM）/ power（Type-C EC）/ input（cros keyd + Flip）
modules/nixos/backup.nix          # 暗号化 /home → Google Drive バックアップ（agenix / restic / rclone）
modules/nixos/release.nix         # system.nixos.tags（世代ラベルのスラッグ）
home/mitac.nix                    # HM エントリ（identity + imports）
home/local-llm.nix                # llama.cpp + Qwen3.5-4B オンデマンド管理（local-llm / WebUI）
home/hermes.nix                   # Hermes Agent CLI + ACP（flake 入力 hermes-agent）
home/secrets.nix                  # agenix ユーザーシークレット連携（~/.ssh / ~/.config/gh / user-env）
home/flake-tools.nix              # repoPath / flakeHost / scripts（secrets・flake-update・waybar 等）
home/shell.nix                    # bash エイリアス / rebuild / audio-panic / runbtop
home/programs.nix                 # git / rbw / neovim / rofi / ghostty / mime / 共通パッケージ（T3 Code 含む）
home/startup-sound.nix            # ランダム起動音（startup-sound.service / Waybar トレイ管理 / プリセット・同梱音源）
home/startup-sounds/              # 起動音の宣言的ローカル追加置き場（ブルアカ・マリオカート8 等、README 参照）
home/capsomnia.nix                # Capsomnia ユーザー常駐デーモン（capsomniad.service）
home/lazy-plugins.nix             # nixpkgs 由来 LazyVim プラグイン + treesitter パーサ
home/clipboard.nix                # cliphist + clipboard-history
home/hyprland.nix                 # Hyprland Lua 設定（waybar/mako/hyprpaper/hyprlock/hypridle・polkit・チートシート）
home/nvim/
scripts/local-llm.py              # local-llm CLI / オンデマンド llama-server マネージャ・T3 Code ACP
scripts/secrets-tool.sh           # secrets CLI（init / bootstrap / import / edit / rekey / check）
scripts/restore-on-nixos.sh       # 実機復元（--from / --new-device / --agenix-only）
```
