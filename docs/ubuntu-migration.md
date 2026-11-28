# ubuntu サーバーの NixOS 移行手順

GMKtec NucBox G3（Intel N100 / 16GB RAM / Apacer 256GB NVMe）で動いている Ubuntu 24.04 サーバーを、この flake の `.#ubuntu`（NixOS + disko + btrfs）へ安全に入れ替えるための手順です。

**最初に必ずフルディスクバックアップを取り、戻せる状態を確保してから進めてください。**

---

## 0. 移行前の前提と確認事項

- 対象機: GMKtec NucBox G3（UEFI、内蔵 NVMe 1 本 `/dev/nvme0n1`、実容量 238.5 GiB）
- 現在のディスク構成（Ubuntu 24.04）:
  - `nvme0n1p1`: 1 GiB vfat（`/boot/efi`、使用約 6 MiB）
  - `nvme0n1p2`: 2 GiB ext4（`/boot`、使用約 202 MiB）
  - `nvme0n1p3`: 235.4 GiB LVM（PV・LV ともに 235.4 GiB いっぱい、`ubuntu-vg/ubuntu-lv`、使用約 75 GiB / 空き 147 GiB）
  - スワップ: `/swapfile` 8 GiB（使用中）+ `/swap.img` 4 GiB（未使用）
- 新しいディスク構成（`hosts/ubuntu/disko.nix`）:
  - GPT、1 GiB vfat ESP（`/boot`）、残りを btrfs（`compress=zstd:1`、`@` / `@home` / `@nix` / `@log` / `@swap` 4 GiB swapfile）
- ネットワーク:
  - 有線 LAN `enp3s0`（MAC `e0:51:d8:1e:90:95`）
  - ルーターの DHCP 予約で `192.168.1.50` が割り当てられる前提
  - ルーター転送ポート: TCP `22`, `443`, `25565` / UDP `500`, `4500`, `1194`
  - Tailscale アドレス: `100.124.196.22` / `fd7a:115c:a1e0::f101:c484`（SSH の `Match LocalAddress` もこのアドレスを前提にしています）
- 現行 Ubuntu からの意図的な変更・廃止:
  - **`nfas26.service`（ユーザー unit、`workerd` 0.0.0.0:8787 + Tailscale Serve `:8443`）と `code-server@mitac.service`（0.0.0.0:8080）は、現在も実機で enabled / active ですが、移行方針どおり意図的に廃止しています。** 移行当日に実機側で停止し、必要ならデータ（`~/NFAS26`・`~/.config/code-server`）を念のため退避してから切り替えてください。
  - `cloudflared`・Node 18・`snapd`・`cloud-init`・`open-vm-tools` も意図的に除外しています。
  - タイムゾーンは現行の `Etc/UTC` から `Asia/Tokyo` へ変更しています。
  - `services.tailscale.useRoutingFeatures = "server"` により IPv4 に加えて IPv6 転送も有効になります（現行 Ubuntu は IPv4 のみ転送）。
- 移行前に残っている `TODO`（秘密・任意項目のみ）:
  - `/etc/win-credentials` の agenix 暗号化（`secrets/ubuntu-win-credentials.age`）
  - ユニット外の秘密ファイル（`~/.hermes/.env`・`auth.json`、`~/siesta-bot/.env`、`~/.config/lecture-asr/gemini.env` 等）は退避から復元するか agenix へ移行
  - （任意）NVMe を増設する予定があれば `hosts/ubuntu/disko.nix` の `/dev/nvme0n1` を `/dev/disk/by-id/...` に固定
  - 公開鍵 4 本（`pi-lecture-upload` の `rrsync` 制限含む）、`hermes-gateway` / `siesta-bot` / `lecture-asr` / `lecture-publish` の実ユニット値、Minecraft 6 インスタンスの起動コマンドは `modules/nixos/ubuntu.nix` へ実測値を反映済み

---

## 1. フルディスクバックアップ（Clonezilla Live USB → Google Drive）

