# Declarative secrets via agenix, unlocked by a single shared master age key
# kept in Bitwarden (`agenix-master-key`) and installed at `/etc/agenix/master.key`.
#
# Each secret under `../../secrets/*.age` is wired conditionally with
# `builtins.pathExists` so pure flake evaluation / CI always succeeds even before
# secrets are generated, and activates seamlessly once encrypted and git-tracked.
{
  config,
  inputs,
  lib,
  pkgs,
  flakeTarget ? "chromebook",
  ...
}:

let
  user = "mitac";
  secretsDir = ../../secrets;
  hasSecretFile = filename: builtins.pathExists (secretsDir + "/${filename}");
  lanMouseSecretFile = "lan-mouse-${flakeTarget}.pem.age";

  nmProfilesScript = pkgs.writeScript "nm-agenix-profiles" ''
    #!${pkgs.python3}/bin/python3
    import configparser
    import os
    import pathlib
    import re
    import subprocess
    import sys

    src = pathlib.Path(${
      builtins.toJSON (config.age.secrets."nm-connections".path or "/run/agenix/nm-connections")
    })
    if not src.is_file():
        print(f"nm-agenix-profiles: {src} not found, skipping", file=sys.stderr)
        sys.exit(0)

    raw = src.read_text(encoding="utf-8")
    sections = []
    current_name = None
    current_lines = []

    header_re = re.compile(r"^\s*#\s*===\s*(.+?)\s*===\s*$")
    for line in raw.splitlines(keepends=True):
        m = header_re.match(line)
        if m:
            if current_lines:
                sections.append((current_name, "".join(current_lines)))
            current_name = m.group(1)
            current_lines = []
        else:
            current_lines.append(line)

    if current_lines:
        sections.append((current_name, "".join(current_lines)))

    # Fallback if user wrote a single bare NetworkManager keyfile with no header marker.
    if not sections and "[connection]" in raw:
        sections = [("default", raw)]

    def clean_keyfile(text: str) -> str:
        # Keep profiles portable across Chromebook / VAIO NICs.
        out = []
        for line in text.splitlines(keepends=True):
            stripped = line.lstrip()
            if stripped.startswith(("interface-name=", "mac-address=")):
                continue
            out.append(line)
        content = "".join(out).strip()
        return (content + "\n") if content else ""

    def parse_keyfile_meta(text: str):
        cp = configparser.RawConfigParser(delimiters=("=",), interpolation=None)
        cp.optionxform = str
        cp.read_string(text)
        if not cp.has_section("connection"):
            return None
        ctype = cp.get("connection", "type", fallback="").strip().lower()
        uuid = cp.get("connection", "uuid", fallback="").strip()
        cid = cp.get("connection", "id", fallback="").strip()
        ssid = (
            cp.get("wifi", "ssid", fallback="").strip()
            or cp.get("802-11-wireless", "ssid", fallback="").strip()
        )
        return ctype, uuid, cid, ssid

    dest_dir = pathlib.Path("/run/NetworkManager/system-connections")
    dest_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(dest_dir, 0o700)

    for old in dest_dir.glob("agenix-*.nmconnection"):
        old.unlink()

    written = 0
    deployed_wifi_uuids = set()
    deployed_wifi_keys = set()
    for idx, (name, body) in enumerate(sections, start=1):
        cleaned = clean_keyfile(body)
        if not cleaned or "[connection]" not in cleaned:
            continue
        base = (name or f"profile-{idx}")
        if base.endswith(".nmconnection"):
            base = base[: -len(".nmconnection")]
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("_") or f"profile-{idx}"
        out_path = dest_dir / f"agenix-{idx:02d}-{slug}.nmconnection"
        tmp_path = dest_dir / f".agenix-{idx:02d}-{slug}.tmp"
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(cleaned)
            os.chown(tmp_path, 0, 0)
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, out_path)
            written += 1
            try:
                meta = parse_keyfile_meta(cleaned)
            except Exception:
                meta = None
            if meta is not None:
                ctype, uuid, cid, ssid = meta
                if ctype in ("wifi", "802-11-wireless"):
                    if uuid:
                        deployed_wifi_uuids.add(uuid)
                    if cid and ssid:
                        deployed_wifi_keys.add((cid, ssid))
        except Exception:
            if tmp_path.exists():
                tmp_path.unlink()
            raise

    removed_dups = 0
    local_dir = pathlib.Path("/etc/NetworkManager/system-connections")
    if local_dir.is_dir() and (deployed_wifi_uuids or deployed_wifi_keys):
        for local_file in sorted(local_dir.glob("*.nmconnection")):
            if not local_file.is_file() or local_file.is_symlink():
                continue
            try:
                meta = parse_keyfile_meta(local_file.read_text(encoding="utf-8"))
            except Exception:
                continue
            if meta is None:
                continue
            ctype, uuid, cid, ssid = meta
            if ctype not in ("wifi", "802-11-wireless"):
                continue
            if (uuid and uuid in deployed_wifi_uuids) or (cid and ssid and (cid, ssid) in deployed_wifi_keys):
                try:
                    local_file.unlink()
                    removed_dups += 1
                except OSError as exc:
                    print(f"nm-agenix-profiles: warning: could not remove duplicate {local_file}: {exc}", file=sys.stderr)

    subprocess.run(
        ["${pkgs.networkmanager}/bin/nmcli", "connection", "reload"],
        check=False,
    )
    print(f"nm-agenix-profiles: loaded {written} declarative profile(s) (removed {removed_dups} duplicate local Wi-Fi file(s))")
  '';

  nmSyncScript = pkgs.writeShellApplication {
    name = "nm-agenix-sync";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
      pkgs.python3
    ];
    text = ''
      exec python3 ${../../scripts/nm-agenix-sync.py} "$@"
    '';
  };
