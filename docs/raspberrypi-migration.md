# Raspberry Pi 5（`raspberrypi`）NixOS 移行手順書

現在 Raspberry Pi OS（Debian 12 bookworm）が動いている **Raspberry Pi 5（8GB / 28.8GB SD カード `mmcblk0`）** を、`nvmd/nixos-raspberrypi` ベースの NixOS（`.#raspberrypi`）へ移行するための手順です。

この移行では **今使っている SD カード（28.8GB）を上書き** します。失敗しても元の Raspberry Pi OS に丸ごと戻せるように、**必ず「1. SD カード全体のバックアップ」を一番最初に完了してから** 進めてください。

---

## 0. 移行前に必要なもの

- 別の Linux PC（または Chromebook / VAIO）と microSD カードリーダー
  - 作業用の一時空き容量として 20GB ほどあると安心です（直接 Google Drive へ送ることもできます）
- Google Drive（空き容量 2TB 以上あり、保存先として十分）と `rclone`
- （Clonezilla を使う場合）32GB 以上の空き USB メモリとキーボード・ディスプレイ（またはシリアル接続）
- このリポジトリの agenix マスター鍵（`/etc/agenix/master.key` / Bitwarden の `agenix-master-key`）

---

## 1. 最優先：SD カード全体のフルバックアップ（zstd イメージ）

ファイル単位のコピーだけでは、起動用ファームウェア・パーティション構成・権限まで元どおりには戻りません。**SD カードを 1 ビットも書き換える前に、カード丸ごとのイメージを zstd 圧縮で保存します。**

### 事前準備（任意・イメージを小さくするため）

現在の Pi の journal ログだけで約 2.1GB あります。Pi を止める前に掃除しておくとイメージが少し軽くなります。

```bash
# 現在の Raspberry Pi 上で実行
sudo journalctl --vacuum-size=200M
```

そのあと安全にシャットダウンしてから SD カードを抜きます。

```bash
sudo poweroff
```

### 方法 A：別 PC のカードリーダーで `dd | zstd` イメージを取る（おすすめ・一番確実）

1. SD カードを別 PC のカードリーダーに挿し、デバイス名を確認します（例では `/dev/sdX` とします。**内蔵 SSD や別ドライブと絶対に間違えないこと**）。

   ```bash
   lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL
   ```

   28.8GB 前後で `vfat`（512MB）と `ext4`（28.3GB）の 2 パーティションが見えるデバイスが対象です。マウントされていたら全部外します。

   ```bash
   sudo umount /dev/sdX* 2>/dev/null || true
   ```

2. SD カード全体を zstd 圧縮してイメージ化します（圧縮後はだいたい 10〜16GB になります）。

   ```bash
   sudo dd if=/dev/sdX bs=4M status=progress conv=fsync \
     | zstd -T0 -10 -o raspberrypi-mmcblk0-backup.img.zst
   ```

3. 壊れていないか検証し、チェックサム（SHA-256）も作ります。

   ```bash
   zstd -t raspberrypi-mmcblk0-backup.img.zst
   sha256sum raspberrypi-mmcblk0-backup.img.zst > raspberrypi-mmcblk0-backup.img.zst.sha256
   ```

4. 空き容量が 2TB 以上ある **Google Drive** へアップロードし、転送後のサイズ・ハッシュも確認します。

   ```bash
   rclone copy -P raspberrypi-mmcblk0-backup.img.zst gdrive:backups/raspberrypi/
   rclone copy -P raspberrypi-mmcblk0-backup.img.zst.sha256 gdrive:backups/raspberrypi/
   rclone check raspberrypi-mmcblk0-backup.img.zst gdrive:backups/raspberrypi/
   ```

   ※ ローカルに 16GB の空きが無い場合は、直接 `rclone rcat` で Google Drive へ流すこともできます（その場合は完了後に一度 Google Drive から `rclone cat ... | zstd -t` で破損チェックしてください）。

