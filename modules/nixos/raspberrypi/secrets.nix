# Declarative agenix secrets for the Raspberry Pi 5 server.
#
# Follows the repository's shared master-key pattern (`/etc/agenix/master.key`,
# recipient rules in `secrets/agenix-rules.nix`). Every secret file is wired
# conditionally via `builtins.pathExists` so pure flake evaluation succeeds
# before the `.age` ciphertexts are populated with real credentials.
#
# TODO: Encrypt each placeholder secret listed below via `agenix -e` (using
# `secrets/agenix-rules.nix`) before switching on the real Pi:
#   - secrets/raspberrypi-nm-connections.age
#       Bundle of NetworkManager keyfiles separated by `# === <name> ===` headers:
#         * Wired connection 1 (eth0, 802.1x PEAP/MSCHAPv2, tokyo-ct.ac.jp, autoconnect=true, password-flags=0)
#         * Hazamaru AP-tr     (wlan0, 802.1x PEAP/MSCHAPv2, tokyo-ct.ac.jp, autoconnect=true, route-metric=600)
#         * eduroam            (wlan0, 802.1x PEAP/MSCHAPv2, autoconnect=true)
#   - secrets/raspberrypi-freeap-hostapd.age      (/etc/hostapd/freeap.conf with SSID + passphrase)
#   - secrets/raspberrypi-usque-config.age        (/etc/usque/config.json with WARP/MASQUE credentials)
#   - secrets/raspberrypi-freeap-notify-env.age   (/etc/freeap-notify.env containing `WEBHOOK=...`, shared by freeap-count-notify and campus-apload-report)
#   - secrets/raspberrypi-lecture-timetable-env.age (/etc/lecture-recorder/timetable.env)
#   - secrets/raspberrypi-lecture-upload-key.age  (/var/lib/lecrec/.ssh/id_ed25519 write-only SSH private key for ubuntu:~/lectures/inbox)
#   - secrets/raspberrypi-code-server-env.age     (optional PASSWORD/HASHED_PASSWORD env for code-server)
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  secretsDir = ../../../secrets;
  hasSecretFile = filename: builtins.pathExists (secretsDir + "/${filename}");

  # Deploy decrypted NetworkManager profiles into /run/NetworkManager/system-connections
  # BEFORE NetworkManager starts so wired eth0 802.1x comes up at boot without login.
  # Unlike the laptop script, preserve `interface-name=` so eth0 / wlan0 bindings stay intact.
  nmProfilesScript = pkgs.writeScript "raspberrypi-nm-profiles" ''
    #!${pkgs.python3}/bin/python3
    import os
    import pathlib
    import re
    import subprocess
    import sys

    src = pathlib.Path(${
      builtins.toJSON (
        config.age.secrets."raspberrypi-nm-connections".path or "/run/agenix/raspberrypi-nm-connections"
      )
    })
    if not src.is_file():
        print(f"raspberrypi-nm-profiles: {src} not found, skipping", file=sys.stderr)
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

    if not sections and "[connection]" in raw:
        sections = [("default", raw)]

    dest_dir = pathlib.Path("/run/NetworkManager/system-connections")
    dest_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(dest_dir, 0o700)

    for old in dest_dir.glob("agenix-*.nmconnection"):
        old.unlink()

    written = 0
    for idx, (name, body) in enumerate(sections, start=1):
        content = body.strip()
        if not content or "[connection]" not in content:
            continue
        base = name or f"profile-{idx}"
        if base.endswith(".nmconnection"):
            base = base[: -len(".nmconnection")]
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("_") or f"profile-{idx}"
        out_path = dest_dir / f"agenix-{idx:02d}-{slug}.nmconnection"
        tmp_path = dest_dir / f".agenix-{idx:02d}-{slug}.tmp"
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(content + "\n")
            os.chown(tmp_path, 0, 0)
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, out_path)
            written += 1
        except Exception:
            if tmp_path.exists():
                tmp_path.unlink()
            raise

    # Reload NetworkManager if it is already running (e.g. during nixos-rebuild switch).
    if subprocess.run(
        ["${pkgs.systemd}/bin/systemctl", "is-active", "--quiet", "NetworkManager.service"],
        check=False,
    ).returncode == 0:
        subprocess.run(
            ["${pkgs.networkmanager}/bin/nmcli", "connection", "reload"],
            check=False,
        )

    print(f"raspberrypi-nm-profiles: deployed {written} declarative profile(s)")
  '';
