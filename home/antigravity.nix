# Google Antigravity CLI (`agy` / `antigravity`) and Remote Control daemon.
{
  pkgs,
  ...
}:

let
  waitForNetwork = pkgs.writeShellScript "antigravity-wait-for-network" ''
    # Avoid an early-boot DNS failure before NetworkManager brings up a route.
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      if ${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gnugrep}/bin/grep -q . \
        || ${pkgs.iproute2}/bin/ip -6 route show default | ${pkgs.gnugrep}/bin/grep -q .; then
        if ${pkgs.getent}/bin/getent ahosts oauth2.googleapis.com >/dev/null 2>&1; then
          exit 0
        fi
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    exit 0
  '';
  antigravityEnsureRcToken = pkgs.writeShellScript "antigravity-ensure-rc-token" ''
    token="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
    if [ ! -s "$token" ] && [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ]; then
      # Export the OAuth token from the unlocked keyring for `remote-control serve`.
      # Skip before graphical login so gnome-keyring does not spawn gcr-prompter without a display.
      # Ignore the read-only unit write error since the service file is Nix-managed.
      ${pkgs.antigravity}/bin/antigravity remote-control start >/dev/null 2>&1 || true
    fi
  '';
in
{
  home.packages = [
    pkgs.antigravity
  ];

  # Persistent headless daemon for Antigravity Remote Control (https://antigravity.google.com)
  systemd.user.services.antigravity-cli-daemon = {
    Unit = {
      Description = "antigravity remote-control daemon";
      After = [ "network.target" ];
      StartLimitIntervalSec = 0;
    };

    Service = {
      Type = "simple";
      ExecStartPre = [
        "${waitForNetwork}"
        "${antigravityEnsureRcToken}"
      ];
      ExecStart = "${pkgs.antigravity}/bin/antigravity remote-control serve";
      # user@.service overrides PATH before Hyprland/UWSM updates activation env; supply system/profile bins for boot-time linger
      Environment = [
        "PATH=/run/wrappers/bin:%h/.nix-profile/bin:/nix/profile/bin:%h/.local/state/nix/profile/bin:/etc/profiles/per-user/%u/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
      ];
      Restart = "on-failure";
      RestartSec = "10s";
      RestartPreventExitStatus = 3;
      SuccessExitStatus = 3;
      TimeoutStopSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    Install = {
      WantedBy = [
        "default.target"
        "graphical-session.target"
      ];
    };
  };

  # Overwrite pre-existing imperative unit files/wants symlinks (e.g. written by
  # `antigravity remote-control` before Nixification); backupFileExtension ignores symlinks.
  xdg.configFile."systemd/user/antigravity-cli-daemon.service".force = true;
  xdg.configFile."systemd/user/default.target.wants/antigravity-cli-daemon.service".force = true;
  xdg.configFile."systemd/user/graphical-session.target.wants/antigravity-cli-daemon.service".force =
    true;
}
