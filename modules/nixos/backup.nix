# Encrypted backup of the user's home + selected system state to Google Drive.
#
# Pieces:
#   - restic  : encrypted, deduplicated, snapshot-based backup engine.
#   - rclone  : Google Drive backend (restic talks to the "gdrive" remote).
#   - agenix  : sole source for the restic repository password and rclone.conf
#               at `/run/agenix` (Wi-Fi profiles and Tailscale pre-auth keys
#               are also managed in agenix rather than restic system staging).
#
# Paths:
#   - /home/mitac (with excludes for regenerable bulky trees and agenix secrets;
#     includes ~/MySettings)
#   - Root-only system state staged into the unit RuntimeDirectory:
#       Bluetooth pairings and Cloudflare WARP registration.
#     (/etc/shadow is intentionally not backed up.)
# See README.md → "/home の暗号化バックアップ" for setup & secret sync.
{
  config,
  lib,
  pkgs,
  flakeTarget ? "mitac",
  ...
}:

let
  user = "mitac";
  backupUnit = "restic-backups-home.service";

  # Google Drive destination: rclone remote "gdrive" plus a per-host subpath
  # (`<flakeTarget>-home`, e.g. chromebook-home / vaio-home) so multiple devices
  # never fight over a single restic repo lock or overwrite each other's
  # snapshots.
  repository = "rclone:gdrive:restic/${flakeTarget}-home";

  # Shared with `backup status` so the displayed retention matches the timer.
  retentionOpts = [
    "--keep-daily 7"
    "--keep-weekly 5"
    "--keep-monthly 12"
  ];

  # Shared between restic (`services.restic.backups.home.exclude`) and `backup audit`.
  backupExcludes = [
    "/home/${user}/.cache"
    "/home/${user}/.local/share/Trash"
    "/home/${user}/.config/mozilla/firefox/*/storage"
    "/home/${user}/.mozilla/firefox/*/storage"
    "/home/${user}/**/node_modules"
    "/home/${user}/**/.direnv"
    "/home/${user}/**/target"
    "/home/${user}/.local/state/nvim/swap"

    # Steam: game installs + client/runtime (re-downloadable). Keep config
    # (minus htmlcache), userdata, and Proton compatdata.
    # Also exclude steam.sh (and bootstrap.tar.xz): bin_steam.sh treats
    # executable steam.sh as "already bootstrapped" and skips extracting
    # ubuntu12_32, causing startup to fail if ubuntu12_32 is excluded.
    "/home/${user}/.local/share/Steam/steam.sh"
    "/home/${user}/.local/share/Steam/bootstrap.tar.xz"
    "/home/${user}/.local/share/Steam/steamapps/common"
    "/home/${user}/.local/share/Steam/steamapps/downloading"
    "/home/${user}/.local/share/Steam/steamapps/temp"
    "/home/${user}/.local/share/Steam/steamapps/shadercache"
    "/home/${user}/.local/share/Steam/steamapps/workshop"
    "/home/${user}/.local/share/Steam/depotcache"
    "/home/${user}/.local/share/Steam/steamrt64"
    "/home/${user}/.local/share/Steam/steamrt32"
    "/home/${user}/.local/share/Steam/ubuntu12_32"
    "/home/${user}/.local/share/Steam/ubuntu12_64"
    "/home/${user}/.local/share/Steam/package"
    "/home/${user}/.local/share/Steam/steamui"
    "/home/${user}/.local/share/Steam/appcache"
    "/home/${user}/.local/share/Steam/linux32"
    "/home/${user}/.local/share/Steam/linux64"
    "/home/${user}/.local/share/Steam/legacycompat"
    "/home/${user}/.local/share/Steam/clientui"
    "/home/${user}/.local/share/Steam/bin"
    "/home/${user}/.local/share/Steam/graphics"
    "/home/${user}/.local/share/Steam/config/htmlcache"

    # Cursor: agent worker binaries + editor caches/logs.
    "/home/${user}/.config/Cursor/User/globalStorage/anysphere.cursor-agent-worker"
    "/home/${user}/.config/Cursor/CachedData"
    "/home/${user}/.config/Cursor/CachedExtensionVSIXs"
    "/home/${user}/.config/Cursor/CachedProfilesData"
    "/home/${user}/.config/Cursor/Cache"
    "/home/${user}/.config/Cursor/Code Cache"
    "/home/${user}/.config/Cursor/GPUCache"
    "/home/${user}/.config/Cursor/DawnWebGPUCache"
    "/home/${user}/.config/Cursor/DawnGraphiteCache"
    "/home/${user}/.config/Cursor/IndexedDB"
    "/home/${user}/.config/Cursor/logs"

    # Codex / ChatGPT Desktop: Chromium component/DRM/GPU/service caches.
    "/home/${user}/.config/Codex/CertificateRevocation"
    "/home/${user}/.config/Codex/Crash Reports"
    "/home/${user}/.config/Codex/GPUPersistentCache"
    "/home/${user}/.config/Codex/OnDeviceHeadSuggestModel"
    "/home/${user}/.config/Codex/WasmTtsEngine"
    "/home/${user}/.config/Codex/WidevineCdm"
    "/home/${user}/.config/Codex/component_crx_cache"
    "/home/${user}/.config/Codex/Default/Cache"
    "/home/${user}/.config/Codex/Default/Code Cache"
    "/home/${user}/.config/Codex/Default/GPUCache"
    "/home/${user}/.config/Codex/Default/Service Worker"
    "/home/${user}/.config/Codex/Default/DawnGraphiteCache"
    "/home/${user}/.config/Codex/Default/DawnWebGPUCache"

    # Grok Bot: Electron/Chromium runtime caches.
    "/home/${user}/.config/Grok Bot/Cache"
    "/home/${user}/.config/Grok Bot/Code Cache"
    "/home/${user}/.config/Grok Bot/v8-code-cache"
    "/home/${user}/.config/Grok Bot/GPUCache"
    "/home/${user}/.config/Grok Bot/DawnGraphiteCache"
    "/home/${user}/.config/Grok Bot/DawnWebGPUCache"
    "/home/${user}/.config/Grok Bot/Crashpad"
    "/home/${user}/.config/Grok Bot/attachment-image-cache"
    "/home/${user}/.config/Grok Bot/link-preview-cache"
    "/home/${user}/.config/Grok Bot/plugin-logo-cache"
    "/home/${user}/.config/Grok Bot/link-favicon-cache"

    # Discord: Electron/Chromium runtime caches & logs.
    "/home/${user}/.config/discord/Cache"
    "/home/${user}/.config/discord/Code Cache"
    "/home/${user}/.config/discord/GPUCache"
    "/home/${user}/.config/discord/DawnGraphiteCache"
    "/home/${user}/.config/discord/DawnWebGPUCache"
    "/home/${user}/.config/discord/Crashpad"
    "/home/${user}/.config/discord/logs"
    "/home/${user}/.config/discord/discord_asset_cache"

    # OrcaSlicer: regenerable caches/logs/OTA (keep OrcaSlicer.conf, user/, printers/).
    "/home/${user}/.config/OrcaSlicer/cache"
    "/home/${user}/.config/OrcaSlicer/log"
    "/home/${user}/.config/OrcaSlicer/ota"

    # Development toolchains / package caches (re-downloadable).
    "/home/${user}/.platformio/packages"
    "/home/${user}/.platformio/penv"
    "/home/${user}/.platformio/.cache"
    "/home/${user}/.arduino15/packages"
    "/home/${user}/.arduino15/tmp"
    "/home/${user}/.arduino15/library_index.json*"
    "/home/${user}/.arduino15/package_index.json*"
    "/home/${user}/.npm"
    "/home/${user}/.local/share/go/pkg/mod"
    "/home/${user}/.local/share/pnpm/store"

    # Auto-downloaded binaries / old upgrade backups (apps are packaged in Nix).
    "/home/${user}/.local/share/cursor-agent/versions"
    "/home/${user}/.local/share/app.uniclipboard.desktop-upgrade-backups"

    # Vivaldi: regenerable caches, DRM/components, site WebStorage.
    # Keep Default/Extensions — Preferences still lists installs, and excluding
    # the tree leaves every extension broken after restore (CRX cache alone is incomplete).
    "/home/${user}/.config/vivaldi/Default/Service Worker"
    "/home/${user}/.config/vivaldi/Default/GPUCache"
    "/home/${user}/.config/vivaldi/Default/Code Cache"
    "/home/${user}/.config/vivaldi/Default/Cache"
    "/home/${user}/.config/vivaldi/Default/WebStorage"
    "/home/${user}/.config/vivaldi/component_crx_cache"
    "/home/${user}/.config/vivaldi/WasmTtsEngine"
    "/home/${user}/.config/vivaldi/WidevineCdm"
    "/home/${user}/.config/vivaldi/Safe Browsing"
    "/home/${user}/.config/vivaldi/GPUPersistentCache"
    "/home/${user}/.config/vivaldi/GraphiteDawnCache"

    "/home/${user}/.bash_history"
    "/home/${user}/.local/state/bash/history"
    "/home/${user}/.bash_profile"
    "/home/${user}/.bashrc"
    "/home/${user}/.nix-defexpr"
    "/home/${user}/.nix-profile"

    # Secrets managed declaratively by agenix (plus leftover plaintext copies / .backup files).
    "/home/${user}/.ssh/id_ed25519"
    "/home/${user}/.ssh/id_wsl_builder"
    "/home/${user}/.ssh/id_wsl_builder.pub"
    "/home/${user}/.ssh/*.backup"
    "/home/${user}/.android/adbkey"
    "/home/${user}/.android/adbkey.pub"
    "/home/${user}/.android/adbkey*.backup"
    "/home/${user}/.config/gh/hosts.yml"
    "/home/${user}/.config/gh/hosts.yml.backup"
    "/home/${user}/.config/opencode/service.json"
    "/home/${user}/.config/opencode/service.json.backup"
    "/home/${user}/.config/rclone/rclone.conf"
    "/home/${user}/.config/lan-mouse/lan-mouse.pem"
    "/home/${user}/.config/lan-mouse/lan-mouse.pem.backup"
    "/home/${user}/.config/wol-pc/config.env"
    "/home/${user}/Projects/wol-pc/config.env"

    # Gradle build/dependency caches (re-downloadable).
    "/home/${user}/.gradle/caches"
    "/home/${user}/.gradle/.tmp"
    "/home/${user}/.gradle/daemon"
    "/home/${user}/.local/share/gradle/caches"
    "/home/${user}/.local/share/gradle/.tmp"
    "/home/${user}/.local/share/gradle/daemon"

    # T3 Code: downloaded agent/browser runtimes, logs, temp dirs, Electron caches
    # (keep ~/.t3/userdata/statev2.sqlite, providers, attachments, and ~/.config/t3code-v2 settings).
    "/home/${user}/.t3/tools"
    "/home/${user}/.t3/userdata/logs"
    "/home/${user}/.t3/userdata/antigravity-tmp"
    "/home/${user}/.config/t3code-v2/Cache"
    "/home/${user}/.config/t3code-v2/Code Cache"
    "/home/${user}/.config/t3code-v2/GPUCache"
    "/home/${user}/.config/t3code-v2/GPUPersistentCache"
    "/home/${user}/.config/t3code-v2/DawnGraphiteCache"
    "/home/${user}/.config/t3code-v2/DawnWebGPUCache"
    "/home/${user}/.config/t3code-v2/Crashpad"

    # Bottles: downloaded Wine/Proton runners and temp downloads (keep bottles/ prefixes).
    "/home/${user}/.local/share/bottles/runners"
    "/home/${user}/.local/share/bottles/temp"

    # Auto-downloaded CLI tool runtimes and plugin caches (apps are packaged in Nix).
    "/home/${user}/.opencode/bin"
    "/home/${user}/.local/share/dsh/node22"
    "/home/${user}/.cursor/plugins/cache"
    "/home/${user}/.config/Cursor/agent-harness/versions"
  ];

  # GNU du treats `**` as single-segment glob; expand `/**/` so top-level matches also exclude.
  backupAuditExcludes = pkgs.writeText "restic-home-du-excludes" (
    lib.concatStringsSep "\n" (
      lib.concatMap (
        p:
        if lib.hasInfix "/**/" p then
          [
            (builtins.replaceStrings [ "/**/" ] [ "/" ] p)
            p
          ]
        else
          [ p ]
      ) backupExcludes
    )
    + "\n"
  );

  # Declarative secrets managed solely by agenix under /run/agenix.
  agenixResticPassword =
    config.age.secrets."restic-home-password".path or "/run/agenix/restic-home-password";
  agenixRcloneConf = config.age.secrets."rclone-conf".path or "/run/agenix/rclone-conf";

  # Systemd RuntimeDirectory copy (mode 0600): rclone rewrites its config file
  # when refreshing an expired OAuth access token, so it must not point directly
  # to read-only `/run/agenix/rclone-conf`.
  runtimeRcloneConfigFile = "/run/restic-backups-home/rclone.conf";
  rcloneConfigFile = runtimeRcloneConfigFile;

  # Matches RuntimeDirectory from the nixpkgs restic module for this unit.
  stagingRoot = "/run/restic-backups-home/system";
  bluetoothStagingDir = "${stagingRoot}/bluetooth";
  warpStagingDir = "${stagingRoot}/cloudflare-warp";

  # Root-only non-agenix sources → staged copies readable by the backup user.
  systemStagingSources = [
    {
      src = "/var/lib/bluetooth";
      dest = bluetoothStagingDir;
    }
    {
      src = "/var/lib/cloudflare-warp";
      dest = warpStagingDir;
    }
  ];

  # Run as root (systemd ExecStartPre=+...) so mode-600/700 trees are readable.
  stageSystemState = pkgs.writeShellScript "restic-home-stage-system" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
      ]
    }:$PATH"
    rm -rf "${stagingRoot}"
    mkdir -p "${stagingRoot}"
    ${lib.concatMapStringsSep "\n" (s: ''
      mkdir -p "${s.dest}"
      if [ -d "${s.src}" ]; then
        # Store copy stays writable for chown; do not preserve root-only ownership.
        find "${s.src}" -mindepth 1 -maxdepth 1 -exec \
          cp -a --no-preserve=ownership {} "${s.dest}/" \;
        chown -R ${user}:users "${s.dest}"
        chmod -R u=rwX,go= "${s.dest}"
      fi
    '') systemStagingSources}
  '';

  clearSystemStaging = pkgs.writeShellScript "restic-home-clear-system" ''
    set -eu
    rm -rf "${stagingRoot}" "${runtimeRcloneConfigFile}"
  '';

  # Desktop notifications via the logged-in user's session bus.
  # Same replace-id so start / finish collapse into one bubble.
  # Mid-run progress is shown on the Hyprland waybar panel (status file below).
  notifySend = lib.getExe pkgs.libnotify;
  notifyHint = "string:x-canonical-private-synchronous:restic-home";

  resticNotify = pkgs.writeShellScript "restic-home-notify" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.getent
        pkgs.util-linux
      ]
    }:$PATH"
    uid="$(getent passwd ${user} | cut -d: -f3)"
    bus="/run/user/''${uid}/bus"
    runtime="/run/user/''${uid}"
    urgency="$1"
    title="$2"
    body="$3"
    # Session bus may be absent (no graphical login); do not fail the backup.
    if [ ! -S "$bus" ]; then
      echo "restic-home-notify: no session bus for ''${user}; skip: $title" >&2
      exit 0
    fi
    set -- \
      ${notifySend} \
      --app-name=Restic \
      --urgency="$urgency" \
      -h ${notifyHint} \
      "$title" "$body"
    # Progress/cleanup hooks run as root; drop to the session user so dbus-broker accepts EXTERNAL auth.
    if [ "$(id -u)" -eq 0 ]; then
      exec runuser -u ${user} -- env \
        DBUS_SESSION_BUS_ADDRESS="unix:path=''${bus}" \
        XDG_RUNTIME_DIR="''${runtime}" \
        "$@"
    fi
    export DBUS_SESSION_BUS_ADDRESS="unix:path=''${bus}"
    export XDG_RUNTIME_DIR="''${runtime}"
    exec "$@"
  '';

  # Write / clear the waybar status JSON under mitac's XDG_RUNTIME_DIR.
  resticPanel = pkgs.writeShellScript "restic-home-panel" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.getent
        pkgs.jq
        pkgs.procps
        pkgs.util-linux
      ]
    }:$PATH"
    uid="$(getent passwd ${user} | cut -d: -f3)"
    status="/run/user/''${uid}/restic-home-status"
    action="$1"

    signal_waybar() {
      runuser -u ${user} -- env XDG_RUNTIME_DIR="/run/user/''${uid}" \
        pkill -SIGRTMIN+8 -x waybar >/dev/null 2>&1 || true
    }

    case "$action" in
      clear)
        rm -f "$status"
        signal_waybar
        ;;
      set)
        text="$2"
        tooltip="''${3:-$text}"
        class="''${4:-running}"
        jq -nc \
          --arg text "$text" \
          --arg tooltip "$tooltip" \
          --arg class "$class" \
          '{text:$text, tooltip:$tooltip, class:$class}' >"$status"
        chown ${user}:users "$status" 2>/dev/null || chown ${user} "$status" || true
        chmod 644 "$status" || true
        signal_waybar
        ;;
      *)
        echo "usage: restic-home-panel set <text> [tooltip] [class] | clear" >&2
        exit 2
        ;;
    esac
  '';

  # Companion unit: poll journal progress lines while the backup oneshot runs.
  # Declared separately because ExecStartPre children are killed when preStart ends.
  # Note: `systemctl is-activating` is not a real verb; use ActiveState instead.
  progressNotifyScript = pkgs.writeShellScript "restic-home-progress-notify" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.systemd
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ]
    }:$PATH"

    unit_busy() {
      case "$(systemctl show -p ActiveState --value ${backupUnit} 2>/dev/null || true)" in
        active|activating) return 0 ;;
        *) return 1 ;;
      esac
    }

    for _ in $(seq 1 60); do
      if unit_busy; then
        break
      fi
      sleep 0.5
    done

    if ! unit_busy; then
      # Backup never reached activating/active (e.g. pre-start failed fast).
      exit 0
    fi

    ${resticPanel} set "バックアップ …" "/home/${user} + システム → Google Drive" running || true
    ${resticNotify} low "バックアップ開始" "/home/${user} + システム → Google Drive" || true

    last=""
    while unit_busy; do
      line="$(
        journalctl -u ${backupUnit} -n 30 -o cat --no-pager 2>/dev/null \
          | grep -E '%|[0-9]+ / [0-9]+' \
          | tail -n 1 \
          | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          || true
      )"
      if [ -n "$line" ] && [ "$line" != "$last" ]; then
        pct="$(printf '%s\n' "$line" | sed -n 's/.*[^0-9]\([0-9]\{1,3\}\)\.[0-9]\+%.*$/\1/p')"
        if [ -z "$pct" ]; then
          pct="$(printf '%s\n' "$line" | sed -n 's/.*[^0-9]\([0-9]\{1,3\}\)%.*$/\1/p')"
        fi
        if [ -n "$pct" ]; then
          text="バックアップ ''${pct}%"
        else
          text="バックアップ中"
        fi
        ${resticPanel} set "$text" "$line" running || true
        last="$line"
      fi
      sleep 2
    done

    # Final label + clear are handled by backupCleanupCommand (avoids racing partOf stop).
  '';

  # Single entrypoint for home backup ops (systemd / rclone / agenix / restic).
  # NixOS names its auto-wrapper `restic-<name>`; we disable that and ship `backup`.
  # Meta subcommands are handled here; everything else is passed to restic.
  resticBackupCmd = pkgs.writeShellScriptBin "backup" ''
        set -euo pipefail

        unit="${backupUnit}"
        timer="restic-backups-home.timer"
        remote_name="gdrive"
        agenix_rclone_conf=${lib.escapeShellArg agenixRcloneConf}
        agenix_pw_file=${lib.escapeShellArg agenixResticPassword}

        # setuid sudo + packaged CLIs (restic-home-setup + secrets live outside/on user PATH).
        PATH="${
          lib.makeBinPath [
            pkgs.rclone
            pkgs.jq
            pkgs.openssh
            pkgs.systemd
            pkgs.coreutils
            pkgs.gawk
          ]
        }:/run/wrappers/bin:/run/current-system/sw/bin:/etc/profiles/per-user/${user}/bin:$PATH"

        resolve_writable_rclone_conf() {
          if [ -n "''${RCLONE_CONFIG:-}" ]; then
            export RCLONE_CONFIG
            return 0
          fi
          if [ ! -r "$agenix_rclone_conf" ]; then
            printf 'エラー: %s が見つかりません（secrets bootstrap && rebuild または secrets import-rclone を実行）。\n' \
              "$agenix_rclone_conf" >&2
            exit 1
          fi
          local runtime_dir="''${XDG_RUNTIME_DIR:-/tmp}"
          local runtime_conf="''${runtime_dir%/}/backup-rclone-$(id -u).conf"
          install -m 0600 "$agenix_rclone_conf" "$runtime_conf"
          export RCLONE_CONFIG="$runtime_conf"
        }

        prepare_restic_env() {
          if [ -z "''${RESTIC_PASSWORD:-}" ] && [ -z "''${RESTIC_PASSWORD_FILE:-}" ] && [ -z "''${RESTIC_PASSWORD_COMMAND:-}" ]; then
            if [ -r "$agenix_pw_file" ]; then
              export RESTIC_PASSWORD_FILE="$agenix_pw_file"
            else
              printf 'エラー: %s が見つかりません（secrets bootstrap && rebuild を実行してください）。\n' \
                "$agenix_pw_file" >&2
              exit 1
            fi
          fi
          export RESTIC_CACHE_DIR="/var/cache/restic-backups-home"
          # Allow overriding RESTIC_REPOSITORY in the environment (e.g. to inspect another host's repo).
          export RESTIC_REPOSITORY="''${RESTIC_REPOSITORY:-${repository}}"
          resolve_writable_rclone_conf
          export RESTIC_PROGRESS_FPS="0.2"
        }

        usage() {
          cat <<'EOF'
    backup — ホーム暗号化バックアップ CLI (restic / rclone / agenix / systemd)

    使い方:
      backup <command> [args…]
      backup -h | --help | help

    基本ワークフロー:
      backup setup                   対話式初回セットアップ (restic-home-setup)
      backup reconnect               rclone OAuth 再接続 (gdrive:) ＋ secrets/rclone-conf.age 更新
      backup about                   Google Drive 疎通確認
      backup run                     フルバックアップ開始 (systemd)
      backup log                     進捗・ログを journal で追う
      backup status                  状態・容量・直近バックアップを整理して表示
      backup status --full           systemd 詳細と直近ログも表示
      backup audit [N]               除外ルール適用後の大きいディレクトリ上位 N 件を表示 (既定: 25)

    確認・部分復元（agenix 鍵・設定を自動読み込み済み）:
      backup snapshots
      backup ls latest
      backup find NAME
      backup restore latest --target /tmp/restore
      backup unlock                  古い restic リポジトリロックを解除

    削除（空き容量を作る。restic はスナップショット単位のみ、個別ファイルは不可）:
      backup forget <ID> --prune     指定スナップショットを削除して領域を回収
      backup forget --keep-last 3 --prune  直近3世代だけ残す（--dry-run で事前確認可）
      backup prune                   参照されなくなったデータを回収
      backup forget --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
                                     通常の保持ポリシー（日次バックアップ後に自動実行）

    注意:
      - restore には必ず --target を指定する（省略すると /home/mitac を上書き）
      - forget / prune は破壊的。まず --dry-run で対象を確認すること
      - restic サブコマンドの詳細ヘルプ: backup <command> --help
      - 上記以外の第1引数はそのまま restic へ渡されます
    EOF
        }

        cmd="''${1:-}"
        case "$cmd" in
          ""|-h|--help|help)
            usage
            exit 0
            ;;
          run|start)
            shift
            if systemctl --quiet is-active "$unit" 2>/dev/null; then
              printf '%s は既に実行中です。\n' "$unit"
            elif systemctl start "$unit" 2>/dev/null; then
              printf '%s を開始しました。\n' "$unit"
            else
              sudo systemctl start "$unit"
              printf '%s を開始しました（sudo 経由）。\n' "$unit"
            fi
            printf 'ログ確認: backup log\n'
            ;;
          audit)
            shift
            limit="''${1:-25}"
            case "$limit" in
              ""|*[!0-9]*|0)
                printf '使い方: backup audit [N]（N は正の整数、既定 25）\n' >&2
                exit 2
                ;;
            esac
            printf '=== バックアップ対象サイズ監査 (/home/%s, 上位 %s 件 / 現行 exclude 適用) ===\n' "${user}" "$limit"
            out="$(du -xh --max-depth=3 --exclude-from=${backupAuditExcludes} "/home/${user}" 2>/dev/null || true)"
            printf '%s\n' "$out" | sort -hr | awk -v n="$limit" 'NR <= n { print }'
            ;;
          log|logs)
            shift
            exec journalctl -u "$unit" -f "$@"
            ;;
          status)
            shift
            full=0
            for arg in "$@"; do
              case "$arg" in
                --full|-v) full=1 ;;
              esac
            done

            printf '=== バックアップ状態 ===\n'
            unit_state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
            unit_sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
            unit_result="$(systemctl show -p Result --value "$unit" 2>/dev/null || true)"
            timer_state="$(systemctl show -p ActiveState --value "$timer" 2>/dev/null || true)"
            next_run="$(systemctl list-timers "$timer" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}' || true)"
            printf '  サービス : %s (%s) / 前回結果: %s\n' \
              "''${unit_state:-unknown}" "''${unit_sub:-unknown}" "''${unit_result:-unknown}"
            printf '  タイマー : %s / 次回: %s\n' \
              "''${timer_state:-unknown}" "''${next_run:-不明}"
            printf '  保持     : %s\n' "${lib.concatStringsSep " " retentionOpts}"

            # 容量・スナップショットの取得には restic / rclone の環境が必要。
            prepare_restic_env

            printf '\n=== 容量 (Google Drive) ===\n'
            drive_about="$(rclone about "''${remote_name}:" 2>&1 || true)"
            if [ -n "$drive_about" ]; then
              printf '%s\n' "$drive_about" | sed 's/^/  /'
            else
              printf '  取得失敗（backup reconnect を確認）\n'
            fi
            case "$RESTIC_REPOSITORY" in
              rclone:*)
                repo_target="''${RESTIC_REPOSITORY#rclone:}"
                repo_info="$(rclone size "$repo_target" 2>/dev/null || true)"
                repo_size="$(printf '%s\n' "$repo_info" | awk '/^Total size:/ {print $3, $4}')"
                repo_objects="$(printf '%s\n' "$repo_info" | awk '/^Total objects:/ {print $3}')"
                printf '  リポジトリ: %s (%s objects)\n' "''${repo_size:-不明}" "''${repo_objects:-?}"
                printf '  対象      : %s\n' "$RESTIC_REPOSITORY"
                ;;
            esac
            raw_json="$(restic stats --mode raw-data --json 2>/dev/null | jq -c '.' || true)"
            if [ -n "$raw_json" ]; then
              raw_size="$(printf '%s' "$raw_json" | jq -r '.total_size' | awk '{printf "%.2f GiB", $1/1073741824}')"
              raw_uncompressed="$(printf '%s' "$raw_json" | jq -r '.total_uncompressed_size' | awk '{printf "%.2f GiB", $1/1073741824}')"
              raw_ratio="$(printf '%s' "$raw_json" | jq -r '.compression_ratio' | awk '{printf "%.2f", $1}')"
              raw_count="$(printf '%s' "$raw_json" | jq -r '.snapshots_count')"
              printf '  実データ  : %s (未圧縮 %s / 圧縮 %sx / %s 世代)\n' \
                "$raw_size" "$raw_uncompressed" "$raw_ratio" "$raw_count"
            fi

            printf '\n=== 直近のバックアップ ===\n'
            latest_json="$(restic snapshots --json latest 2>/dev/null | jq -c '.[0] // empty' || true)"
            if [ -n "$latest_json" ]; then
              snap_id="$(printf '%s' "$latest_json" | jq -r '.short_id // .id')"
              snap_time="$(printf '%s' "$latest_json" | jq -r '.time')"
              snap_host="$(printf '%s' "$latest_json" | jq -r '.hostname')"
              snap_paths="$(printf '%s' "$latest_json" | jq -r '.paths | join(", ")')"
              start="$(printf '%s' "$latest_json" | jq -r '.summary.backup_start')"
              end="$(printf '%s' "$latest_json" | jq -r '.summary.backup_end')"
              new_files="$(printf '%s' "$latest_json" | jq -r '.summary.files_new')"
              changed_files="$(printf '%s' "$latest_json" | jq -r '.summary.files_changed')"
              unchanged_files="$(printf '%s' "$latest_json" | jq -r '.summary.files_unmodified')"
              added="$(printf '%s' "$latest_json" | jq -r '.summary.data_added' | awk '{printf "%.2f GiB", $1/1073741824}')"
              added_packed="$(printf '%s' "$latest_json" | jq -r '.summary.data_added_packed' | awk '{printf "%.2f GiB", $1/1073741824}')"
              duration=""
              if [ -n "$start" ] && [ "$start" != null ] && [ -n "$end" ] && [ "$end" != null ]; then
                start_epoch="$(date -d "$start" +%s 2>/dev/null || true)"
                end_epoch="$(date -d "$end" +%s 2>/dev/null || true)"
                if [ -n "$start_epoch" ] && [ -n "$end_epoch" ]; then
                  secs=$((end_epoch - start_epoch))
                  duration=" ($((secs / 60))分)"
                fi
              fi
              printf '  ID       : %s\n' "$snap_id"
              printf '  日時     : %s%s\n' "$snap_time" "$duration"
              printf '  ホスト   : %s\n' "$snap_host"
              printf '  対象     : %s\n' "$snap_paths"
              printf '  ファイル : 新規 %s / 変更 %s / 未変更 %s\n' \
                "$new_files" "$changed_files" "$unchanged_files"
              printf '  追加     : %s → %s (圧縮後)\n' "$added" "$added_packed"
            else
              printf '  スナップショットなし（backup run を実行）\n'
            fi
            stats_json="$(restic stats latest --mode restore-size --json 2>/dev/null | jq -c '.' || true)"
            if [ -n "$stats_json" ]; then
              restore_files="$(printf '%s' "$stats_json" | jq -r '.total_file_count')"
              restore_size="$(printf '%s' "$stats_json" | jq -r '.total_size' | awk '{printf "%.2f GiB", $1/1073741824}')"
              printf '  リストア時: %s ファイル / %s\n' "$restore_files" "$restore_size"
            fi

            if [ "$full" -eq 1 ]; then
              printf '\n=== systemd 詳細 ===\n'
              systemctl status "$unit" --no-pager || true
              printf '\n'
              systemctl status "$timer" --no-pager || true
              printf '\n=== 直近ログ ===\n'
              journalctl -u "$unit" -n 15 --no-pager || true
            else
              printf '\n  詳細は backup status --full\n'
            fi
            ;;
          setup)
            shift
            exec restic-home-setup "$@"
            ;;
          reconnect)
            shift
            tmp_conf="$(mktemp --tmpdir "backup-rclone-reconnect.XXXXXX.conf")"
            chmod 0600 "$tmp_conf"
            cleanup_tmp_conf() { rm -f "$tmp_conf"; }
            trap cleanup_tmp_conf EXIT
            if [ -r "$agenix_rclone_conf" ]; then
              install -m 0600 "$agenix_rclone_conf" "$tmp_conf"
            fi
            export RCLONE_CONFIG="$tmp_conf"
            rclone config reconnect "''${remote_name}:" "$@"
            for arg in "$@"; do
              case "$arg" in
                -h|--help|--help=*) exit 0 ;;
              esac
            done
            if command -v secrets >/dev/null 2>&1 && secrets import-rclone "$tmp_conf"; then
              printf '\nagenix の secrets/rclone-conf.age を更新しました。\n'
              printf '反映するには: rebuild（未ステージなら git add secrets/rclone-conf.age も実行）\n'
            else
              trap - EXIT
              printf '\n警告: secrets import-rclone の自動実行に失敗しました。\n' >&2
              printf '再認証済み設定を一時保持しています: %s\n' "$tmp_conf" >&2
              printf '以下を実行してから一時ファイルを削除してください:\n' >&2
              printf '  secrets import-rclone %q && rm -f %q && rebuild\n' "$tmp_conf" "$tmp_conf" >&2
              exit 1
            fi
            ;;
          about)
            shift
            resolve_writable_rclone_conf
            exec rclone about "''${remote_name}:" "$@"
            ;;
          *)
            prepare_restic_env
            exec ${lib.getExe pkgs.restic} "$@"
            ;;
        esac
  '';

  # Interactive first-time setup / re-auth: rclone gdrive remote -> agenix, restic key -> agenix, first backup.
  # Secrets stay out of the Nix store and live exclusively under agenix (/run/agenix).
  resticHomeSetup = pkgs.writeShellApplication {
    name = "restic-home-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.rclone
      pkgs.restic
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      # setuid sudo + system wrappers (backup) + user profile (secrets) live outside app PATH.
      export PATH="/run/wrappers/bin:/run/current-system/sw/bin:/etc/profiles/per-user/${user}/bin:$PATH"

      remote_name="gdrive"
      agenix_rclone_conf=${lib.escapeShellArg agenixRcloneConf}
      agenix_pw_file=${lib.escapeShellArg agenixResticPassword}
      repo="${repository}"
      unit="${backupUnit}"

      say() { printf '%s\n' "$*"; }
      step() { printf '\n==> %s\n' "$*"; }
      die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }

      confirm() {
        local prompt="$1"
        local reply
        printf '%s [y/N] ' "$prompt"
        read -r reply || true
        case "$reply" in
          y|Y|yes|YES) return 0 ;;
          *) return 1 ;;
        esac
      }

      # Google OAuth apps left in "Testing" issue refresh tokens that die ~weekly
      # (invalid_grant). Publishing (unverified is fine for personal use) fixes it.
      warn_oauth_publish() {
        say "重要: Google Cloud の OAuth 同意画面は「本番環境に公開 (Publish)」にしてください（Testing 不可）。"
        say "  Testing のままだと refresh_token が約 7 日で失効します（invalid_grant）。"
        say "  Console: https://console.cloud.google.com/auth/audience"
        say "  Branding（所有ドメイン必須。github.io は却下されやすい）:"
        say "    アプリ名: restic Home Backup"
        say "    ホームページ: https://restic-oauth.mitac.f5.si/"
        say "    プライバシー: https://restic-oauth.mitac.f5.si/privacy.html"
        say "    承認済みドメイン: mitac.f5.si（Search Console でドメイン確認済み）"
        say "  Branding 保存後、Audience → Publish app を押してください。"
        say "  Publish 後に再接続すると長寿命の refresh_token が発行されます。"
        say "  参考: https://rclone.org/drive/#making-your-own-client-id"
      }

      probe_gdrive() {
        # 0 = OK, 1 = auth/token failure, 2 = other failure
        # (command substitution alone would mask rclone's exit status)
        local err rc=0
        err="$(rclone about "''${remote_name}:" 2>&1)" || rc=$?
        if [ "$rc" -eq 0 ]; then
          return 0
        fi
        printf '%s\n' "$err" >&2
        case "$err" in
          *invalid_grant*|*token\ expired*|*couldn?t\ fetch\ token*) return 1 ;;
          *) return 2 ;;
        esac
      }

      say "restic ホームバックアップ — セットアップ (agenix 一元管理)"
      say "リポジトリ: $repo"

      tmp_conf="$(mktemp --tmpdir "restic-home-setup.XXXXXX.conf")"
      chmod 0600 "$tmp_conf"
      cleanup_tmp_conf() { rm -f "$tmp_conf"; }
      trap cleanup_tmp_conf EXIT

      # --- 1. rclone Google Drive remote -> secrets/rclone-conf.age ------
      step "1/3 Google Drive リモート ($remote_name → agenix)"
      export RCLONE_CONFIG="$tmp_conf"
      rclone_updated=0
      if [ -r "$agenix_rclone_conf" ]; then
        install -m 0600 "$agenix_rclone_conf" "$tmp_conf"
        say "現在の agenix 設定 ($agenix_rclone_conf) を読み込みました。"
      fi

      has_remote=0
      if [ -s "$tmp_conf" ] && rclone listremotes 2>/dev/null | grep -qx "''${remote_name}:"; then
        has_remote=1
      fi

      if [ "$has_remote" -eq 1 ]; then
        say "リモート ''${remote_name}: は既に設定済みです。"
        probe_rc=0
        probe_gdrive || probe_rc=$?
        if [ "$probe_rc" -eq 0 ]; then
          say "Google Drive 認証 OK (rclone about ''${remote_name}:)。"
          if confirm "OAuth を再設定しますか（独自 client_id / refresh_token）？"; then
            warn_oauth_publish
            say "独自の Desktop OAuth client_id を設定してください（共有 ID は制限／2026 年廃止予定）。"
            rclone config reconnect "''${remote_name}:" || rclone config
            rclone_updated=1
          fi
        else
          say "Google Drive 認証エラー（終了コード $probe_rc）。"
          warn_oauth_publish
          if ! confirm "OAuth アプリを公開 (Publish) 済みであることを確認し、今すぐ再接続しますか？"; then
            die "中断しました。アプリを公開してから次を実行してください: backup reconnect"
          fi
          rclone config reconnect "''${remote_name}:" || rclone config
          probe_gdrive || die "再接続後も ''${remote_name}: へ接続できませんでした。Publish と client_id を確認してください。"
          say "再接続後の Google Drive 認証 OK。"
          rclone_updated=1
        fi
      else
        say "リモート ''${remote_name}: が未設定です。対話式 rclone config を起動します。"
        warn_oauth_publish
        say "リモート名は必ず ''${remote_name}（storage: Google Drive / drive）にしてください。"
        say "重要: 自分で作成した Google Cloud の Desktop OAuth client_id と client_secret を"
        say "貼り付けてください（空欄にすると共有クライアントになり低速・廃止対象です）。"
        say "参考: https://rclone.org/drive/#making-your-own-client-id"
        say "ブラウザー OAuth を完了し、rclone メニューを終了 (q) してください。"
        if ! confirm "rclone config を開始しますか？"; then
          die "中断しました。設定するには次を再実行してください: backup setup"
        fi
        rclone config
        if ! rclone listremotes 2>/dev/null | grep -qx "''${remote_name}:"; then
          die "rclone config 完了後もリモート ''${remote_name}: が見つかりません。"
        fi
        probe_gdrive || die "リモート ''${remote_name}: を作成しましたが認証確認に失敗しました。"
        say "リモート ''${remote_name}: OK。"
        rclone_updated=1
      fi

      if [ "$rclone_updated" -eq 1 ]; then
        if command -v secrets >/dev/null 2>&1 && secrets import-rclone "$tmp_conf"; then
          say "secrets/rclone-conf.age を更新しました（システム反映には rebuild を実行）。"
        else
          trap - EXIT
          say "警告: secrets import-rclone の自動実行に失敗しました。"
          say "設定を一時保持しています: $tmp_conf"
          die "次を実行してから一時ファイルを削除してください: secrets import-rclone \"$tmp_conf\" && rm -f \"$tmp_conf\" && rebuild"
        fi
      fi

      # --- 2. restic encryption password (agenix) ------------------------
      step "2/3 restic 暗号化鍵 (agenix)"
      if [ -r "$agenix_pw_file" ]; then
        say "agenix 復号済みパスフレーズを確認しました: $agenix_pw_file"
      else
        say "$agenix_pw_file が見つかりません。"
        if command -v secrets >/dev/null 2>&1 && confirm "secrets import-restic で secrets/restic-home-password.age を作成・暗号化しますか？"; then
          secrets import-restic
          say "暗号化しました。次に git add secrets/ && rebuild を実行してください。"
        else
          say "手動で設定するには: secrets init && secrets import-restic && git add secrets/ && rebuild"
        fi
      fi

      # Smoke-check only when both agenix secrets are readable on the system.
      if [ -r "$agenix_pw_file" ] && [ -r "$agenix_rclone_conf" ] && command -v backup >/dev/null 2>&1; then
        if RCLONE_CONFIG="$tmp_conf" RESTIC_PASSWORD_FILE="$agenix_pw_file" backup snapshots >/dev/null 2>&1; then
          say "リポジトリを開けました（既存スナップショット OK）。"
        else
          say "まだリポジトリは未初期化です（初回バックアップ前の正常な状態）。"
        fi
      fi

      # --- 3. First backup -----------------------------------------------
      step "3/3 初回バックアップ ($unit)"
      if [ "$rclone_updated" -eq 1 ] || [ ! -r "$agenix_rclone_conf" ] || [ ! -r "$agenix_pw_file" ]; then
        say "注: agenix の更新内容を /run/agenix へ反映するには先に \`rebuild\` を実行してください。"
      fi
      say "必要に応じて Google Drive 上に restic リポジトリを自動初期化します (initialize = true)。"
      if confirm "$unit を今すぐ開始しますか（sudo を求める場合があります）？"; then
        if systemctl --quiet is-active "$unit" 2>/dev/null; then
          say "$unit は既に実行中です。"
        elif systemctl start "$unit" 2>/dev/null; then
          say "$unit を開始しました。"
        else
          sudo systemctl start "$unit"
          say "$unit を開始しました（sudo 経由）。"
        fi
        say "ログ確認:"
        say "  backup log"
      else
        say "スキップしました。あとで開始するには:"
        say "  backup run"
        say "  backup log"
      fi

      say ""
      say "完了です。以後の確認・部分復元:"
      say "  backup snapshots"
      say "  backup restore latest --target /tmp/restore"
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    restic
    rclone
    resticBackupCmd
    resticHomeSetup
  ];

  services.restic.backups.home = {
    inherit user repository rcloneConfigFile;

    # Prefer a short `backup` CLI over nixpkgs' default `restic-home` wrapper.
    createWrapper = false;

    # Home plus staged root-only system state (Bluetooth, Cloudflare WARP).
    # Wi-Fi and Tailscale keys live in agenix rather than restic staging.
    paths = [
      "/home/${user}"
      stagingRoot
    ];

    # Skip regenerable bulk (Steam client/runtime, Cursor agent binaries, browser
    # caches/extensions, Firefox storage) and HM/Nix links.
    # Login password (/etc/shadow) is intentionally not staged.
    # ~/MySettings (flake checkout, including .git / uncommitted work) is kept.
    exclude = backupExcludes;

    # Decrypt restic passphrase and rclone OAuth config solely via agenix.
    passwordFile = agenixResticPassword;

    # Copy decrypted rclone.conf to writable RuntimeDirectory before restic preStart
    # so OAuth token refreshes succeed without failing on read-only /run/agenix.
    backupPrepareCommand = ''
      if [ ! -r ${lib.escapeShellArg agenixResticPassword} ]; then
        echo "restic-home: ${agenixResticPassword} is not readable (run: secrets bootstrap && rebuild)" >&2
        exit 1
      fi
      if [ ! -r ${lib.escapeShellArg agenixRcloneConf} ]; then
        echo "restic-home: ${agenixRcloneConf} is not readable (run: secrets bootstrap && rebuild)" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/install -m 0600 ${lib.escapeShellArg agenixRcloneConf} ${lib.escapeShellArg runtimeRcloneConfigFile}
    '';

    # Create the restic repository on Google Drive on first run.
    initialize = true;

    # Emit progress to the journal even under systemd (non-TTY); companion
    # notifier / waybar panel reads those lines (~every few seconds).
    progressFps = 0.2;

    # Retention: prune old snapshots after each run.
    pruneOpts = retentionOpts;

    # Run daily; catch up if the machine was powered off at the scheduled time.
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };

    # Final status (postStop always runs; SERVICE_RESULT distinguishes success).
    backupCleanupCommand = ''
      summary="$(
        journalctl -u ${backupUnit} -n 80 -o cat --no-pager 2>/dev/null \
          | grep -E 'Files:|Dirs:|Added to the repository|processed [0-9]' \
          | tail -n 4 \
          | tr '\n' ' ' \
          | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' \
          || true
      )"
      if [ "''${SERVICE_RESULT:-}" = success ]; then
        ${resticPanel} set "バックアップ完了" \
          "''${summary:-/home/${user} + システム → Google Drive}" done || true
        ${resticNotify} normal "バックアップ完了" \
          "''${summary:-/home/${user} + システム → Google Drive}" || true
      else
        fail_hint="結果: ''${SERVICE_RESULT:-unknown}（journalctl -u ${backupUnit}）"
        if journalctl -u ${backupUnit} -n 40 -o cat --no-pager 2>/dev/null \
          | grep -Eqi 'invalid_grant|token expired|couldn.t fetch token'; then
          fail_hint="GDrive OAuth失効。ConsoleでPublish後: backup reconnect"
        elif journalctl -u ${backupUnit} -n 40 -o cat --no-pager 2>/dev/null \
          | grep -Eqi 'restic-home-(password|rclone)|no such file|permission denied|/run/agenix'; then
          fail_hint="agenix復号失敗。/etc/agenix/master.key 確認: secrets bootstrap && rebuild"
        fi
        ${resticPanel} set "バックアップ失敗" "$fail_hint" failed || true
        ${resticNotify} critical "バックアップ失敗" "$fail_hint" || true
      fi
      # Leave the final panel label briefly; progress unit EXIT trap also clears.
      sleep 8
      ${resticPanel} clear || true
    '';

    # CLI: `backup` (see resticBackupCmd) — e.g.:
    #   backup setup | run | log | about | reconnect
    #   backup snapshots
    #   backup restore latest --target /tmp/restore
    #   RESTIC_REPOSITORY=rclone:gdrive:restic/vaio-home backup snapshots
  };

  # Systemd's default PATH for this unit does not include profile bins; restic
  # needs rclone on PATH. Start the progress notifier
  # alongside this oneshot (partOf stops it when the backup ends).
  systemd.services.restic-backups-home = {
    path = [
      pkgs.rclone
      pkgs.openssh
      pkgs.systemd
      pkgs.gnugrep
      pkgs.gnused
      pkgs.coreutils
    ];
    wants = [ "restic-backups-home-progress.service" ];
    after = [ "restic-backups-home-progress.service" ];
    # "+" = run as root even though the unit User= is mitac (system trees are 0600/0700).
    serviceConfig = {
      ExecStartPre = [ "+${stageSystemState}" ];
      ExecStopPost = [ "+${clearSystemStaging}" ];
    };
  };

  # Runs as root so journalctl can read the system unit; notify-send still
  # targets mitac's session bus (see resticNotify).
  systemd.services.restic-backups-home-progress = {
    description = "Desktop progress notifications for restic home backup";
    partOf = [ backupUnit ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${progressNotifyScript}";
    };
  };
}
