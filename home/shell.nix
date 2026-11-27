# Bash aliases and helpers shared across all greetd sessions.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # One option (default lib/machine.nix + flakeTarget). Works from any cwd,
  # not only inside the checkout. The flake-update* commands are store paths.
  repoPath = config.mitac.repoPath;
  defaultHost = config.mitac.flakeHost;
  hiraginoDir = (import ../lib/machine.nix).hiraginoDir;
in
{
  programs.bash = {
    enable = true;
    historyFile = "${config.xdg.stateHome}/bash/history";
    # -1 = unlimited (bash: non-negative caps; negative / unset = no limit).
    historySize = -1;
    historyFileSize = -1;
    shellAliases = {
      ll = "ls -la";
      bcat = "bat";
      generations = "nixos-rebuild list-generations";
      # .deb URLs + nix flake update of every input except nixpkgs-cursor.
      flake-update = lib.getExe config.mitac.scripts.flakeUpdate;
      # nixpkgs-cursor only (code-cursor / cursor-cli), same rev as nixpkgs otherwise.
      flake-update-cursor = lib.getExe config.mitac.scripts.flakeUpdateCursor;
      # Waybar upd indicator: compare pinned debs + GitHub flake tips (no mutate).
      flake-update-check = lib.getExe config.mitac.scripts.flakeUpdateCheck;
      # Emergency: mute speakers/sink and restart audio stack (PulseAudio on Chromebook, PipeWire on VAIO).
      audio-panic = "if command -v chromebook-speaker-levels >/dev/null 2>&1; then chromebook-speaker-levels mute || true; else ${pkgs.pulseaudio}/bin/pactl set-sink-mute @DEFAULT_SINK@ 1 2>/dev/null || true; fi; for u in pulseaudio.service pipewire.service pipewire-pulse.service wireplumber.service; do systemctl --user restart $u 2>/dev/null || true; done";
      # When no display is up, gui wraps with cage; otherwise passthrough.
      vivaldi = "gui vivaldi";
      cursor = "gui cursor";
      code-cursor = "gui cursor";
      # Official Cursor Agent CLI name (`cursor-cli` ships cursor-agent only).
      agent = "cursor-agent";
      chatgpt = "gui chatgpt";
      grok-bot = "gui grok-bot";
      orca-ide = "gui orca-ide";
      onlyoffice-desktopeditors = "gui onlyoffice-desktopeditors";
      jquake = "gui JQuake";
      parsec = "gui parsecd";
      bottles = "gui bottles";
      trayscale = "gui trayscale";
    };
    # Top ~10 lines: command output; bottom: btop. Usage: runbtop <cmd> [args...]
    # rebuild: sudo on this TTY first; then human-readable logs + nom ETA while building.
    initExtra = ''
      runbtop() {
        if [ "$#" -eq 0 ]; then
          printf 'usage: runbtop <command> [args...]\n' >&2
          return 1
        fi
        tmux new-session \; \
          send-keys -- "$(printf '%q ' "$@")" C-m \; \
          split-window -v -- btop \; \
          select-pane -t '{top}' \; \
          resize-pane -y 10 \; \
          select-pane -t '{bottom}'
      }

      rebuild() {
        local defaultTarget=${lib.escapeShellArg defaultHost}
        local restoreBin=${lib.escapeShellArg (lib.getExe config.mitac.scripts.restoreOnNixos)}
        local target=""
        local doRestore=0
        local doReboot=0
        local -a restoreArgs=()

        while [ "$#" -gt 0 ]; do
          case "$1" in
            -h|--help)
              cat <<'EOF'
      使い方:
        rebuild [TARGET]
        rebuild [TARGET] --restore [--from HOST | --repo REPO] [--new-device] [--reboot]
        rebuild --restore-status
        rebuild --restore-cancel

      オプション:
        --restore          バックアップを事前ステージング・検証し、rebuild 後に次回 OS 再起動時の自動復元を予約
        --from HOST        復元元ホスト指定（例: --from vaio / --from chromebook）
        --repo REPO        restic リポジトリ URI を明示指定
        --new-device       新端末・再構築向けに端末 ID / トークン / Bluetooth / WARP を初期化して復元
        --reboot           --restore の予約と rebuild 完了後に自動で sudo reboot
        --restore-status   次回起動時の復元予約状態と直近適用結果を表示
        --restore-cancel   予約中の復元とステージ領域を削除してキャンセル
      EOF
              return 0
              ;;
            --restore)
              doRestore=1
              shift
              ;;
            --reboot)
              doReboot=1
              shift
              ;;
            --restore-status)
              "$restoreBin" --restore-status
              return $?
              ;;
            --restore-cancel)
              "$restoreBin" --cancel-staged
              return $?
              ;;
            --new-device)
              restoreArgs+=(--new-device)
              shift
              ;;
            --from|--repo)
              if [ "$#" -lt 2 ]; then
                printf 'rebuild: %s には値が必要です。\n' "$1" >&2
                return 2
              fi
              restoreArgs+=("$1" "$2")
              shift 2
              ;;
            --from=*|--repo=*)
              restoreArgs+=("$1")
              shift
              ;;
            -*)
              printf 'rebuild: 不明なオプションです: %s（rebuild --help を確認）\n' "$1" >&2
              return 2
              ;;
            *)
              if [ -n "$target" ]; then
                printf 'rebuild: ターゲットは 1 つだけ指定してください: %s\n' "$1" >&2
                return 2
              fi
              target="$1"
              shift
              ;;
          esac
        done

        if [ "$doRestore" -eq 0 ] && [ "''${#restoreArgs[@]}" -gt 0 ]; then
          printf 'rebuild: --from / --repo / --new-device は --restore と併用してください。\n' >&2
          return 2
        fi
        if [ "$doRestore" -eq 0 ] && [ "$doReboot" -eq 1 ]; then
          printf 'rebuild: --reboot は --restore と併用してください。\n' >&2
          return 2
        fi

        target="''${target:-$defaultTarget}"
        local flakeUri=${lib.escapeShellArg repoPath}"#$target"
        # Ask for the password on the real TTY (|& nom swallows/hides the prompt).
        sudo -v || return $?

        if [ "$doRestore" -eq 1 ]; then
          "$restoreBin" --stage-for-boot --defer-commit "''${restoreArgs[@]}" || return $?
          # Refresh sudo timestamp in case download/verify took longer than sudo timeout.
          sudo -v || return $?
        fi

        # Resolve nom at call time (PATH) so GC of an old store path cannot break
        # a long-lived shell that still has this function body.
        local nom
        nom="$(command -v nom)" || {
          printf 'rebuild: nom not on PATH (nix-output-monitor)\n' >&2
          return 127
        }
        # Human-readable mode: pass-through eval/activation; ETA only while building.
        # pathExists of the Hiragino directory is false in pure eval. Pass
        # --impure only when the OTFs are actually on disk.
        local -a rebuildArgs=(--flake "$flakeUri")
        if [ -d ${lib.escapeShellArg hiraginoDir} ]; then
          rebuildArgs+=(--impure)
        fi
        sudo nixos-rebuild switch "''${rebuildArgs[@]}" |& "$nom"
        local rc="''${PIPESTATUS[0]}"
        # 終了後に SGR と端末のパレット・動的色上書きを既定へ戻す (OSC 104 = palette,
        # OSC 110/111/112 = fg/bg/cursor)。根本原因 (colorshell の pywal16 が /dev/pts/* へ
        # OSC 4/10/11 を流し込む問題) は pkgs/colorshell/default.nix の `wal -s` で抑止済み。
        if [ -t 1 ]; then
          printf '\033[0m\033]104\033\\\033]110\033\\\033]111\033\\\033]112\033\\'
        fi
        if [ "$doRestore" -eq 1 ]; then
          if [ "$rc" -eq 0 ]; then
            sudo mv -f /var/lib/mitac-restore/pending.staging.json /var/lib/mitac-restore/pending.json || return $?
            printf '\n次回 OS 再起動時のデータ復元を予約しました（mitac-restore-apply.service）。\n'
            printf '  状態確認: rebuild --restore-status\n'
            printf '  キャンセル: rebuild --restore-cancel\n'
            if [ "$doReboot" -eq 1 ]; then
              printf '再起動します...\n'
              sudo reboot
            else
              printf '準備ができたら `sudo reboot` を実行してください。\n'
            fi
          else
            printf '\n警告: nixos-rebuild が失敗したため、次回起動時の復元予約は確定していません。\n' >&2
            printf '残骸を削除する場合は `rebuild --restore-cancel` を実行してください。\n' >&2
          fi
        fi
        return "$rc"
      }

      # Low-priority nix eval (CPU + IO). Prefer narrow config.… paths over options.…
      nix-eval-low() {
        nice -n 19 ionice -c3 nix eval "$@"
      }

      # Accept home LAN routes via Tailscale only when away. On the same
      # 192.168.1.0/24, --accept-routes steers LAN through galleria and breaks Wi-Fi.
      ts-home-routes() {
        case "''${1:-}" in
          on)
            tailscale set --accept-routes=true || return $?
            printf 'accept-routes=on（外出先向け。帰宅後は ts-home-routes off）\n'
            ;;
          off)
            tailscale set --accept-routes=false || return $?
            printf 'accept-routes=off（自宅 LAN 直通）\n'
            ;;
          status|"")
            if tailscale debug prefs 2>/dev/null | grep -q '"RouteAll": true'; then
              printf 'accept-routes=on\n'
            else
              printf 'accept-routes=off\n'
            fi
            ;;
          *)
            printf 'usage: ts-home-routes on|off|status\n' >&2
            return 2
            ;;
        esac
      }

      # Launch Parsec after clearing WARP and checking Tailscale to the host.
      # Host (Windows) must set app_custom_address to its Tailscale IP — see README.
      parsec-ts() {
        local host="''${1:-galleria-mitac}"
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
        printf 'Tailscale ping %s …\n' "$host"
        if ! tailscale ping -c 2 -timeout 5s "$host"; then
          printf '到達できません。ホストの電源・Tailscale・WOL を確認してください。\n' >&2
          return 1
        fi
        gui parsecd
      }
    '';
  };

  # Structured SQLite shell history (Ctrl+R search + `atuin stats`).
  # Data stays under XDG via ATUIN_DATA_DIR in home/programs.nix.
  programs.atuin = {
    enable = true;
    enableBashIntegration = true;
    # Keep Up Arrow on plain bash history and avoid hijacking `?` for Atuin AI.
    flags = [
      "--disable-up-arrow"
      "--disable-ai"
    ];
    # Local-only by default (no external sync/update traffic); redact common secrets.
    settings = {
      auto_sync = false;
      update_check = false;
      secrets_filter = true;
    };
  };
}
