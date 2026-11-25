---
name: ops-advisor
description: Use when analyzing operation history to propose shortcuts, aliases, or tools.
version: 1.0.0
license: MIT
---

# Ops Advisor — Operation History Efficiency Review

Analyze the user's real local operation history (ActivityWatch, WhatPulse, Bash, Vivaldi/Firefox, Rofi, GTK recently-used, Meltype, AI agents, and opt-in clipboard) against their current NixOS/Hyprland config (`~/MySettings`) to propose concrete, high-impact shortcuts, aliases, and tools.

## Procedure

1. **Collect sanitized usage data (shell-only)**
   - Prefer the Nix-wrapped command on PATH (`ops-advisor-collect`, which bundles `sqlite3`, `jq`, `curl`, `rg`, `awk`, `sed`):
     ```bash
     ops-advisor-collect --days 7
     ```
   - Use `--days N` when the user asks for another window (e.g. 14 or 30 days).
   - If `ops-advisor-collect` is not on PATH yet (before `rebuild`), run the bundled script directly — wrapping with `nix shell nixpkgs#sqlite -c` if `sqlite3` is missing:
     ```bash
     bash <skill-dir>/scripts/collect.sh --days 7
     # or when sqlite3 is not on PATH:
     nix shell nixpkgs#sqlite -c bash <skill-dir>/scripts/collect.sh --days 7
     ```
   - Never pass `--include-clipboard` unless the user explicitly asks to include clipboard history.
   - Never inspect raw browser/WhatPulse/clipboard DBs directly when `collect.sh` already summarizes and redacts them.

2. **Check coverage and prior feedback**
   - Review `sources.*.status`. Note any inactive/missing source briefly in one line (e.g., if `whatpulse.status == "not_found"`, remind once that starting `whatpulse` will unlock per-app click/key/combo/Backspace stats).
   - Check `feedback.adopted` and `feedback.dismissed` (from `~/.local/state/ops-advisor/feedback.json`) and skip proposing anything already adopted or dismissed unless the user asks to revisit it.
   - Check `current_config` (`cheatsheet`, `hypr_binds`, `shell_aliases`, `shell_functions`, `keyd_mappings`, `installed_tools`) so you never pitch an already-configured shortcut, alias, or installed tool as "new".

3. **Synthesize 3–5 concrete proposals**
   Focus on high-frequency friction backed by actual numbers in the JSON:
   - **Hyprland / keyd binds**:
     - Frequent app switches in `activitywatch.app_switch_pairs` -> dedicated workspace, scratchpad, or focus-toggle bind.
     - Frequent Rofi launches (`rofi.top_entries`) -> direct `Super+...` bind.
     - Already-configured binds in `current_config.cheatsheet` that are clearly unused -> label explicitly as **既存設定の活用**.
   - **In-app shortcuts** (especially from WhatPulse once active):
     - High `clicks_per_1k_keys` or `distance_m` in `whatpulse.input_per_app` -> target app's keyboard navigation shortcuts.
     - High Backspace / Arrow counts in `whatpulse.nav_edit_keys_per_app` -> word-delete (`Ctrl+W`/`Ctrl+BS`), jump motions, fuzzy search, or editor/browser vim bindings.
     - Rare modifier usage in `whatpulse.top_keycombos` -> specific missing chords for top apps.
   - **Shell aliases / functions / workflows**:
     - `bash_history.long_repeated_commands`, `top_commands`, and `repeated_sequences` -> aliases or functions in `~/MySettings/home/shell.nix`.
     - If `bash_history.has_timestamps == false`, consider proposing `HISTTIMEFORMAT` (or `atuin`) once if shell history granularity is limiting analysis.
   - **Tools / web workflows**:
     - Repeated `vivaldi.top_paths` / `typed_visits` -> Vivaldi quick commands/bookmark keywords, PWA (`vivaldi-pwa-desktop.nix`), or CLI alternative (`gh`, etc.).
     - Repeated `recently_used.top_directories` -> Yazi bookmarks, `zoxide`, or shell jump aliases.
     - Missing high-leverage tools not yet in `current_config.installed_tools`.

4. **Format each proposal clearly (default: Japanese unless user asks in English)**
   Limit to **3–5 proposals**, ordered by impact vs setup effort. Each proposal must include:
   - Stable kebab-case ID (e.g. `hypr-bind-vivaldi`, `bash-fn-git-sync`)
   - Category (`Hyprland/keyd` / `アプリ内ショートカット` / `Bash/CLI` / `ツール`) + tag (`新規` or `既存設定の活用`)
   - Concrete evidence from the JSON (counts, minutes, click/key ratio, switch count)
   - Ready-to-apply change (exact shortcut or Nix snippet targeting `~/MySettings/home/...` — verify no key collision in `current_config.hypr_binds` / `home/hyprland.nix` first)

5. **Save report and handle follow-up feedback**
   - Save the report to `${XDG_STATE_HOME:-$HOME/.local/state}/ops-advisor/reports/$(date +%Y-%m-%d).md` (`mkdir -p` with `chmod 700` on the state directory).
   - End by asking which proposal numbers/IDs the user wants to **apply** (`~/MySettings` edit) or **dismiss**.
   - When the user adopts or dismisses a proposal, record it in `${XDG_STATE_HOME:-$HOME/.local/state}/ops-advisor/feedback.json` using `jq` (never Python):
     ```bash
     state="${XDG_STATE_HOME:-$HOME/.local/state}/ops-advisor"
     fb="$state/feedback.json"
     mkdir -p "$state" && chmod 700 "$state"
     [ -f "$fb" ] || printf '{"adopted":[],"dismissed":[]}\n' >"$fb"
     tmp="$(mktemp)"
     jq --arg bucket "adopted" --arg id "<id>" --arg date "$(date +%Y-%m-%d)" --arg note "<note>" \
       '.[$bucket] = ((.[$bucket] // []) | map(select(.id != $id)) + [{id: $id, date: $date, note: $note}])' \
       "$fb" >"$tmp" && mv -f "$tmp" "$fb"
     ```
   - When applying a proposal to `~/MySettings`, follow repo conventions (`home/hyprland.nix` + `cheatsheetEntries`, `home/shell.nix`, `modules/nixos/release.nix`, `nixfmt --check`).

## Privacy & Safety Rules

- Transient SQLite copies stay in `~/.cache` (excluded from restic backups) and are deleted on exit by `collect.sh`.
- Never write raw history dumps into `~/.local/state/ops-advisor/` or into `~/MySettings`.
- Keep clipboard history off unless explicitly requested.
