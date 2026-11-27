# AGENTS.md

## What this repo is

NixOS flake for `mitac`: greetd/tuigreet + Hyprland (UWSM, default) & optional Niri desktop, two hosts — `.#chromebook` (ASUS CX5500FE "delbin") and `.#vaio` (Intel 8th+ gen); `.#mitac` is a legacy alias of chromebook. Not an app/server: "running" it means nix eval/build. Real application is `sudo nixos-rebuild switch --flake .#chromebook|.#vaio` on the target machine (see `README.md`). No CI, no test suite, no `opencode.json`.

Nix is on PATH and the daemon normally runs. If a `nix` command errors with `cannot connect to socket at '/nix/var/nix/daemon-socket/socket'`, start `nix-daemon` in the background and retry.

## Commands you'd otherwise guess wrong

- Fast sanity eval (all modules load): `nix eval .#nixosConfigurations.chromebook.config.networking.hostName` (same for `vaio`).
- **Never** `nix eval ...options...` (especially `options.home-manager.users`) — forces the whole options tree and stalls the machine. Use narrow `config.` paths or `rg` the module sources. If unavoidable, eval a leaf under `nice -n 19 ionice -c3` (interactive helper: `nix-eval-low`).
- Build a declared package: `nix build .#nixosConfigurations.vaio.config.home-manager.users.mitac.programs.neovim.finalPackage`.
- Full checks (only when `hardware-configuration.nix` matches the target): `nix flake check`, `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
- Format check (repo follows nixfmt RFC style): `nix run nixpkgs#nixfmt -- --check flake.nix hosts/*/*.nix modules/nixos/*.nix modules/nixos/*/*.nix home/*.nix` — drop `--check` to reformat in place.
- Don't run a full `nix build` just to "verify" a finished config change — the user's `rebuild` does that.

## Non-obvious wiring

- `rebuild`, `generations`, `secrets`, `flake-update`, `flake-update-cursor` are **Nix-store wrapper commands** defined in `home/shell.nix` / `home/flake-tools.nix`, not the files in `scripts/`. Editing `scripts/` changes nothing until `rebuild`.
- They act on `repoPath` from `lib/machine.nix` (default `/home/mitac/MySettings`, overridable via `mitac.repoPath`). The `rebuild` target comes from `flakeTarget` / `mitac.flakeHost` (fallback `chromebook`); `rebuild vaio` overrides it.
- `flake-update` runs `nix flake update` (all inputs) **and** rewrites pinned `.deb` URLs + custom package versions in `flake.nix` (UniClipboard / Grok Bot / Meltype / Antigravity / wol-pc). Don't substitute a bare `nix flake update` — it skips the version sync. `flake-update-cursor` moves only `nixpkgs-cursor`.
- Home Manager sets `backupFileExtension = "backup"` — colliding files are renamed instead of failing activation.

## Gotchas

- `hosts/vaio/hardware-configuration.nix` is a `lib.mkDefault` placeholder; regenerate on the target machine before switching. `hosts/chromebook/hardware-configuration.nix` is the real delbin config.
- Chromebook ALSA UCM merge (`modules/nixos/chromebook/audio.nix`) copies from read-only `/nix/store` inputs with `cp -a --no-preserve=mode` so the tree stays writable.
- Graphify is optional: `nix run nixpkgs#uv -- tool install graphifyy`, then `export PATH="$HOME/.local/bin:$PATH"`; `graphify update .` after structural edits (`graphify-out/` is gitignored). Use it for architecture/refactor questions, not as a prelude to every read.

## Workflow / rules

- Work and commit only on `main`; never develop on the `chromebook` branch.
- OpenCode does **not** auto-load `.cursor/rules/*.mdc`. At the start of work, read every `alwaysApply: true` rule (plus glob-scoped ones when editing matching files). The ones that change behavior most:
  - `generation-tags` — bump `system.nixos.tags` in `modules/nixos/release.nix` on meaningful config changes (skip docs/rules/cheatsheet-only edits; no `gen/NN-*` tags).
  - `commit-before-next-unit` / `committing-changes-with-git` — commit finished verified units; git safety (no force-push, no `--no-verify`, no config edits, HEREDOC commit messages, ask before push).
  - `nix-eval-avoid-options` — see above.
  - `cheatsheet-expand` — for reusable answers, also update `cheatsheetEntries` in `home/hyprland.nix`.
  - `backup-staging` — prefer declarative Nix/agenix (`secrets/*.age`); only machine-specific non-secret state goes in `modules/nixos/backup.nix` (`systemStagingSources`), with `scripts/restore-on-nixos.sh` + `README.md` updated too.
  - `declarative-agent-skills` — manage AI agent skills/plugins declaratively via `flake.nix` (`flake = false` inputs) + `home/agent-skills.nix` instead of imperative-only installs.
  - `avoid-premature-workarounds`, `investigate-before-conclude`, `prefer-native-tools`, `communication-style`, `skip-build-on-completion` — investigate root causes, read logs before concluding, prefer native CLI over ad-hoc Python, answer concisely.
- **Subagent cost optimization (Antigravity / T3 Code)**:
  - Actively delegate broad codebase exploration, multi-file research, log inspection, and independent/routine subtasks to subagents to save main-model cost. Keep trivial one-step lookups or small edits direct.
  - When delegating from Antigravity in T3 Code, use `delegate_task` with `target: { providerInstanceId: "opencode", model: "opencode/hy4-flash-free" }` instead of native `invoke_subagent` (call `orchestrator_capabilities` once per thread before the first `delegate_task`).