ファイル単位の退避とは別に、**元の Ubuntu へ丸ごと戻せるディスクイメージ**を先に作ります（ロールバックの本命）。
使用量が約 75 GiB あるため、zstd 圧縮後のイメージは **45〜70 GiB** 程度になります。Google Drive に 2 TB 以上の空きがあるため、Clonezilla Live の中で `rclone` を使って Google Drive へ直接保存できます。

### 1-1. 準備するもの

- USB メモリ（Clonezilla Live amd64 / UEFI 版を書き込んだもの）
- キーボード・モニター（NucBox G3 に直接つなぐ）
- 既存の `rclone.conf`（`gdrive` リモート設定済みのファイル。USB メモリ等に一時コピーするか、Live 内で `rclone config` で新規認証する）
- （任意）整合性を上げるため、シャットダウン前に現行 Ubuntu で常駐サービスを止めておくと安心です:
  ```bash
  sudo systemctl stop vpnserver docker code-server@mitac
  systemctl --user stop nfas26 hermes-gateway siesta-bot
  ```

### 1-2. Clonezilla Live の起動と rclone の用意

1. NucBox G3 に Clonezilla Live USB を挿し、UEFI メニューから USB 起動します（Secure Boot は無効）。
2. 起動後、言語・キーマップを選び、**「Enter_shell（コマンドラインへ入る）」** を選択します（先に Google Drive をマウントしてから Clonezilla のメニューを起動するためです）。
3. ネットワークがつながっているか確認します:
   ```bash
   ip -4 addr
   ping -c 2 1.1.1.1
   ```
4. Live 環境で `rclone` が使えるか確認し、無ければ一時導入します:
   ```bash
   sudo -i
   which rclone || (apt-get update && apt-get install -y rclone fuse3)
   ```
5. `rclone` に Google Drive（リモート名 `gdrive`）を設定します:
   - **手元の `rclone.conf` を持ち込む場合**: 別の USB メモリなどから `/root/.config/rclone/rclone.conf` にコピーします（権限 `chmod 600`）。
   - **Live 内で新しく認証する場合**: `rclone config` を実行し、`n` → 名前 `gdrive` → ストレージ `drive` を選びます。Live 環境にブラウザが無いので `Use web browser to automatically authenticate?` には `n` を選び、手元の PC で `rclone authorize "drive"` を実行して出たトークンを貼り付けます。
6. 疎通を確認します:
   ```bash
   rclone about gdrive:
   ```

### 1-3. Google Drive を `/home/partimag` にマウントしてイメージ取得

Clonezilla は `/home/partimag` を保存先として使います。`rclone mount` で Google Drive の専用フォルダをそこへつなぎます。

```bash
mkdir -p /home/partimag /tmp/rclone-cache
rclone mkdir gdrive:backups/ubuntu-clonezilla

# 書き込みキャッシュ付きでマウント（バックグラウンド起動）
rclone mount gdrive:backups/ubuntu-clonezilla /home/partimag \
  --vfs-cache-mode writes \
  --cache-dir /tmp/rclone-cache \
  --vfs-write-back 5s \
  --daemon

# マウントできているか確認
df -h /home/partimag
```

> **注意（メモリ / 一時領域）**: Live USB の `/tmp` は RAM（16 GB の半分程度）です。45〜70 GB のイメージ全体がキャッシュに溜まると RAM が溢れるため、Clonezilla の分割サイズ（`-s` / split size）は既定の **4096 MB（4 GB）以下**（例: `2048 MB`）にし、空き容量のある外付け SSD / USB HDD を一時保存先にしてから `rclone copy` で Google Drive へ送る方法がいちばん安全です。
>
> 外付けドライブを使う場合は、Clonezilla で普通に外付けドライブ（`/home/partimag`）へ保存したあと、次でアップロードします:
> ```bash
> rclone copy -P /home/partimag/ubuntu-2026-backup gdrive:backups/ubuntu-clonezilla/ubuntu-2026-backup
> ```