### 方法 B：Clonezilla でイメージを取る

カードリーダーが無い場合は、別 USB メモリに Clonezilla live（ARM64 版、またはカードリーダーを繋いだ x86_64 PC で起動）を用意し、以下の設定でイメージを取ります。

1. `device-image` → 保存先に SSH / SMB / 外付け USB HDD を選ぶ
2. `savedisk`（ディスク丸ごと保存）を選び、対象に `mmcblk0`（28.8GB）を指定
3. 圧縮方式に **zstd** を選び、保存後の **イメージ検証（check image）をオン** にする
4. 作成されたイメージフォルダを丸ごと Google Drive（`gdrive:backups/raspberrypi/clonezilla/` など）へコピーしておく

### 元の Raspberry Pi OS へ丸ごと戻す方法（ロールバック手順）

もし NixOS 移行がうまくいかず元に戻したいときは、Google Drive からイメージを戻して同じ（または 32GB 以上の）SD カードに書き戻すだけです。

```bash
# 1. Google Drive から取得してハッシュ検証
rclone copy -P gdrive:backups/raspberrypi/raspberrypi-mmcblk0-backup.img.zst .
rclone copy -P gdrive:backups/raspberrypi/raspberrypi-mmcblk0-backup.img.zst.sha256 .
sha256sum -c raspberrypi-mmcblk0-backup.img.zst.sha256

# 2. 書き戻し先 SD カード（/dev/sdX）を確認し、アンマウントする
lsblk -o NAME,SIZE,MODEL,TRAN
sudo umount /dev/sdX* 2>/dev/null || true

# 3. 展開しながら丸ごと書き戻す（パーティションテーブルと PARTUUID もそのまま戻る）
zstd -d -c raspberrypi-mmcblk0-backup.img.zst \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

書き終わったら SD カードを Raspberry Pi 5 に戻して電源を入れるだけで、移行前の Raspberry Pi OS がそのまま起動します（EEPROM の起動順は変えていないため変更不要です）。起動後、学内有線 802.1x と Tailscale が繋がることを確認してください。

### 補助：再起動せずに取るライブ（ファイル単位）バックアップ

**元の Raspberry Pi OS へ丸ごと戻す本命は、上の「SD カードを抜いて別 PC で取る zstd イメージ（または Clonezilla）」のままです。** 現在の Pi には LVM スナップショットが無く、稼働中の SD カード全体をそのまま `dd` するとファイルシステムの不整合が起きるおそれがあります。またファイル単位からの起動復旧は、新しい SD に vfat + ext4 を切り直して `cmdline.txt` / `fstab` の PARTUUID を合わせる手間がかかります。

あくまで「移行前に停止できない間のデータ保険」として、起動したままファイル単位のアーカイブを `ubuntu`（空き 147GB）や Google Drive へ二重に残したい場合の手順です（現在の Pi には `rclone` が入っていないため、別マシン経由で Google Drive へ送ります）。

- 目安サイズ：不要な `factorio` / `.sdkman` / `journal` を除いて約 13GB → **zstd 圧縮後 8〜14GB**（初回アップロード目安 30〜90 分）。SD 自身の空き（9.7GB）には収まらないため、必ず別ホストや外付け先へ出力します。

```bash
# 1. PostgreSQL 17 をダンプし、書き込みが発生する timer / DB 系だけ短時間止める
sudo -u postgres pg_dumpall -p 5438 | zstd > /tmp/pg17-all.sql.zst
sudo systemctl stop lecture-recorder.timer lecture-upload.timer ntopng redis-server

# 2. `/` と `/boot/firmware` をファイル単位でアーカイブ（例: SSH 経由で ubuntu へ直接書き出す）
sudo tar --acls --xattrs --numeric-owner --one-file-system \
  --exclude='/home/mitac/factorio' \
  --exclude='/home/mitac/.sdkman' \
  --exclude='/var/log/journal' \
  --exclude='/tmp' \
  --exclude='/var/tmp' \
  -cpf - / /boot/firmware \
  | zstd -T0 -10 \
  | ssh mitac@100.124.196.22 'cat > ~/backups/raspberrypi-live.tar.zst'

