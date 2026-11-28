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
  # Mirrors /etc/ntopng/ntopng.conf on the live Pi (-w=127.0.0.1:3000, -W=0, -m local nets).
  services.ntopng = {
    enable = true;
    redis = {
      createInstance = null;
      address = "127.0.0.1:6379";
    };
    configText = ''
      --interface=freeap0
      --interface=usque0
      --interface=eth0
      --http-port=127.0.0.1:3000
      --https-port=0
      --local-networks=10.42.0.0/24,172.18.40.0/21,172.16.0.0/12,100.64.0.0/10
      --redis=127.0.0.1:6379
      --data-dir=/var/lib/ntopng
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
