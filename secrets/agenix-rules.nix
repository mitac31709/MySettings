# Recipient rules for `agenix` (evaluated standalone with `nix-instantiate`).
# Master public key(s) are loaded from `./master-pubkey.txt` (`secrets init` populates it;
# the matching private key is stored in Bitwarden item `agenix-master-key` and `/etc/agenix/master.key`).
let
  raw = if builtins.pathExists ./master-pubkey.txt then builtins.readFile ./master-pubkey.txt else "";
  lines = builtins.filter builtins.isString (builtins.split "\n" raw);
  stripWs =
    s:
    let
      m = builtins.match "^[ \t\r]*(.*[^ \t\r])[ \t\r]*$" s;
    in
    if m == null then "" else builtins.head m;
  masterKeys = builtins.filter (l: l != "" && builtins.substring 0 1 l != "#") (map stripWs lines);
in
{
  "restic-home-password.age".publicKeys = masterKeys;
  "rclone-conf.age".publicKeys = masterKeys;
  "nm-connections.age".publicKeys = masterKeys;
  "tailscale-authkey.age".publicKeys = masterKeys;
  "id-wsl-builder.age".publicKeys = masterKeys;
  "id-ed25519.age".publicKeys = masterKeys;
  "gh-hosts.yml.age".publicKeys = masterKeys;
  "user-env.age".publicKeys = masterKeys;
  "wol-pc-env.age".publicKeys = masterKeys;
  "adbkey.age".publicKeys = masterKeys;
  "opencode-service.json.age".publicKeys = masterKeys;
  "lan-mouse-chromebook.pem.age".publicKeys = masterKeys;
  "lan-mouse-vaio.pem.age".publicKeys = masterKeys;

  # Raspberry Pi 5 server secrets (placeholders; populate via `agenix -e`).
  "raspberrypi-nm-connections.age".publicKeys = masterKeys;
  "raspberrypi-freeap-hostapd.age".publicKeys = masterKeys;
  "raspberrypi-usque-config.age".publicKeys = masterKeys;
  "raspberrypi-freeap-notify-env.age".publicKeys = masterKeys;
  "raspberrypi-lecture-timetable-env.age".publicKeys = masterKeys;
  "raspberrypi-lecture-upload-key.age".publicKeys = masterKeys;
  "raspberrypi-code-server-env.age".publicKeys = masterKeys;
}
