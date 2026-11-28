# Network traffic monitoring (ntopng on 127.0.0.1:3000 + Redis on 127.0.0.1:6379)
# and iperf3 throughput test server (*:5201).
{ ... }:

{
  # Local Redis for ntopng (127.0.0.1:6379, matching current Pi OS redis-server).
  services.redis.servers."" = {
    enable = true;
    bind = "127.0.0.1";
    port = 6379;
  };

  # ntopng Community Edition watching freeap0, usque0, and eth0 with localhost-only Web UI.
  # Matches live /etc/ntopng/ntopng.conf verbatim (with explicit NixOS --redis and --user).
  services.ntopng = {
    enable = true;
    redis = {
      createInstance = null;
      address = "127.0.0.1:6379";
    };
    configText = ''
      -G=/run/ntopng.pid
      --community
      -i=freeap0
      -i=usque0
      -i=eth0
      -w=127.0.0.1:3000
      -W=0
      -m=10.42.0.0/24,172.18.40.0/21,172.16.0.0/12,100.64.0.0/10
      -d=/var/lib/ntopng
      --redis=127.0.0.1:6379
      --user=ntopng
    '';
  };

  systemd.services.ntopng = {
    requires = [ "redis.service" ];
    after = [
      "redis.service"
      "network.target"
    ];
  };

  # iperf3 server on TCP/UDP 5201.
  services.iperf3 = {
    enable = true;
    port = 5201;
    openFirewall = true;
  };

  networking.firewall.allowedUDPPorts = [ 5201 ];
}