`/home/partimag` の準備ができたら、Clonezilla を起動します:

```bash
clonezilla
```

メニューでの選択:

1. **device-image**（ディスク／パーティション → イメージ）
2. **skip**（`/home/partimag` はすでにマウント済み）
3. **Expert mode** または **Beginner mode**
4. **savedisk**（ローカルディスク全体をイメージとして保存）
5. イメージ名を入力（例: `ubuntu-nvme-2026-11-28`）
6. 対象ディスクとして **`nvme0n1`**（Apacer 256GB）を選択（LVM の `ubuntu-vg/ubuntu-lv` も Clonezilla が自動で処理します）
7. 圧縮方式に **zstd**（`-z9p` または `-z1p` 並列 zstd）を選択
8. `rclone mount` 経由の場合は分割サイズを `2048` MB 程度に設定
9. イメージのチェック（**Check the saved image**）を「する」にして完了まで待つ

終了後、シェルに戻ってキャッシュの書き出しを待ち、アンマウントします:

```bash
sync
fusermount3 -u /home/partimag   # 書き出し中なら完了まで待つ
rclone ls gdrive:backups/ubuntu-clonezilla/ubuntu-nvme-2026-11-28
```

### 1-4. フルディスクイメージからの復元方法（元の Ubuntu へ戻すとき）

NixOS 移行をやり直したい・元の Ubuntu に戻したいときの手順です。

1. 同じ Clonezilla Live USB から UEFI 起動し、シェルに入ります。
2. 1-2 と同じ手順でネットワークと `rclone`（`gdrive`）を設定します。
3. Google Drive のイメージフォルダを `/home/partimag` にマウントします（読み込み専用なので `--vfs-cache-mode minimal` で十分です）:
   ```bash
   mkdir -p /home/partimag
   rclone mount gdrive:backups/ubuntu-clonezilla /home/partimag \
     --vfs-cache-mode minimal \
     --read-only \
     --daemon
   ```
   （外付けドライブに控えがある場合は、そちらを `/home/partimag` にマウントする方が高速です。）
4. `clonezilla` を起動し、次を選びます:
   - **device-image** → **skip**（`/home/partimag` 使用済み）
   - **restoredisk**（イメージをディスク全体へ復元）
   - イメージ `ubuntu-nvme-2026-11-28` を選択
   - 復元先ディスクとして **`nvme0n1`** を選択
5. 確認画面で `y` を入力して復元を実行します。完了したらアンマウントして USB を抜き、再起動します。
6. 起動後、LAN（`192.168.1.50`）、SSH、Tailscale、SoftEther が元どおり動くことを確認します。

### 1-5. 補足: 再起動せず取るライブ（ファイル単位）バックアップ

Clonezilla 用の物理アクセスを取る前に、**起動したまま二重の保険としてデータと設定を Google Drive へ逃がしたい場合**の補足手順です。

> **重要**: **元の Ubuntu へ丸ごと戻すロールバックの本命は、あくまで 1-1〜1-4 の Clonezilla オフラインイメージです。**
> 現行の LVM は PV・LV ともに 235.4 GiB いっぱいで VG にスナップショット用の空き PE が無いため LVM スナップショットは使えず、稼働中の ext4 を `dd` / `partclone` するとジャーナル不整合の危険があります。またファイル単位からのベアメタル復元はパーティション・EFI・LVM・GRUB・fstab の手作業再構築が必要で手間が大きいため、ライブバックアップは **ホーム・Docker・SoftEther 設定などのデータ保険** として位置付けてください。

前提と目安:

