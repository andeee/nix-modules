_:
{
  flake.modules.nixos.networking = _: {
    networking.networkmanager = {
      enable = true;
      dns = "systemd-resolved";
    };
    services.resolved = {
      enable = true;
      settings = {
        Resolve.FallbackDNS = [ "1.1.1.1" "8.8.8.8" ];
      };
    };
    systemd.services.NetworkManager-wait-online.enable = false;

    services.openssh = {
      enable = true;
      settings = {
        X11Forwarding = true;
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
      openFirewall = true;
    };
    programs.mosh.enable = true;
  };
}