in
{
  age.identityPaths = [ "/etc/agenix/master.key" ];

  age.secrets = lib.mkMerge [
    (lib.optionalAttrs (hasSecretFile "raspberrypi-nm-connections.age") {
      "raspberrypi-nm-connections" = {
        file = secretsDir + "/raspberrypi-nm-connections.age";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-freeap-hostapd.age") {
      "raspberrypi-freeap-hostapd" = {
        file = secretsDir + "/raspberrypi-freeap-hostapd.age";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-usque-config.age") {
      "raspberrypi-usque-config" = {
        file = secretsDir + "/raspberrypi-usque-config.age";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-freeap-notify-env.age") {
      "raspberrypi-freeap-notify-env" = {
        file = secretsDir + "/raspberrypi-freeap-notify-env.age";
        owner = "root";
        group = "root";
        mode = "0600";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-lecture-timetable-env.age") {
      "raspberrypi-lecture-timetable-env" = {
        file = secretsDir + "/raspberrypi-lecture-timetable-env.age";
        owner = "lecrec";
        group = "lecrec";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-lecture-upload-key.age") {
      "raspberrypi-lecture-upload-key" = {
        file = secretsDir + "/raspberrypi-lecture-upload-key.age";
        owner = "lecrec";
        group = "lecrec";
        mode = "0400";
      };
    })
    (lib.optionalAttrs (hasSecretFile "raspberrypi-code-server-env.age") {
      "raspberrypi-code-server-env" = {
        file = secretsDir + "/raspberrypi-code-server-env.age";
        owner = "shimesaba";
        group = "users";
        mode = "0400";
      };
    })
  ];

  # Keep /etc/agenix strictly root-only, and link decrypted agenix secrets into
  # their canonical /etc paths when present so scripts reading those paths directly work.
  systemd.tmpfiles.rules = [
    "d /etc/agenix 0700 root root -"
  ]
  ++ lib.optional (hasSecretFile "raspberrypi-freeap-notify-env.age") "L+ /etc/freeap-notify.env - - - - ${
    config.age.secrets."raspberrypi-freeap-notify-env".path
  }"
  ++ lib.optional (hasSecretFile "raspberrypi-usque-config.age") "L+ /etc/usque/config.json - - - - ${
    config.age.secrets."raspberrypi-usque-config".path
  }"
  ++ lib.optional (hasSecretFile "raspberrypi-freeap-hostapd.age") "L+ /etc/hostapd/freeap.conf - - - - ${
    config.age.secrets."raspberrypi-freeap-hostapd".path
  }"
  ++ lib.optional (hasSecretFile "raspberrypi-lecture-timetable-env.age") "L+ /etc/lecture-recorder/timetable.env - - - - ${
    config.age.secrets."raspberrypi-lecture-timetable-env".path
  }";

  # Run before NetworkManager.service so wired 802.1x (eth0) and campus Wi-Fi
  # profiles are present on cold boot without requiring any user login.
  systemd.services.raspberrypi-nm-profiles =
    lib.mkIf (hasSecretFile "raspberrypi-nm-connections.age")
      {
        description = "Deploy agenix-encrypted NetworkManager profiles for raspberrypi";
        wantedBy = [
          "NetworkManager.service"
          "multi-user.target"
        ];
        before = [
          "NetworkManager.service"
          "network-online.target"
        ];
        restartTriggers = [
          (builtins.hashFile "sha256" (secretsDir + "/raspberrypi-nm-connections.age"))
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${nmProfilesScript}";
        };
      };

  environment.systemPackages = [
    pkgs.age
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