- 現行 `ubuntu` には `rsync`・`dd`・`zstd` は入っていますが、**`rclone` / `restic` / `borg` / `partclone` は未導入** です（`sudo` はパスワード必須）。`rclone` を導入するか、`rclone` 設定済みの別マシン（VAIO / Chromebook 等）経由で Google Drive へ送ります。
- 対象約 75 GiB + `/boot` 202 MiB + EFI 6 MiB → 圧縮後 **45〜65 GiB** 程度。初回アップロードは回線次第で **3〜8 時間** が目安です。`ubuntu` 自身の空き 147 GiB は一時置きにしか使えません（同じ NVMe 故障時に消えるため）。

コマンド例（`ubuntu` 上で実行）:

```bash
# 1. ディスク構成メタデータ（小さいので必ず取る）
sudo sfdisk --dump /dev/nvme0n1 > ubuntu-nvme0n1.sfdisk
sudo dd if=/dev/nvme0n1p1 bs=4M status=progress | zstd -T0 -10 -o ubuntu-efi.img.zst
sudo tar -C /boot -cpf - . | zstd -T0 -10 -o ubuntu-boot.tar.zst
sudo vgcfgbackup -f ubuntu-vg.cfg ubuntu-vg

# 2. 整合性のため短時間サービスを止める
sudo systemctl stop vpnserver
# 可能なら Docker も止める（止めずに取る場合は named volume を別途 docker run --rm -v ... tar）
sudo systemctl stop docker

# 3a. restic + rclone を入れて Google Drive へ直接送る例
# restic -r rclone:gdrive:restic/ubuntu-live --verbose backup \
#   --one-file-system / /boot /boot/efi \
#   --exclude /tmp --exclude /var/tmp --exclude /var/cache \
#   --exclude /swapfile --exclude /swap.img

# 3b. rclone 未導入のままアーカイブを作り、別ディスクや rclone 済み端末へ送る例
sudo tar --acls --xattrs --numeric-owner --one-file-system \
  --exclude=/tmp --exclude=/var/tmp --exclude=/var/cache \
  --exclude=/swapfile --exclude=/swap.img \
  -cpf - / | zstd -T0 -10 > /path/on-other-disk/ubuntu-root.tar.zst

# 4. サービスを再開
sudo systemctl start docker vpnserver
```

---

## 2. 個別に退避するデータ（NixOS 移行後に戻す分）

フルディスクイメージとは別に、NixOS インストール後にすぐ戻せるよう、以下のファイル群を別の安全な場所（手元の PC、外付けドライブ、または Google Drive の暗号化アーカイブ）へコピーしておきます。

**秘密鍵・トークン・パスワードを含むため、平文のまま共有領域へ置かないでください。**

### 2-1. 退避リスト

| 項目 | 現行 Ubuntu 上のパス / コマンド | 権限・備考 |
|---|---|---|
| ホーム全体 | `/home/mitac/` | `.hermes`（3.3G）、`siesta-bot`、`lectures`（モデル 1.5G 含む）、`minecraft`（6 インスタンス: `ATM10` / `ATM9-Eureka` / `latest-vanila` / `mohist-1.20.1` / `paper-1.21.11` / `yower-1.21.1`）、`znc`、`ntopng`、`FindSenryu4Discord`、`slowflow-vpn`、`bin/`、`.ssh/`、`.gnupg/`、`.config/gh/`、`.config/lecture-asr/`、`.config/btop/`、`.config/systemd/user/` などを含む |
| 停止中アプリのデータ（退避のみ） | `~/immich-app`（+ volume `immich_model-cache` 5.6G）、`~/AdGuardHome`、`~/kikoune`、`~/CloudflareOS`、`~/DiscordShogi` | NixOS 側には設定を作らずデータだけ保持 |
| 廃止予定アプリのデータ（任意） | `~/NFAS26`、`~/.config/code-server` | 意図的に廃止する対象。念のため残したい場合のみ退避（`/home/mitac` 丸ごとコピーなら自動的に含まれる） |
| SoftEther 設定・証明書 | `/usr/local/vpnserver/vpn_server.config` と同フォルダ内の証明書・`chain_certs` 等 | root 所有。`sudo` が必要 |
| SSH ホスト鍵 | `/etc/ssh/ssh_host_*` | 再インストール後も他端末から `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` を出さないため。root 所有 |
| Tailscale 状態 | `/var/lib/tailscale/` | ノード ID と `100.124.196.22` / `fd7a:115c:a1e0::f101:c484` を維持するため（SSH の `Match LocalAddress` にも必要）。root 所有 |
| Docker ボリューム | `/var/lib/docker/volumes/`（`immich_model-cache` や各 compose の named volume） | bind mount 分は `/home/mitac` に含まれる。named volume は `docker volume ls` で確認し、Docker 停止中にコピーまたは `tar` で抜く |
| ローカルビルドの Docker イメージ | `docker save findsenryu4discord-app`（その他 `docker images` でローカルビルド扱いがあれば同様） | `/var/lib/docker/volumes/` には含まれないため、そのまま戻す場合は `docker save` で退避する（または移行後に `docker compose build` で再ビルド） |
| 各種 `.env`・認証ファイル | `~/.hermes/.env`、`~/.hermes/auth.json`、`~/siesta-bot/.env`、`~/.config/lecture-asr/gemini.env`、`~/slowflow-vpn/psk`、各 compose の `.env` | `/home/mitac` に含まれるが、漏れがないか個別確認する |
| CIFS 資格情報 | `/etc/win-credentials` | root 所有（0600）。NixOS では agenix（`secrets/ubuntu-win-credentials.age`）へ暗号化して管理する |

