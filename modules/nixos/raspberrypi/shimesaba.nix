# shimesaba development stack:
# - code-server@shimesaba on 127.0.0.1:8080
# - PostgreSQL 17 on localhost:5438 (live cluster has role `postgres` and default DBs only)
# - shimesaba.service (Drogon app `sangakusenshu`), defined but disabled as today
{
  config,
  lib,
  pkgs,
  ...
}:

let
  hasCodeServerEnv = config.age.secrets ? "raspberrypi-code-server-env";

  shimesabaBinary = "/home/shimesaba/repo/drogon/sangakusenshu/build/sangakusenshu";
in
{
  # code-server running as shimesaba on 127.0.0.1:8080.
  # Reads restored /home/shimesaba/.config/code-server/config.yaml by default,
  # or PASSWORD / HASHED_PASSWORD from secrets/raspberrypi-code-server-env.age if provided.
  services.code-server = {
    enable = true;
    user = "shimesaba";
    group = "users";
    host = "127.0.0.1";
    port = 8080;
    auth = "password";
    extraArguments = [
      "--config=/home/shimesaba/.config/code-server/config.yaml"
    ];
  };

  systemd.services.code-server = {
    aliases = [ "code-server@shimesaba.service" ];
    # Clear the module's empty HASHED_PASSWORD="" so config.yaml (or agenix EnvironmentFile) is honored.
    environment.HASHED_PASSWORD = lib.mkForce null;
    serviceConfig = lib.mkIf hasCodeServerEnv {
      EnvironmentFile = config.age.secrets."raspberrypi-code-server-env".path;
    };
  };

  # PostgreSQL 17 listening on localhost:5438 (127.0.0.1 & ::1; default enableTCPIP = false sets listen_addresses = "localhost").
  # Verified against live Pi: only role `postgres` and databases `postgres`, `template0`, `template1` exist (no app DBs).
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    settings = {
      port = 5438;
    };
  };

  # Drogon library and native build toolchain for rebuilding sangakusenshu on the Pi.
  environment.systemPackages = with pkgs; [
    drogon
    cmake
    gnumake
    gcc
    gdb
    pkg-config
    jsoncpp
    openssl
    zlib
    libpq
  ];

  # Defined as a systemd unit but intentionally disabled (wantedBy = []),
  # matching the current Raspberry Pi OS unit (runs as root in build/ so relative
  # resources/ resolves, with Restart=always). Start manually with `systemctl start shimesaba`.
  systemd.services.shimesaba = {
    description = "shimesaba Drogon web service (sangakusenshu)";
    wantedBy = [ ];
    after = [
      "network.target"
      "postgresql.service"
    ];
    unitConfig = {
      ConditionPathExists = shimesabaBinary;
    };
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/home/shimesaba/repo/drogon/sangakusenshu/build";
      ExecStart = shimesabaBinary;
      Restart = "always";
      RestartSec = 5;
    };
  };
}
