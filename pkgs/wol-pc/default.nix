# Packaged Wake-on-LAN client/relay from github:mitac-31709/wol-pc.
# Keeps secrets out of the Nix store by reading WOL_PC_CONFIG or
# `/run/agenix/wol-pc-env`.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  makeWrapper,
  python3,
  bash,
  coreutils,
  curl,
  gnugrep,
  iputils,
  libnotify,
  openssh,
  rofi-prompt,
  sshpass,
  wakeonlan,
}:

stdenvNoCC.mkDerivation {
  pname = "wol-pc";
  version = "0-unstable-2025-10-01";

  src = fetchFromGitHub {
    owner = "mitac-31709";
    repo = "wol-pc";
    rev = "347902d845927901bde041f0486db668c0afdbe6";
    hash = "sha256-jXwkjkucdKPMvjcOxDG+fo2nskOmwvVEE7WFeCRfoWk=";
  };

  nativeBuildInputs = [
    makeWrapper
    python3
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    python3 - wake-pc.sh <<'PY'
    from pathlib import Path
    import sys

    p = Path(sys.argv[1])
    text = p.read_text(encoding="utf-8")
    old = """SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="''${SCRIPT_DIR}/config.env"

    if [[ ! -f "$CONFIG_FILE" ]]; then
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "WOL エラー" "config.env がありません。\\nconfig.example.env をコピーして設定してください。"
      fi
      echo "エラー: $CONFIG_FILE が見つかりません" >&2
      echo "  cp ''${SCRIPT_DIR}/config.example.env ''${CONFIG_FILE}" >&2
      exit 2
    fi"""
    new = """CONFIG_FILE="''${WOL_PC_CONFIG:-/run/agenix/wol-pc-env}"

    if [[ -z "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "WOL エラー" "/run/agenix/wol-pc-env が見つかりません。\\nsecrets import-wol && rebuild を実行してください。"
      fi
      echo "エラー: WOL 設定ファイルが見つかりません (/run/agenix/wol-pc-env または WOL_PC_CONFIG)" >&2
      exit 2
    fi"""
    if old not in text:
        raise SystemExit("expected config header block not found in wake-pc.sh")
    text = text.replace(old, new, 1)

    old_prompt = """prompt_ssh_password() {
      if command -v zenity >/dev/null 2>&1; then
        zenity --password --title="SSH パスワード" \\
          --text="''${SSH_USER}@''${WOL_RELAY_HOST} のパスワードを入力"
        return
      fi

      if command -v kdialog >/dev/null 2>&1; then
        kdialog --password "SSH パスワード (''${SSH_USER}@''${WOL_RELAY_HOST})"
        return
      fi

      if [[ -t 0 ]]; then
        read -r -s -p "SSH パスワード (''${SSH_USER}@''${WOL_RELAY_HOST}): " password
        echo >&2
        printf '%s' "$password"
        return
      fi

      echo "パスワード入力 UI (zenity / kdialog) が見つかりません" >&2
      return 1
    }"""
    new_prompt = """prompt_ssh_password() {
      if command -v rofi-askpass >/dev/null 2>&1; then
        rofi-askpass --title "SSH パスワード" \\
          "''${SSH_USER}@''${WOL_RELAY_HOST} のパスワードを入力"
        return
      fi

      if [[ -t 0 ]]; then
        read -r -s -p "SSH パスワード (''${SSH_USER}@''${WOL_RELAY_HOST}): " password
        echo >&2
        printf '%s' "$password"
        return
      fi

      echo "パスワード入力 UI (rofi-askpass) が見つかりません" >&2
      return 1
    }"""
    if old_prompt not in text:
        raise SystemExit("expected prompt_ssh_password block not found in wake-pc.sh")
    p.write_text(text.replace(old_prompt, new_prompt, 1), encoding="utf-8")
    PY

    install -Dm755 wake-pc.sh "$out/bin/wake-pc"
    install -Dm755 wake-relay.sh "$out/bin/wake-pc-relay"
    install -Dm644 config.example.env "$out/share/wol-pc/config.example.env"
    install -Dm644 Wake-PC.desktop "$out/share/applications/wake-pc.desktop"

    substituteInPlace "$out/share/applications/wake-pc.desktop" \
      --replace-fail '__SCRIPT_DIR__/wake-pc.sh' 'wake-pc'

    patchShebangs "$out/bin"

    wrapProgram "$out/bin/wake-pc" \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          curl
          gnugrep
          iputils
          libnotify
          openssh
          rofi-prompt
          sshpass
        ]
      }

    wrapProgram "$out/bin/wake-pc-relay" \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          iputils
          wakeonlan
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "Wake-on-LAN SSH relay client and launcher";
    homepage = "https://github.com/mitac-31709/wol-pc";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "wake-pc";
  };
}