### 2-2. 退避コマンドの例（現行 Ubuntu 上で実行）

移行前に現行のユニット定義と Minecraft 起動スクリプトも必ず控えておき、`modules/nixos/ubuntu.nix` の `TODO` を埋める材料にします:

```bash
# ユーザー systemd ユニットの確認（TODO 解消用）
head -n 100 ~/.config/systemd/user/*.service ~/.config/systemd/user/*.path ~/.config/systemd/user/*.timer

# Minecraft 6 インスタンスの起動スクリプト確認
ls -la ~/minecraft/{ATM10,ATM9-Eureka,latest-vanila,mohist-1.20.1,paper-1.21.11,yower-1.21.1}

# Docker コンテナ・イメージ・ボリューム一覧の記録
docker ps -a
docker images
docker volume ls

# ローカルビルドの Docker イメージ保存（FindSenryu4Discord）
mkdir -p /tmp/ubuntu-docker-images
docker save findsenryu4discord-app | zstd -T0 -10 -o /tmp/ubuntu-docker-images/findsenryu4discord-app.tar.zst

# root 領域のまとめ退避（一時的に /tmp/ubuntu-sys-backup へ集めて転送する例）
sudo mkdir -p /tmp/ubuntu-sys-backup/{softether,ssh,tailscale,cifs,docker-volumes}
sudo cp -a /usr/local/vpnserver/vpn_server.config /tmp/ubuntu-sys-backup/softether/
sudo cp -a /usr/local/vpnserver/chain_certs /tmp/ubuntu-sys-backup/softether/ 2>/dev/null || true
sudo cp -a /etc/ssh/ssh_host_* /tmp/ubuntu-sys-backup/ssh/
sudo cp -a /var/lib/tailscale/. /tmp/ubuntu-sys-backup/tailscale/
sudo cp -a /etc/win-credentials /tmp/ubuntu-sys-backup/cifs/
# Docker named volume がある場合は Docker を止めてからコピー
# sudo systemctl stop docker
# sudo cp -a /var/lib/docker/volumes/. /tmp/ubuntu-sys-backup/docker-volumes/
```

退避した `/etc/win-credentials` の内容は、手元の NixOS マシンの `MySettings` で agenix に登録しておきます（平文を git に入れない）:

```bash
cd ~/MySettings
secrets edit ubuntu-win-credentials
# エディタで username=... / password=... を貼り付けて保存
git add secrets/ubuntu-win-credentials.age
```

---