# 3. 止めたサービス・タイマーを戻す
sudo systemctl start redis-server ntopng lecture-recorder.timer lecture-upload.timer

# 4. rclone のある別マシンから Google Drive へ送る
# rclone copy -P raspberrypi-live.tar.zst pg17-all.sql.zst gdrive:backups/raspberrypi/
```

---

## 2. 個別に退避しておくデータ一覧

フルイメージとは別に、NixOS へそのまま引き継ぐデータ・設定・秘密を退避しておきます。**現在の Raspberry Pi OS が起動している間に**（sudo で）まとめて取得するのが一番確実です。

退避先の例として、手元の PC または `ubuntu`（空き容量十分）へ保存します。秘密情報（802.1x パスワード・SSH 秘密鍵・usque 設定・hostapd パスフレーズ等）を含むため、**Git には絶対にコミットせず**、権限 `0700` の一時フォルダで扱ってください。

| 退避対象 | パス / 取得方法（実測サイズ目安） | 移行後の使い道 |
|---|---|---|
| ホームフォルダ一式 | `/home/mitac`（約 1.7GB）、`/home/shimesaba`（**約 1.9GB**）、`/home/grokbot`（約 1.3MB） | lecture 関連、Drogon リポジトリ（`sangakusenshu`）、code-server 設定（`~/.config/code-server/config.yaml`）、WoL 中継スクリプト（`~/wol`, `~/wol-pc`）等（不要な `factorio.tar` や `.sdkman` は除いて OK） |
| NetworkManager 接続 | `/etc/NetworkManager/system-connections/` | `Wired connection 1`（有線 802.1x）、`Hazamaru AP-tr`、`eduroam` を `secrets/raspberrypi-nm-connections.age` に暗号化登録 |
| Tailscale 状態 | `/var/lib/tailscale/` | 同じ Tailscale ノード名・IP（`100.71.240.112`）・exit node 設定を認証キー無しで引き継ぐ |
| PostgreSQL 17 ダンプ | `sudo -u postgres pg_dumpall -p 5438 > pg17-all.sql`（クラスタ実測 約 39MB） | NixOS の PostgreSQL 17（ポート 5438）へそのままリストア（`/var/lib/postgresql` の生コピーより安全） |
| usque 設定 | `/etc/usque/`（`config.json`, `up.sh`、約 12KB） | `config.json` は `secrets/raspberrypi-usque-config.age` へ。`up.sh` も配置して `--on-connect` から利用 |
| hostapd / FreeAP 設定 | `/etc/hostapd/freeap.conf`, `/etc/freeap-notify.env`, `/etc/nftables.d/freeap-usque.nft`, `/var/lib/freeap-notify`（約 964KB） | `freeap.conf` は `secrets/raspberrypi-freeap-hostapd.age` へ、`freeap-notify.env` は `secrets/raspberrypi-freeap-notify-env.age` へ |
| ntopng / Redis データ | `/var/lib/ntopng/`（**約 728MB**）、`/var/lib/redis/`（約 100KB）、`/etc/ntopng/ntopng.conf` | 計測履歴の引き継ぎ（`/var/lib/ntopng` は 728MB あるため退避先の空きに注意） |
| 追加 CA 証明書 | `/usr/local/share/ca-certificates/burp-ca.crt`（939B） | 継続利用する場合、`modules/nixos/raspberrypi/default.nix` の `security.pki.certificateFiles` に追加 |
| SSH ホスト鍵 | `/etc/ssh/ssh_host_*` | 再インストール後も他端末から `REMOTE HOST IDENTIFICATION HAS CHANGED` が出ないように引き継ぐ |
| カスタムスクリプト・設定 | `/opt/lecture-recorder/`, `/etc/lecture-recorder/`, `/var/lib/lecrec/`（約 96KB）, `/usr/local/sbin/{campus-apload,freeap,ux302nc}*`, `/var/lib/campus-apload/`（約 7.4MB）, `/etc/udev/rules.d/99-ux302nc.rules`, `/etc/systemd/system/*.{service,timer}`, `/etc/sudoers.d/90-grokbot` | スクリプト本体の復元と、残りの TODO（udev の VID:PID・`grokbot` 公開鍵・sudoers 等）の最終確認 |

### 退避コマンド例（現在の Raspberry Pi 上で実行）

```bash
# 1. PostgreSQL 17（ポート 5438）を論理ダンプ
sudo -u postgres pg_dumpall -p 5438 | zstd > /tmp/pg17-all.sql.zst

# 2. ntopng / redis の整合性を保つため、コピー直前だけ一時停止すると安全
sudo systemctl stop ntopng redis-server

# 3. 退避用アーカイブを作成（一時作業先へ送る。不要な巨大キャッシュ・factorio・sdkman は除外例）
sudo tar --acls --xattrs --numeric-owner \
  --exclude='/home/mitac/factorio' \
  --exclude='/home/mitac/.sdkman' \
  --exclude='/home/mitac/.cache' \
  -cf - \
  /home/mitac \
  /home/shimesaba \
  /home/grokbot \
  /etc/NetworkManager/system-connections \
  /var/lib/tailscale \
  /etc/usque \
  /etc/hostapd \
  /etc/freeap-notify.env \
  /etc/nftables.d \
  /etc/ntopng/ntopng.conf \
  /var/lib/ntopng \
  /var/lib/redis \
  /usr/local/share/ca-certificates/burp-ca.crt \
  /etc/ssh/ssh_host_* \
  /opt/lecture-recorder \
  /etc/lecture-recorder \
  /var/lib/lecrec \
  /usr/local/sbin \
  /var/lib/campus-apload \
  /var/lib/freeap-notify \
  /etc/udev/rules.d/99-ux302nc.rules \
  /etc/systemd/system \
  /etc/sudoers.d \
  /tmp/pg17-all.sql.zst \
  | zstd -T0 -6 > /tmp/raspberrypi-migration-data.tar.zst

sudo systemctl start redis-server ntopng
```

作成したら安全な場所（手元の PC や Google Drive の暗号化保存先など）へコピーし、Pi 上の `/tmp/raspberrypi-migration-data.tar.zst` と `/tmp/pg17-all.sql.zst` は消しておきます。

### 退避データから agenix シークレットと TODO を準備する

SD カードを書き換える前に、手元の PC（このリポジトリ `MySettings`）で以下を準備してコミットしておくと移行がスムーズです。

1. `secrets/` に以下の `.age` ファイルを `agenix -e`（`secrets/agenix-rules.nix` 利用）で作成する：
   - `secrets/raspberrypi-nm-connections.age`（`Wired connection 1`・`Hazamaru AP-tr`・`eduroam` の 3 つの `.nmconnection` を `# === <名前> ===` 区切りで結合したもの。有線 802.1x がログイン無しで自動接続するよう `autoconnect=true`、`password-flags=0`、ユーザー制限 `permissions=` 無しを確認する）
   - `secrets/raspberrypi-freeap-hostapd.age`（`/etc/hostapd/freeap.conf` の中身）
   - `secrets/raspberrypi-usque-config.age`（`/etc/usque/config.json` の中身）
   - `secrets/raspberrypi-freeap-notify-env.age`（`/etc/freeap-notify.env` の中身：`WEBHOOK=...`。`freeap-count-notify` と `campus-apload-report` / `final` で共通利用）
   - `secrets/raspberrypi-lecture-timetable-env.age`（`/etc/lecture-recorder/timetable.env` の中身）
   - `secrets/raspberrypi-lecture-upload-key.age`（`/var/lib/lecrec/.ssh/id_ed25519` に展開される `ubuntu` 書き込み専用 SSH 秘密鍵、`lecrec` 所有）
   - （任意）`secrets/raspberrypi-code-server-env.age`（`config.yaml` ではなく環境変数でパスワードを渡す場合）
2. 残りの確認事項（TODO）：
   - 必要に応じて `/usr/local/share/ca-certificates/burp-ca.crt` を `modules/nixos/raspberrypi/default.nix` の `security.pki.certificateFiles` に追加する（その他の udev / nftables / `up.sh` / 運用スクリプト / sudoers / SSH 公開鍵はすでに Nix 側へ反映済み）。
   - TODO: 内蔵 Wi-Fi のファームウェア（`cyfmac43455-sdio.bin`）を minimal のまま残すか要確認（現在は NixOS 標準版のファームウェアを使用。minimal を維持したい場合は `hardware.firmware` を上書きして差し替える）。

---

## 3. NixOS SD イメージのビルド・書き込みと、その後の更新方法

### 3-1. SD イメージの入手・ビルドと書き込み

`nvmd/nixos-raspberrypi` は **Cachix バイナリキャッシュ（`https://nixos-raspberrypi.cachix.org`）** を提供しているため、ベンダーカーネルやファームウェアを自前で長時間ビルドせずに済みます。

#### パターン 1：公式インストーラ SD イメージをそのまま書き込んでから切り替える（一番手軽・手元が x86_64 8GB でも楽）

公式の RPi5 用 SD イメージはバイナリキャッシュ済みかつ **そのまま本番 SD カードとして使い続けられる可変パーティション構成（`FIRMWARE` 1GB + `NIXOS_SD` 自動拡張）** になっています。

```bash
# 1. 公式 RPi5 SD イメージをビルド（ほぼキャッシュからダウンロードされる）
#    ※ x86_64 マシンの場合、aarch64-linux のエミュレーション（binfmt）かリモートビルダーが必要。
#       無い場合は nvmd/nixos-raspberrypi の GitHub Releases / CI から最新 rpi5 イメージを取得しても OK。
nix --accept-flake-config build github:nvmd/nixos-raspberrypi/main#installerImages.rpi5

# 2. 圧縮イメージを展開
zstd -d result/sd-image/*.img.zst -o nixos-rpi5.img

# 3. 対象 SD カード（/dev/sdX）を確認し、アンマウントして書き込む
lsblk -o NAME,SIZE,MODEL,TRAN
sudo umount /dev/sdX* 2>/dev/null || true
sudo dd if=nixos-rpi5.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

#### パターン 2：このリポジトリから設定込みの SD イメージを直接ビルドする

aarch64 マシン（または binfmt / aarch64 ビルダー環境）がある場合は、このリポジトリの `packages.aarch64-linux.raspberrypi-sd-image` を直接ビルドして書き込めます。

```bash
# このリポジトリのルートで実行
nix --accept-flake-config build .#packages.aarch64-linux.raspberrypi-sd-image

zstd -d result/sd-image/*.img.zst -o raspberrypi-nixos.img
sudo umount /dev/sdX* 2>/dev/null || true
sudo dd if=raspberrypi-nixos.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

> **学内 802.1x 環境での初回起動のコツ**
> パターン 1（公式イメージ）を書き込んだ直後は、まだ学内 802.1x の資格情報が入っていません。初回だけ **自宅 LAN やテザリング、またはキーボード＋画面（もしくはシリアル `BOOT_UART=1`）** で起動して `/etc/agenix/master.key` を配置し、`.#raspberrypi` を適用すると安全です（または SD カードの `NIXOS_SD` パーティションを別 PC でマウントして `/mnt/etc/agenix/master.key` を先に置いておくこともできます）。

### 3-2. 導入後のリモート更新（`nixos-rebuild --target-host`）

NixOS 化が終わったら、以降は手元の PC（Chromebook / VAIO など）からネットワーク経由で更新できます。

- **Raspberry Pi 側でビルドさせる場合（手元が x86_64 のとき標準）**：

  ```bash
  nixos-rebuild switch --flake .#raspberrypi \
    --target-host mitac@raspberrypi \
    --build-host mitac@raspberrypi \
    --sudo
  ```

  - `--build-host mitac@raspberrypi` を付けると、x86_64 の手元 PC ではなく **Raspberry Pi 5（aarch64）自身** でビルド＆キャッシュ取得が行われます。
  - Tailscale 経由なら `mitac@raspberrypi.tail60de67.ts.net` または `mitac@100.71.240.112` を指定してください。

- **Raspberry Pi 上で直接更新する場合**：

  ```bash
  sudo nixos-rebuild switch --flake /home/mitac/MySettings#raspberrypi
  ```

---

## 4. インストール後の復元順序

初回起動後、以下の **順番どおり** に復元・確認します。ネットワーク（802.1x）と鍵を先に整えることで、途中で締め出されるのを防ぎます。

### ステップ 1：agenix マスター鍵の配置（最優先）

```bash
sudo install -d -m 0700 -o root -g root /etc/agenix
# Bitwarden（agenix-master-key）または退避した鍵を配置
sudo install -m 0400 -o root -g root /path/to/master.key /etc/agenix/master.key
```

### ステップ 2：SSH ホスト鍵の復元

他端末からの SSH 接続でホスト鍵警告が出ないよう、先に `/etc/ssh/ssh_host_*` を戻します。

```bash
sudo cp -a /path/to/backup/etc/ssh/ssh_host_* /etc/ssh/
sudo chmod 600 /etc/ssh/ssh_host_*_key
sudo chmod 644 /etc/ssh/ssh_host_*_key.pub
sudo systemctl restart sshd
```

### ステップ 3：`.#raspberrypi` の初回適用と 802.1x ネットワーク確認

手元 PC から `nixos-rebuild switch --flake .#raspberrypi --target-host ... --build-host ... --sudo`（または Pi 上で直接 `nixos-rebuild switch`）を実行します。

- `raspberrypi-nm-profiles.service` が `/run/NetworkManager/system-connections/` に `Wired connection 1`・`Hazamaru AP-tr`・`eduroam` を展開します。
- 再起動して **ログインしない状態のまま** 有線 `eth0` の 802.1x が自動で上がることを確認します。

```bash
nmcli connection show --active
nmcli device status
```

### ステップ 4：Tailscale 状態の復元（exit node）

認証キーを使わず、既存のノード ID と IP（`100.71.240.112`）を引き継ぎます。

```bash
sudo systemctl stop tailscaled
sudo rsync -aHAX /path/to/backup/var/lib/tailscale/ /var/lib/tailscale/
sudo chmod 700 /var/lib/tailscale
sudo systemctl start tailscaled
tailscale status
```

`raspberrypi.tail60de67.ts.net` がオンラインになり、exit node が有効になっていることを確認します。

### ステップ 5：ホームフォルダ・カスタムスクリプト・各種状態ディレクトリの復元

`/home/mitac` には WoL 中継用の `~/wol`・`~/wol-pc` も含まれます（`wakeonlan` は Nix 側で導入済み）。`campus-apload`・`freeap-count-notify`・`ux302nc` のスクリプト本体は Nix 側で `/usr/local/sbin` に配置済みのため、ここでは `/opt/lecture-recorder` とデータディレクトリを中心に復元します。

```bash
# ホームフォルダ（mitac: ~/wol・~/wol-pc 含む / shimesaba / grokbot）
sudo rsync -aHAX /path/to/backup/home/mitac/ /home/mitac/
sudo rsync -aHAX /path/to/backup/home/shimesaba/ /home/shimesaba/
sudo rsync -aHAX /path/to/backup/home/grokbot/ /home/grokbot/
sudo chown -R mitac:users /home/mitac
sudo chown -R shimesaba:users /home/shimesaba
sudo chown -R grokbot:users /home/grokbot

# lecture-recorder 本体と各種データディレクトリ
sudo mkdir -p /opt/lecture-recorder /etc/lecture-recorder
sudo rsync -aHAX /path/to/backup/opt/lecture-recorder/ /opt/lecture-recorder/
sudo rsync -aHAX /path/to/backup/etc/lecture-recorder/ /etc/lecture-recorder/
sudo rsync -aHAX /path/to/backup/var/lib/lecrec/ /var/lib/lecrec/
sudo chown -R lecrec:lecrec /var/lib/lecrec
sudo rsync -aHAX /path/to/backup/usr/local/sbin/ /usr/local/sbin/
sudo rsync -aHAX /path/to/backup/var/lib/campus-apload/ /var/lib/campus-apload/
sudo rsync -aHAX /path/to/backup/var/lib/freeap-notify/ /var/lib/freeap-notify/
```

※ `mitac` / `shimesaba` / `grokbot` のログインパスワード（sudo 用）が未設定なら、ここで `sudo passwd <user>` で設定します。

### ステップ 6：PostgreSQL 17（ポート 5438）のリストア

```bash
zstd -d -c /path/to/backup/pg17-all.sql.zst | sudo -u postgres psql -p 5438
# 疎通・DB 一覧確認
sudo -u postgres psql -p 5438 -c '\l'
```

### ステップ 7：usque・FreeWiFi AP（`freeap0`）の復元と fail-closed 確認

agenix に `raspberrypi-freeap-hostapd.age` と `raspberrypi-usque-config.age` を登録済みなら自動展開されます。`/etc/usque/up.sh` を使う場合は配置して実行権限を付けます。

```bash
sudo systemctl restart usque freeap-interface freeap-policy freeap-hostapd dnsmasq
ip addr show freeap0 usque0
ip rule show
ip route show table freeap
sudo nft list table inet freeap-usque
```

FreeAP にスマホ等を繋ぎ、IP（`10.42.0.x`）が配られ、外部へ Cloudflare WARP（`usque0`）経由で出られること、また `usque` 停止時に学内 LAN へ漏れない（fail-closed）ことを確認します。

### ステップ 8：ntopng・Redis・iperf3 の復元と確認

```bash
sudo systemctl stop ntopng redis
sudo rsync -aHAX /path/to/backup/var/lib/redis/ /var/lib/redis/
sudo rsync -aHAX /path/to/backup/var/lib/ntopng/ /var/lib/ntopng/
sudo chown -R redis:redis /var/lib/redis
sudo chown -R ntopng:ntopng /var/lib/ntopng
sudo systemctl start redis ntopng
```

待ち受けポートを確認します。

```bash
ss -tlnp | grep -E ':(22|3000|5201|5438|6379|8080)\b'
```

### ステップ 9：各サービスの最終チェックリスト

- [ ] `systemctl status NetworkManager ModemManager tailscaled sshd` がすべて active
- [ ] `systemctl status freeap-hostapd dnsmasq usque freeap-policy freeap-flowlog` が active
- [ ] `systemctl status ntopng redis iperf3 postgresql code-server` が active（`code-server` は `127.0.0.1:8080`、`ntopng` は `127.0.0.1:3000`）
- [ ] `systemctl is-enabled shimesaba` が `disabled`（ユニット定義あり・自動起動なし）
- [ ] `systemctl list-timers 'lecture-*' 'campus-apload-*' 'freeap-*'` に各タイマーが載っている
- [ ] `arecord -l` で USB 書画カメラ（`Camera`）が見え、`lecture-upload` の `ubuntu:~/lectures/inbox` への疎通が通る
- [ ] `swapon --show` で約 512MB のスワップが有効になっている
- [ ] `mmcli -L` で UX302NC（povo）モデムが認識される