in
{
  age.identityPaths = [ "/etc/agenix/master.key" ];

  age.secrets = lib.mkMerge [
    (lib.optionalAttrs (hasSecretFile "restic-home-password.age") {
      "restic-home-password" = {
        file = secretsDir + "/restic-home-password.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "rclone-conf.age") {
      "rclone-conf" = {
        file = secretsDir + "/rclone-conf.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "nm-connections.age") {
      "nm-connections" = {
        file = secretsDir + "/nm-connections.age";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    })
    (lib.optionalAttrs (hasSecretFile "tailscale-authkey.age") {
      "tailscale-authkey" = {
        file = secretsDir + "/tailscale-authkey.age";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "id-wsl-builder.age") {
      # Separate root (nix-daemon) and user (ssh client) descriptors from one ciphertext.
      "id-wsl-builder-root" = {
        file = secretsDir + "/id-wsl-builder.age";
        owner = "root";
        group = "root";
        mode = "0400";
      };
      "id-wsl-builder-user" = {
        file = secretsDir + "/id-wsl-builder.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "id-ed25519.age") {
      "id-ed25519" = {
        file = secretsDir + "/id-ed25519.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "gh-hosts.yml.age") {
      "gh-hosts.yml" = {
        file = secretsDir + "/gh-hosts.yml.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "user-env.age") {
      "user-env" = {
        file = secretsDir + "/user-env.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "wol-pc-env.age") {
      "wol-pc-env" = {
        file = secretsDir + "/wol-pc-env.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "adbkey.age") {
      "adbkey" = {
        file = secretsDir + "/adbkey.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "opencode-service.json.age") {
      "opencode-service.json" = {
        file = secretsDir + "/opencode-service.json.age";
        owner = user;
        group = "users";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile lanMouseSecretFile) {
      # Share one per-host TLS identity across mitac and regreet's greeter so
      # peers see the same fingerprint at the login screen and in Hyprland.
      "lan-mouse-pem" = {
        file = secretsDir + "/${lanMouseSecretFile}";
        owner = user;
        group = "users";
        mode = "0400";
      };
      "lan-mouse-greeter-pem" = {
        file = secretsDir + "/${lanMouseSecretFile}";
        owner = "greeter";
        group = "greeter";
        mode = "0400";
      };
    })
  ];

  # Keep /etc/agenix strictly root-only even before the first key is written.
  systemd.tmpfiles.rules = [
    "d /etc/agenix 0700 root root -"
  ];

  systemd.services.nm-agenix-profiles = lib.mkIf (hasSecretFile "nm-connections.age") {
    description = "Load agenix-encrypted NetworkManager profiles";
    wantedBy = [ "multi-user.target" ];
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    before = [ "network-online.target" ];
    restartTriggers = [
      (builtins.hashFile "sha256" (secretsDir + "/nm-connections.age"))
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${nmProfilesScript}";
    };
  };

  # Automatically sync imperative Wi-Fi additions/edits (nmcli / nmtui) back
  # into secrets/nm-connections.age without needing interactive unlock.
  systemd.services.nm-agenix-sync = {
    description = "Sync local NetworkManager Wi-Fi profiles into secrets/nm-connections.age";
    wantedBy = [ "multi-user.target" ];
    after = [
      "NetworkManager.service"
      "nm-agenix-profiles.service"
    ];
    unitConfig = {
      ConditionPathExists = "/home/${user}/MySettings/secrets/master-pubkey.txt";
      ConditionDirectoryNotEmpty = "/etc/NetworkManager/system-connections";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nmSyncScript}/bin/nm-agenix-sync --secrets-dir /home/${user}/MySettings/secrets --master-key /etc/agenix/master.key --skip-if-locked";
    };
  };

  systemd.paths.nm-agenix-sync = {
    description = "Watch NetworkManager profiles and sync Wi-Fi changes into secrets/nm-connections.age";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "/home/${user}/MySettings/secrets/master-pubkey.txt";
    };
    pathConfig = {
      PathChanged = "/etc/NetworkManager/system-connections";
      Unit = "nm-agenix-sync.service";
    };
  };

  services.tailscale.authKeyFile = lib.mkIf (hasSecretFile "tailscale-authkey.age") (
    lib.mkDefault config.age.secrets."tailscale-authkey".path
  );

  environment.systemPackages = [
    pkgs.age
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