## 3. `nixos-anywhere` で NixOS をインストールする

手元のマシン（Nix が使える Linux / NixOS）から、グローバル IP のポート 22 経由で `nixos-anywhere` を実行します。
**この操作で `/dev/nvme0n1` の全データが消去されます。** 手順 1 と 2 が終わっていることを必ず確認してから実行してください。

### 3-1. 事前に確認しておくリスク（重要）

`nixos-anywhere` は次の流れで動きます:

1. 今の Ubuntu に SSH 接続し、メモリ上で NixOS インストーラへ `kexec`（再起動なしで一時 OS へ切り替え）する
2. 一時インストーラが起動し、**もう一度 SSH でつなぎ直して** disko でディスク初期化 → NixOS 書き込み → 再起動する

ここで **いちばん大きなリスク** があります:

> **kexec 後のインストーラが DHCP で `192.168.1.50` を取り直せなかった場合、ルーターのポート 22 転送（グローバル IP → `192.168.1.50`）が届かなくなり、途中で接続不能になります。**

原因になりやすい点と対策:

- **DHCP Client-ID の違い**: ルーターの DHCP 予約が MAC アドレス（`e0:51:d8:1e:90:95`）を見ていれば基本的に `192.168.1.50` が降ってきますが、ルーターによっては kexec インストーラが送る DHCP Client-ID（DUID 等）が違うと別 IP を渡すことがあります。
- **対策**:
  - できれば **自宅 LAN 内から `192.168.1.50` へ直接実行** する方が安全です（別 IP になっても LAN 内で発見でき、ポート転送に依存しません）。
  - 外からグローバル IP 経由で実行する場合は、途中で止まったときに現地で電源リセット／Clonezilla 復元ができるタイミングで行ってください。
  - インストール後の NixOS 本体（`modules/nixos/ubuntu.nix`）では `MACAddress = "e0:51:d8:1e:90:95"` + `dhcpV4Config.ClientIdentifier = "mac"` を設定しているため、再起動後は MAC ベースの DHCP 予約と確実に一致します。

### 3-2. `--extra-files` で SSH ホスト鍵と agenix マスター鍵を同時配置（推奨）

再起動直後から SSH ホスト鍵（known_hosts 一致）と `/etc/agenix/master.key` を有効にするため、一時ディレクトリを用意して `--extra-files` で渡せます:

```bash
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

install -d -m 755 "$temp/etc/ssh"
# 退避しておいた ssh_host_* を配置（秘密鍵は 600、公開鍵は 644）
install -m 600 /path/to/backup/ssh/ssh_host_ed25519_key "$temp/etc/ssh/"
install -m 644 /path/to/backup/ssh/ssh_host_ed25519_key.pub "$temp/etc/ssh/"
install -m 600 /path/to/backup/ssh/ssh_host_ecdsa_key "$temp/etc/ssh/"
install -m 644 /path/to/backup/ssh/ssh_host_ecdsa_key.pub "$temp/etc/ssh/"
install -m 600 /path/to/backup/ssh/ssh_host_rsa_key "$temp/etc/ssh/"
install -m 644 /path/to/backup/ssh/ssh_host_rsa_key.pub "$temp/etc/ssh/"

# agenix マスター鍵（0400 root:root）
install -d -m 700 "$temp/etc/agenix"
sudo install -m 400 /etc/agenix/master.key "$temp/etc/agenix/master.key"
```

### 3-3. `nixos-anywhere` の実行コマンド

```bash
# <PUBLIC_IP> は実際のグローバル IP（または LAN 内実行なら 192.168.1.50）に置き換える
# 現在の Ubuntu に root 鍵ログインが無い場合は mitac@<PUBLIC_IP> で実行（sudo パスワード確認あり）
nix run github:nix-community/nixos-anywhere -- \
  --flake .#ubuntu \
  --extra-files "$temp" \
  --target-host mitac@<PUBLIC_IP> \
  --ssh-port 22
```

