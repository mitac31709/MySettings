# Random session startup sound: Windows / Mac / GameCube / Wii / Wii Sports presets,
# repo/local audio pool, per-sound/global toggles, and Waybar/Rofi tray management.
{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:

let
  repoPath = config.mitac.repoPath;
  isPipewirePulse = osConfig != null && (osConfig.services.pipewire.pulse.enable or false);
  audioServiceAfter =
    if isPipewirePulse then
      [
        "pipewire-pulse.service"
        "wireplumber.service"
      ]
    else
      [ "pulseaudio.service" ];
  audioServiceRequires =
    if isPipewirePulse then [ "pipewire-pulse.service" ] else [ "pulseaudio.service" ];

  audioExtensions = [
    "wav"
    "mp3"
    "ogg"
    "oga"
    "opus"
    "flac"
    "m4a"
    "aac"
    "wma"
    "aiff"
    "aif"
    "webm"
    "mka"
  ];

  isAudioFile = name: lib.any (ext: lib.hasSuffix ".${ext}" (lib.toLower name)) audioExtensions;

  findAudioExpr = lib.concatStringsSep " -o " (map (ext: "-iname '*.${ext}'") audioExtensions);

  wiiBiosSfxZip = pkgs.fetchurl {
    url = "https://archive.org/download/xbox-system-bios-xbox-menu-sounds/Wii%20-%20System%20BIOS%20-%20Sound%20Effects.zip";
    name = "wii-system-bios-sfx.zip";
    hash = "sha256-Vk5AMM5D9JPSfofhVnddF/iK2ySbGSF7J2WI4Xf45Ow=";
  };

  wiiStartupWav =
    pkgs.runCommand "wii-startup.wav"
      {
        nativeBuildInputs = [ pkgs.unzip ];
      }
      ''
        unzip -p ${wiiBiosSfxZip} "Wii BIOS/WII-START.wav" >"$out"
        test -s "$out"
      '';

  # Classic Windows, Mac, GameCube, Nintendo Wii, and Wii Sports startup cues.
  # Official Media/Windows Startup.wav in Vista/7/11 is often a ~0.2s stub; these are the real cues.
  presetSounds = {
    "windows-3.1.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Windows%203.1%20-%20Boot.wav";
      name = "windows-3.1-startup.wav";
      hash = "sha256-BysBe0A9D3lK5wY4G6Pw5PL2M7tYHEj7qKr3x1QYvds=";
    };
    "windows-95.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Windows%2095%20-%20Boot.wav";
      name = "windows-95-startup.wav";
      hash = "sha256-RPIRSiNDWZoN+VBOWUPaI5sKUtIM9wU1g3w38p3evuA=";
    };
    "windows-98.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Windows%2098%20-%20Boot.wav";
      name = "windows-98-startup.wav";
      hash = "sha256-3k2haDLckHG7SikPBqvLSe0/dUSv14vYWfcNs48xQso=";
    };
    "windows-2000.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Windows%202000%20%26%20Millenium%20-%20Boot.wav";
      name = "windows-2000-startup.wav";
      hash = "sha256-+hXytMs7RbOPMVsvaAUWdsbCGoglmiZgoP41ND3mDiY=";
    };
    "windows-xp.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/windowsxpstartup_201910/Windows%20XP%20Startup.wav";
      name = "windows-xp-startup.wav";
      hash = "sha256-j4Weu5AkcDbO0R24VISKvhQ03D/9+leV98XwbbmkI9U=";
    };
    "windows-7.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/10-.-wav/Vista%20.WAV.wav";
      name = "windows-7-startup.wav";
      hash = "sha256-fOaAm7YsloolLoknFqr1Tqh81p9gFkq+T17LFwRg8vM=";
    };
    "windows-11.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/10-.-wav/11%20.WAV.wav";
      name = "windows-11-startup.wav";
      hash = "sha256-rnugG3J4qiXJ5RCm9YkAzMzFFEdC3+ueZPXXz1PQib0=";
    };
    "mac.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Mac%20OS%209%20-%20Boot.wav";
      name = "mac-startup.wav";
      hash = "sha256-O6DKnuCvK/zxjvjH+3HCfCz5EXeWaJzD3hCgtN63iFI=";
    };
    "gamecube.wav" = pkgs.fetchurl {
      url = "https://archive.org/download/Boot_Sounds_Compilation/Nintendo%20Gamecube%20-%20Boot.wav";
      name = "gamecube-startup.wav";
      hash = "sha256-31iXp1Hb/fT6JnMT3dtQG9MXtsMvxSQMHlkizYW+ags=";
    };
    "wii.wav" = wiiStartupWav;
    "wii-sports.flac" = pkgs.fetchurl {
      url = "https://archive.org/download/wii-sports_202605/Nintendo%20Co.%2C%20Ltd.%20-%20Wii%20Sports%20-%20Track%20%2801%29.flac";
      name = "wii-sports-startup.flac";
      hash = "sha256-ZNbcq7AFHV9niANu4kdih0WLuYxPA6R+Y/0fBcrTgBQ=";
    };
  };

  repoSoundsDir = ./startup-sounds;
  repoSounds =
    if builtins.pathExists repoSoundsDir then
      lib.mapAttrs (name: _: repoSoundsDir + "/${name}") (
        lib.filterAttrs (name: type: (type == "regular" || type == "symlink") && isAudioFile name) (
          builtins.readDir repoSoundsDir
        )
      )
    else
      { };

  nixStartupSounds = pkgs.linkFarm "nix-startup-sounds" (
    lib.mapAttrsToList (name: path: { inherit name path; }) (presetSounds // repoSounds)
  );

  rofiBin = lib.getExe config.programs.rofi.package;
  nvimBin = lib.getExe config.programs.neovim.finalPackage;
  ghosttyBin = lib.getExe pkgs.ghostty;
  yaziBin = lib.getExe pkgs.yazi;

  startupSoundBin = pkgs.writeShellApplication {
    name = "startup-sound";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.libnotify
      pkgs.mpv
      pkgs.pulseaudio
      pkgs.hyprland
      pkgs.systemd
    ];
    text = ''
      self_bin="$(realpath "$0")"
      nix_dir=${lib.escapeShellArg nixStartupSounds}
      repo_cfg=${lib.escapeShellArg "${repoPath}/home/startup-sound.nix"}
      local_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/startup-sounds"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/startup-sound"
      state_file="$state_dir/last"
      disabled_marker="$state_dir/disabled"
      muted_file="$state_dir/disabled-sounds"
      pid_file="''${XDG_RUNTIME_DIR:-/tmp}/startup-sound-player.pid"

      usage() {
        cat <<'EOF'
      Usage: startup-sound [OPTION | FILE | KEY | NAME]

      Play a random startup sound from Nix-declared presets (including repo
      home/startup-sounds/) and local files under ~/.local/share/startup-sounds/.

      Options:
        --auto               Respect global ON/OFF (used by systemd at login)
        --play               Play one random enabled sound now
        --play-bg            Play one random enabled sound in background
        --stop               Stop currently playing startup sound
        -l, --list           List all sounds ([ON/OFF], source, * = last played)
        --toggle             Toggle global startup sound ON/OFF
        --toggle-and-notify  Toggle global ON/OFF and send desktop notification
        --enable             Enable global startup sound
        --disable            Disable global startup sound
        --waybar             Print JSON status for Waybar custom/startup-sound
        --menu               Open interactive Rofi tray menu (list/edit/toggle/play)
        -h, --help           Show this help message
      EOF
      }

      refresh_waybar() {
        systemctl --user kill --kill-who=main --signal=RTMIN+13 waybar.service >/dev/null 2>&1 || true
        systemctl --user kill --kill-who=main --signal=RTMIN+13 waybar-hypr-status.service >/dev/null 2>&1 || true
      }

      notify() {
        notify-send -a "startup-sound" "$@" >/dev/null 2>&1 || true
      }

      is_global_enabled() {
        [ ! -e "$disabled_marker" ]
      }

      is_sound_enabled() {
        local key="$1"
        if [ -r "$muted_file" ] && grep -Fxq -- "$key" "$muted_file"; then
          return 1
        fi
        return 0
      }

      set_sound_enabled() {
        local key="$1"
        local want="$2"
        mkdir -p "$state_dir"
        local tmp
        tmp="$(mktemp "$state_dir/.disabled-sounds.XXXXXX")"
        if [ -r "$muted_file" ]; then
          grep -Fxv -- "$key" "$muted_file" >"$tmp" || true
        fi
        if [ "$want" = "off" ]; then
          printf '%s\n' "$key" >>"$tmp"
        fi
        mv -f "$tmp" "$muted_file"
      }

      migrate_sound_key() {
        local old_key="$1"
        local new_key="$2"
        if [ -r "$muted_file" ] && grep -Fxq -- "$old_key" "$muted_file"; then
          set_sound_enabled "$old_key" on
          set_sound_enabled "$new_key" off
        fi
        if [ -r "$state_file" ]; then
          local last
          IFS= read -r last <"$state_file" || true
          if [ "$last" = "$old_key" ]; then
            record_last "$new_key"
          fi
        fi
      }

      collect_candidates() {
        candidates=()
        cand_keys=()
        cand_sources=()
        cand_names=()
        local f base rel
        if [ -d "$nix_dir" ]; then
          while IFS= read -r -d "" f; do
            base="$(basename "$f")"
            candidates+=("$f")
            cand_keys+=("nix:$base")
            cand_sources+=("nix")
            cand_names+=("$base")
          done < <((find -L "$nix_dir" -maxdepth 1 -type f \( ${findAudioExpr} \) -print0 || true) | LC_ALL=C sort -z)
        fi
        if [ -d "$local_dir" ]; then
          while IFS= read -r -d "" f; do
            rel="''${f#"$local_dir/"}"
            candidates+=("$f")
            cand_keys+=("local:$rel")
            cand_sources+=("local")
            cand_names+=("$rel")
          done < <((find "$local_dir" -path "$local_dir/nix" -prune -o -xtype f \( ${findAudioExpr} \) -print0 || true) | LC_ALL=C sort -z)
        fi
      }

      is_playing() {
        if [ ! -r "$pid_file" ]; then
          return 1
        fi
        local pid
        IFS= read -r pid <"$pid_file" || true
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
          return 1
        fi
        local comm
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        case "$comm" in
          paplay | mpv | startup-sound | .startup-sound*) return 0 ;;
          *) return 1 ;;
        esac
      }

      stop_playback() {
        if [ -r "$pid_file" ]; then
          local pid
          IFS= read -r pid <"$pid_file" || true
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local comm
            comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
            case "$comm" in
              paplay | mpv | startup-sound | .startup-sound*)
                kill "$pid" 2>/dev/null || true
                ;;
            esac
          fi
          rm -f "$pid_file" 2>/dev/null || true
        fi
      }

      record_last() {
        local key="$1"
        mkdir -p "$state_dir" 2>/dev/null || return 0
        printf '%s\n' "$key" >"$state_file" 2>/dev/null || true
      }

      play_file() {
        local file="$1"
        local ext="''${file##*.}"
        ext="''${ext,,}"
        stop_playback
        printf 'startup-sound: playing %s\n' "$file" >&2
        mkdir -p "$(dirname "$pid_file")" 2>/dev/null || true

        local child rc
        case "$ext" in
          wav | flac | ogg | oga | opus | aiff | aif)
            paplay "$file" &
            child=$!
            printf '%s\n' "$child" >"$pid_file" 2>/dev/null || true
            rc=0
            wait "$child" || rc=$?
            rm -f "$pid_file" 2>/dev/null || true
            if [ "$rc" -eq 0 ] || [ "$rc" -ge 128 ]; then
              return 0
            fi
            ;;
        esac

        mpv \
          --no-config \
          --no-video \
          --no-terminal \
          --audio-display=no \
          --load-scripts=no \
          --ao=pulse \
          --really-quiet \
          "$file" &
        child=$!
        printf '%s\n' "$child" >"$pid_file" 2>/dev/null || true
        rc=0
        wait "$child" || rc=$?
        rm -f "$pid_file" 2>/dev/null || true
        if [ "$rc" -ge 128 ]; then
          return 0
        fi
        return "$rc"
      }

      play_bg() {
        stop_playback
        "$self_bin" "$@" </dev/null >/dev/null 2>&1 &
        for _ in 1 2 3 4 5 6; do
          if [ -r "$pid_file" ]; then
            break
          fi
          sleep 0.05
        done
      }

      play_random() {
        collect_candidates
        local i enabled_indices=()
        for ((i = 0; i < ''${#candidates[@]}; i++)); do
          if is_sound_enabled "''${cand_keys[$i]}"; then
            enabled_indices+=("$i")
          fi
        done

        if [ "''${#enabled_indices[@]}" -eq 0 ]; then
          printf 'startup-sound: no enabled audio files found in %s or %s\n' "$nix_dir" "$local_dir" >&2
          return 0
        fi

        local last=""
        if [ -r "$state_file" ]; then
          IFS= read -r last <"$state_file" || true
        fi

        local pool=()
        if [ "''${#enabled_indices[@]}" -ge 2 ] && [ -n "$last" ]; then
          for i in "''${enabled_indices[@]}"; do
            if [ "''${cand_keys[$i]}" != "$last" ]; then
              pool+=("$i")
            fi
          done
        fi
        if [ "''${#pool[@]}" -eq 0 ]; then
          pool=("''${enabled_indices[@]}")
        fi

        local pick_pos idx
        pick_pos="$(shuf -i "0-$(( ''${#pool[@]} - 1 ))" -n 1)"
        idx="''${pool[$pick_pos]}"
        record_last "''${cand_keys[$idx]}"
        refresh_waybar
        play_file "''${candidates[$idx]}"
      }

      list_candidates() {
        collect_candidates
        local global_str="ON"
        if ! is_global_enabled; then
          global_str="OFF"
        fi
        local last=""
        if [ -r "$state_file" ]; then
          IFS= read -r last <"$state_file" || true
        fi

        printf 'Global startup sound: %s\n' "$global_str"
        if [ "''${#candidates[@]}" -eq 0 ]; then
          printf 'No startup sounds found.\n'
          printf 'Local dir: %s\n' "$local_dir"
          return 0
        fi

        local i mark en_str
        for ((i = 0; i < ''${#candidates[@]}; i++)); do
          en_str="ON "
          if ! is_sound_enabled "''${cand_keys[$i]}"; then
            en_str="OFF"
          fi
          mark=" "
          if [ "''${cand_keys[$i]}" = "$last" ]; then
            mark="*"
          fi
          printf '%s [%s] [%-5s] %-22s %s\n' "$mark" "$en_str" "''${cand_sources[$i]}" "''${cand_names[$i]}" "''${candidates[$i]}"
        done
        printf '\nLocal dir: %s\n' "$local_dir"
      }

      waybar_status() {
        collect_candidates
        local total="''${#candidates[@]}"
        local enabled_count=0
        local local_count=0
        local i k
        for ((i = 0; i < total; i++)); do
          k="''${cand_keys[$i]}"
          if is_sound_enabled "$k"; then
            enabled_count=$((enabled_count + 1))
          fi
          case "$k" in
            local:*) local_count=$((local_count + 1)) ;;
          esac
        done
        local nix_count=$((total - local_count))
        local global_on=0
        if is_global_enabled; then
          global_on=1
        fi

        local last=""
        if [ -r "$state_file" ]; then
          IFS= read -r last <"$state_file" || true
        fi
        local last_label="なし"
        if [ -n "$last" ]; then
          last_label="''${last#*:}"
        fi

        local glyph cls state_str
        if [ "$global_on" -eq 0 ]; then
          glyph=$'\uf026'
          cls="disabled"
          state_str="OFF"
        elif [ "$enabled_count" -eq 0 ]; then
          glyph=$'\uf001'
          cls="empty"
          state_str="ON（有効な曲なし）"
        else
          glyph=$'\uf001'
          cls="enabled"
          state_str="ON"
        fi

        local tip
        tip="$(printf '起動音: %s\n有効: %d / %d曲（Nix %d / ローカル %d）\n前回: %s\n\n左クリック: 一覧・編集・ON/OFF・再生\n右クリック: 全体 ON/OFF\n中クリック: ランダム再生' \
          "$state_str" "$enabled_count" "$total" "$nix_count" "$local_count" "$last_label")"

        jq -cn --arg text "$glyph" --arg tooltip "$tip" --arg class "$cls" \
          '{text: $text, tooltip: $tooltip, class: $class}'
      }

      launch_in_session() {
        if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && ${pkgs.hyprland}/bin/hyprctl version >/dev/null 2>&1; then
          local cmd=""
          local arg lua_expr
          for arg in "$@"; do
            cmd+="''${cmd:+ }$(printf '%q' "$arg")"
          done
          lua_expr="$(jq -Rn --arg c "$cmd" '"hl.dsp.exec_cmd(" + ($c | tojson) + ")"')"
          ${pkgs.hyprland}/bin/hyprctl dispatch "$lua_expr" >/dev/null
        else
          "$@" </dev/null >/dev/null 2>&1 &
        fi
      }

      rofi_pick_index() {
        local prompt="$1"
        local mesg="$2"
        shift 2
        if [ -n "$mesg" ]; then
          printf '%s\n' "$@" | ${rofiBin} -dmenu -i -format i -p "$prompt" -mesg "$mesg" || true
        else
          printf '%s\n' "$@" | ${rofiBin} -dmenu -i -format i -p "$prompt" || true
        fi
      }

      add_local_sound_ui() {
        mkdir -p "$local_dir"
        local found=()
        local d
        for d in "$HOME/Downloads" "$HOME/Music" "$HOME/Desktop" "$HOME/Documents" "$HOME/Videos"; do
          if [ -d "$d" ]; then
            while IFS= read -r -d "" f; do
              found+=("$f")
            done < <((find "$d" -maxdepth 3 -xtype f \( ${findAudioExpr} \) -print0 || true) | LC_ALL=C sort -z)
          fi
        done

        local labels=("パスを手入力して追加…")
        local paths=("__manual__")
        for f in "''${found[@]}"; do
          labels+=("''${f/#"$HOME"/\~}")
          paths+=("$f")
        done

        local choice
        choice="$(rofi_pick_index "音声追加" "コピー先: ~/.local/share/startup-sounds/" "''${labels[@]}")"
        [ -n "$choice" ] || return 0

        local src=""
        if [ "''${paths[$choice]}" = "__manual__" ]; then
          src="$(${rofiBin} -dmenu -p "音声パス" -mesg "追加する音声ファイルのパスを入力（~ 可）" </dev/null || true)"
          [ -n "$src" ] || return 0
          case "$src" in
            [~]/*) src="$HOME/''${src#[~]/}" ;;
          esac
        else
          src="''${paths[$choice]}"
        fi

        if [ ! -f "$src" ]; then
          notify -u critical "起動音を追加できませんでした" "ファイルが見つかりません: $src"
          return 0
        fi

        local base stem ext dest n=1
        base="$(basename "$src")"
        dest="$local_dir/$base"
        if [ -e "$dest" ]; then
          stem="''${base%.*}"
          ext="''${base##*.}"
          while [ -e "$local_dir/$stem-$n.$ext" ]; do
            n=$((n + 1))
          done
          dest="$local_dir/$stem-$n.$ext"
        fi

        cp -f "$src" "$dest"
        chmod u+w "$dest" 2>/dev/null || true
        refresh_waybar
        notify "起動音を追加しました" "$(basename "$dest")"
      }

      rename_local_sound_ui() {
        local file="$1"
        local rel="$2"
        local old_key="local:$rel"
        local orig_base orig_ext new_name
        orig_base="$(basename "$file")"
        orig_ext="''${orig_base##*.}"

        new_name="$(printf '%s\n' "$rel" | ${rofiBin} -dmenu -p "名前変更" -mesg "現在: $rel（拡張子省略時は .$orig_ext を維持）" || true)"
        [ -n "$new_name" ] || return 1
        if [ "$new_name" = "$rel" ]; then
          return 1
        fi
        case "$new_name" in
          /* | *../* | */.. | ..)
            notify -u critical "無効なファイル名です" "$new_name"
            return 1
            ;;
        esac
        if [[ "$new_name" != *.* ]]; then
          new_name="$new_name.$orig_ext"
        fi

        local dest
        if [[ "$new_name" == */* ]]; then
          dest="$local_dir/$new_name"
        else
          dest="$(dirname "$file")/$new_name"
        fi
        if [ -e "$dest" ]; then
          notify -u critical "同名ファイルが既にあります" "''${dest#"$local_dir/"}"
          return 1
        fi

        mkdir -p "$(dirname "$dest")"
        mv "$file" "$dest"
        local new_rel="''${dest#"$local_dir/"}"
        migrate_sound_key "$old_key" "local:$new_rel"
        refresh_waybar
        notify "名前を変更しました" "$rel → $new_rel"
        return 0
      }

      copy_nix_to_local_ui() {
        local file="$1"
        local name="$2"
        mkdir -p "$local_dir"
        local dest="$local_dir/$name"
        if [ -e "$dest" ]; then
          local stem="''${name%.*}"
          local ext="''${name##*.}"
          local n=1
          while [ -e "$local_dir/$stem-$n.$ext" ]; do
            n=$((n + 1))
          done
          dest="$local_dir/$stem-$n.$ext"
        fi
        cp -f "$file" "$dest"
        chmod u+w "$dest" 2>/dev/null || true
        refresh_waybar
        notify "ローカルへ複製しました" "$(basename "$dest")"
      }

      item_menu() {
        local key="$1"
        while true; do
          collect_candidates
          local idx=-1 i
          for ((i = 0; i < ''${#cand_keys[@]}; i++)); do
            if [ "''${cand_keys[$i]}" = "$key" ]; then
              idx="$i"
              break
            fi
          done
          if [ "$idx" -lt 0 ]; then
            return 0
          fi

          local file="''${candidates[$idx]}"
          local src="''${cand_sources[$idx]}"
          local name="''${cand_names[$idx]}"
          local enabled=1
          local toggle_label="無効化する (OFF にする)"
          local state_label="ON"
          if ! is_sound_enabled "$key"; then
            enabled=0
            toggle_label="有効化する (ON にする)"
            state_label="OFF"
          fi

          local labels=("再生する")
          local actions=("play")
          if is_playing; then
            labels+=("再生停止")
            actions+=("stop")
          fi
          labels+=("$toggle_label")
          actions+=("toggle")

          if [ "$src" = "local" ]; then
            labels+=("名前を変更 (リネーム)" "Yazi でフォルダを開く" "削除する")
            actions+=("rename" "yazi" "delete")
          else
            labels+=("ローカルへ複製 (編集・リネーム用コピー)" "Nix 定義を編集 (home/startup-sound.nix)")
            actions+=("copy_local" "edit_nix")
          fi
          labels+=("戻る")
          actions+=("back")

          local choice
          choice="$(rofi_pick_index "$name" "種別: $src │ 状態: $state_label" "''${labels[@]}")"
          [ -n "$choice" ] || return 0

          case "''${actions[$choice]}" in
            play)
              play_bg --play "$key"
              refresh_waybar
              ;;
            stop)
              stop_playback
              ;;
            toggle)
              if [ "$enabled" -eq 1 ]; then
                set_sound_enabled "$key" off
              else
                set_sound_enabled "$key" on
              fi
              refresh_waybar
              ;;
            rename)
              if rename_local_sound_ui "$file" "$name"; then
                return 0
              fi
              ;;
            copy_local)
              copy_nix_to_local_ui "$file" "$name"
              ;;
            yazi)
              mkdir -p "$local_dir"
              launch_in_session "$ghosttyBin" -e "$yaziBin" "$file"
              exit 0
              ;;
            edit_nix)
              launch_in_session "$ghosttyBin" -e "$nvimBin" "$repo_cfg"
              exit 0
              ;;
            delete)
              local confirm
              confirm="$(rofi_pick_index "削除確認" "$name を削除しますか？" "いいえ（戻る）" "はい（削除する）")"
              if [ "$confirm" = "1" ]; then
                rm -f "$file"
                set_sound_enabled "$key" on
                refresh_waybar
                notify "起動音を削除しました" "$name"
                return 0
              fi
              ;;
            back)
              return 0
              ;;
          esac
        done
      }

      open_menu() {
        while true; do
          collect_candidates
          local total="''${#candidates[@]}"
          local enabled_count=0 i
          for ((i = 0; i < total; i++)); do
            if is_sound_enabled "''${cand_keys[$i]}"; then
              enabled_count=$((enabled_count + 1))
            fi
          done

          local global_str="ON"
          local global_next="OFF にする"
          if ! is_global_enabled; then
            global_str="OFF"
            global_next="ON にする"
          fi

          local last=""
          if [ -r "$state_file" ]; then
            IFS= read -r last <"$state_file" || true
          fi

          local labels=()
          local actions=()
          local action_keys=()

          labels+=("全体設定 │ ログイン時起動音: $global_str → $global_next")
          actions+=("toggle_global")
          action_keys+=("")

          labels+=("再生 │ ランダムに 1 曲テスト再生")
          actions+=("play_random")
          action_keys+=("")

          if is_playing; then
            labels+=("停止 │ いま鳴っている起動音を止める")
            actions+=("stop")
            action_keys+=("")
          fi

          labels+=("編集 │ 手元の音声ファイルを追加 (~/.local/share/startup-sounds)")
          actions+=("add_local")
          action_keys+=("")

          labels+=("編集 │ 起動音フォルダを Yazi で開く")
          actions+=("open_yazi")
          action_keys+=("")

          labels+=("編集 │ Nix 定義ファイルを Neovim で編集")
          actions+=("edit_nix")
          action_keys+=("")

          local en_str mark
          for ((i = 0; i < total; i++)); do
            en_str="ON "
            if ! is_sound_enabled "''${cand_keys[$i]}"; then
              en_str="OFF"
            fi
            mark=""
            if [ "''${cand_keys[$i]}" = "$last" ]; then
              mark=" ★前回"
            fi
            labels+=("[$en_str] [$(printf '%-5s' "''${cand_sources[$i]}")] ''${cand_names[$i]}$mark")
            actions+=("item")
            action_keys+=("''${cand_keys[$i]}")
          done

          local mesg
          mesg="$(printf '全体: %s │ 有効: %d / %d曲（クリックで再生・ON/OFF・編集）' "$global_str" "$enabled_count" "$total")"
          local choice
          choice="$(rofi_pick_index "起動音" "$mesg" "''${labels[@]}")"
          [ -n "$choice" ] || exit 0

          case "''${actions[$choice]}" in
            toggle_global)
              if is_global_enabled; then
                mkdir -p "$state_dir"
                : >"$disabled_marker"
              else
                rm -f "$disabled_marker"
              fi
              refresh_waybar
              ;;
            play_random)
              play_bg --play
              refresh_waybar
              ;;
            stop)
              stop_playback
              ;;
            add_local)
              add_local_sound_ui
              ;;
            open_yazi)
              mkdir -p "$local_dir"
              launch_in_session "$ghosttyBin" -e "$yaziBin" "$local_dir"
              exit 0
              ;;
            edit_nix)
              launch_in_session "$ghosttyBin" -e "$nvimBin" "$repo_cfg"
              exit 0
              ;;
            item)
              item_menu "''${action_keys[$choice]}"
              ;;
          esac
        done
      }

      ghosttyBin=${lib.escapeShellArg ghosttyBin}
      yaziBin=${lib.escapeShellArg yaziBin}
      nvimBin=${lib.escapeShellArg nvimBin}

      case "''${1:-}" in
        -h | --help)
          usage
          exit 0
          ;;
        -l | --list)
          list_candidates
          exit 0
          ;;
        --waybar)
          waybar_status
          exit 0
          ;;
        --menu)
          open_menu
          exit 0
          ;;
        --stop)
          stop_playback
          exit 0
          ;;
        --enable)
          rm -f "$disabled_marker"
          refresh_waybar
          exit 0
          ;;
        --disable)
          mkdir -p "$state_dir"
          : >"$disabled_marker"
          refresh_waybar
          exit 0
          ;;
        --toggle)
          if is_global_enabled; then
            mkdir -p "$state_dir"
            : >"$disabled_marker"
          else
            rm -f "$disabled_marker"
          fi
          refresh_waybar
          exit 0
          ;;
        --toggle-and-notify)
          if is_global_enabled; then
            mkdir -p "$state_dir"
            : >"$disabled_marker"
            notify "起動音を OFF にしました" "次回ログイン時から再生しません"
          else
            rm -f "$disabled_marker"
            notify "起動音を ON にしました" "次回ログイン時にランダム再生します"
          fi
          refresh_waybar
          exit 0
          ;;
        --auto)
          if ! is_global_enabled; then
            printf 'startup-sound: disabled, skipping\n' >&2
            exit 0
          fi
          play_random
          exit 0
          ;;
        "" | --play)
          if [ -n "''${2:-}" ]; then
            shift
          else
            play_random
            exit 0
          fi
          ;;
        --play-bg)
          shift
          play_bg --play "$@"
          exit 0
          ;;
        -*)
          printf 'startup-sound: unknown option: %s\n' "$1" >&2
          usage >&2
          exit 2
          ;;
      esac

      target="$1"
      if [ -f "$target" ]; then
        play_file "$target"
        exit 0
      fi
      collect_candidates
      for ((i = 0; i < ''${#candidates[@]}; i++)); do
        base="$(basename "''${candidates[$i]}")"
        if [ "''${cand_keys[$i]}" = "$target" ] || [ "''${cand_names[$i]}" = "$target" ] || [ "$base" = "$target" ] || [ "''${base%.*}" = "$target" ]; then
          record_last "''${cand_keys[$i]}"
          refresh_waybar
          play_file "''${candidates[$i]}"
          exit 0
        fi
      done
      printf 'startup-sound: sound not found: %s\n' "$target" >&2
      exit 1
    '';
  };
in
{
  mitac.scripts.startupSound = startupSoundBin;

  home.packages = [ startupSoundBin ];

  # Expose Nix-managed presets under ~/.local/share/startup-sounds/nix while
  # keeping ~/.local/share/startup-sounds/ writable for user-supplied files.
  xdg.dataFile."startup-sounds/nix".source = nixStartupSounds;

  systemd.user.services.startup-sound = {
    Unit = {
      Description = "Random session startup sound";
      After = audioServiceAfter ++ [ "graphical-session.target" ];
      Requires = audioServiceRequires;
    };
    Service = {
      Type = "oneshot";
      # Give sof-rt5682 / audio sink a short settle window after graphical login.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStart = "${lib.getExe startupSoundBin} --auto";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
