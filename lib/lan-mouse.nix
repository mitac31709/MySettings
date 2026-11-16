# Shared non-secret Lan Mouse configuration across Home Manager and greetd.
# Private host TLS keys live in secrets/lan-mouse-<host>.pem.age (agenix).
{
  port = 4242;

  releaseBind = [
    "KeyLeftCtrl"
    "KeyLeftShift"
    "KeyLeftMeta"
    "KeyLeftAlt"
  ];

  authorizedFingerprints = {
    "58:9e:ec:3b:cb:fe:9c:f5:9c:77:1b:f4:3f:5e:4a:cc:22:a8:7c:73:77:78:cc:b6:d7:a7:cb:5b:46:1b:56:81" =
      "galleria-mitac";
    "0a:66:cf:37:85:1b:af:01:3b:8e:9a:b7:4f:30:7e:93:00:ba:d4:8a:c3:46:b7:69:60:00:8f:bf:93:9d:8b:63" =
      "vaio";
    "ae:da:ae:bc:28:50:66:b3:c9:76:99:ec:c4:ae:6c:04:2e:80:0c:07:9e:28:f7:db:80:37:45:58:af:26:97:d6" =
      "chromebook";
  };

  # One-way KVM: vaio controls chromebook on its left edge via Tailscale IP.
  clientsByHost = {
    vaio = [
      {
        hostname = "chromebook";
        position = "left";
        ips = [ "100.75.245.28" ];
        port = 4242;
        activate_on_startup = true;
      }
    ];
    chromebook = [ ];
  };
}