- 手元の PC がメモリ 8 GB のノート（Chromebook など）の場合、手元で全部ビルドするとメモリが厳しくなることがあります。その場合は `--build-on remote` を付けると、kexec 後の NucBox G3（16 GB RAM）側でビルドできます:
  ```bash
  nix run github:nix-community/nixos-anywhere -- \
    --flake .#ubuntu \
    --extra-files "$temp" \
    --build-on remote \
    --target-host mitac@<PUBLIC_IP> \
    --ssh-port 22
  ```
- 完了すると自動で再起動し、新しい NixOS（`.#ubuntu`）が立ち上がります。

---

## 4. インストール後の復元手順（この順番で進める）

再起動後、まずは SSH 鍵で `root@<PUBLIC_IP>`（または `mitac@<PUBLIC_IP>`）へログインします。
初回起動直後は `mitac` のパスワードが未設定のため、最初の管理者作業は鍵認証の `root` で入るのが確実です。

### 手順 1: 基本状態・パスワード・agenix の確認

```bash
ssh root@<PUBLIC_IP>

# IP が 192.168.1.50 になっているか、btrfs と 4G swapfile が有効か確認
ip -4 addr show enp3s0
df -h / /home /nix /var/log /boot
swapon --show

# mitac のログインパスワードを設定（sudo および LAN/Tailscale パスワード SSH 用）
passwd mitac

# agenix の復号結果を確認（--extra-files で渡していなかった場合はここで /etc/agenix/master.key を配置して再適用）
ls -la /run/agenix/
```

### 手順 2: SSH ホスト鍵の復元（`--extra-files` を使わなかった場合のみ）

```bash
# バックアップから /etc/ssh/ssh_host_* を戻す（秘密鍵 0600、公開鍵 0644、root:root）
systemctl restart sshd
```

### 手順 3: Tailscale 状態の復元（アドレス `100.124.196.22` と exit node 維持）

```bash
systemctl stop tailscaled
rm -rf /var/lib/tailscale/*
cp -a /path/to/backup/tailscale/. /var/lib/tailscale/
chown -R root:root /var/lib/tailscale
chmod 700 /var/lib/tailscale
systemctl start tailscaled

# 確認（元のアドレス 100.124.196.22 / fd7a:115c:a1e0::f101:c484 で Online になっていること）
tailscale status
```

### 手順 4: SoftEther VPN Server の設定・証明書復元

NixOS の `services.softether` モジュールのデータディレクトリは **`/var/lib/softether`** で、サーバー本体は **`/var/lib/softether/vpnserver/`** を見ます。

> **重要**: `softether-init.service` が初回起動時に `/var/lib/softether/vpnserver/hamcore.se2` を配置します。ディレクトリごと丸ごと上書きして `hamcore.se2` を消さないよう、初回起動後にサービスを止めてから `vpn_server.config` と証明書だけをコピーしてください。

```bash
systemctl stop vpnserver

# hamcore.se2 が存在することを確認
ls -la /var/lib/softether/vpnserver/

# 設定と証明書を配置（hamcore.se2 はそのまま残す）
install -m 600 -o root -g root /path/to/backup/softether/vpn_server.config \
  /var/lib/softether/vpnserver/vpn_server.config
cp -a /path/to/backup/softether/chain_certs /var/lib/softether/vpnserver/ 2>/dev/null || true
chown -R root:root /var/lib/softether/vpnserver

systemctl start vpnserver
systemctl status vpnserver
```

### 手順 5: `/home/mitac` と `.env` 類の復元

```bash
# バックアップ先から /home/mitac へ展開（パーミッション・シンボリックリンク保持）
rsync -aHAX /path/to/backup/home-mitac/ /home/mitac/
chown -R mitac:users /home/mitac

# ~/.ssh/authorized_keys に古い `/usr/bin/rrsync` の行が残っていると
# /etc/ssh/authorized_keys.d/mitac（NixOS の rrsync パス）より先に一致して失敗するため退避する
mv /home/mitac/.ssh/authorized_keys /home/mitac/.ssh/authorized_keys.ubuntu-bak 2>/dev/null || true

# MySettings を配置しておく（以後の rebuild / secrets コマンド用）
su - mitac -c 'test -d ~/MySettings || git clone -b main https://github.com/mitac31709/MySettings.git ~/MySettings'
```

### 手順 6: Docker ボリューム・ローカルイメージ復元と compose スタック起動

```bash
# named volume がある場合
systemctl stop docker
cp -a /path/to/backup/docker-volumes/. /var/lib/docker/volumes/
systemctl start docker

# ローカルビルドの Docker イメージを読み戻す（または FindSenryu4Discord で docker compose build）
zstd -dc /path/to/backup/docker-images/findsenryu4discord-app.tar.zst | docker load

# mitac で各 compose ディレクトリから起動
# 対象: ~/znc, ~/ntopng, ~/FindSenryu4Discord, ArchiveTeam (uploaderjp x2 / ts-ubuntu-at-exit),
#       watchtower, ~/slowflow-vpn (zstdvpn)
su - mitac -c 'cd ~/znc && docker compose up -d'
# 他の compose も同様に `docker compose up -d` で起動し、`docker ps` で確認
```

### 手順 7: Hermes / siesta-bot / lecture-asr / lecture-publish の起動確認

1. 復元した `/home/mitac/.config/systemd/user/` の旧ユニットが `linger` で二重起動しないよう、NixOS 側（システムユニット）へ移行済みの旧ユーザーユニットを無効化・退避します:
   ```bash
   su - mitac -c '
     mkdir -p ~/.config/systemd/user.ubuntu-bak
     for f in hermes-gateway.service siesta-bot.service lecture-asr.service lecture-asr.path lecture-asr.timer lecture-publish.service lecture-publish.timer nfas26.service; do
       mv ~/.config/systemd/user/"$f" ~/.config/systemd/user.ubuntu-bak/ 2>/dev/null || true
       rm -f ~/.config/systemd/user/default.target.wants/"$f" ~/.config/systemd/user/timers.target.wants/"$f"
     done
     systemctl --user daemon-reload || true
   '
   ```
2. NixOS 側の各ユニットを起動・確認します:
   ```bash
   systemctl start hermes-gateway siesta-bot
   systemctl status hermes-gateway siesta-bot lecture-asr.path lecture-asr.timer lecture-publish.timer znc-tailscale-cert.timer
   ```
3. `lecture-asr` の venv（`~/.local/share/lecture-asr/venv`）や `siesta-bot/.venv` が古い Ubuntu の `/usr/bin/python3` への壊れたシンボリックリンクを指している場合は、`uv` で venv を張り直します（`programs.nix-ld` が有効なので `ctranslate2` / `onnxruntime` の wheel もそのまま動きます）。

### 手順 8: CIFS マウント・Minecraft・restic バックアップの確認

```bash
# CIFS（GALLERIA 192.168.1.33 が起動しているときに自動マウントを確認）
ls /mnt/windows-hdd

# Minecraft（必要なときだけ手動起動。自動起動はしない。ポート 25565 競合防止のため排他）
# 対象 6 インスタンス:
#   ATM10 / ATM9-Eureka（直近使用）/ latest-vanila / mohist-1.20.1 / paper-1.21.11 / yower-1.21.1
# sudo systemctl start minecraft@ATM9-Eureka
# journalctl -u minecraft@ATM9-Eureka -f

# restic 日次バックアップ（保存先: rclone:gdrive:restic/ubuntu-home）
su - mitac -c 'backup about'
su - mitac -c 'backup run && backup log'
```

すべて問題なく動いたら、念のため 1 回 `sudo reboot` して、再起動後に LAN IP（`192.168.1.50`）・SSH・Tailscale・SoftEther・Docker・各常駐サービスが自動で戻ることを確認してください。
