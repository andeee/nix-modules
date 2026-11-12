_:
{
  flake.modules.nixos.virtualisation = { pkgs, ... }: {
    # Needed for default bridge network to automatically work
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    virtualisation = {
      docker = {
        enable = true;
        logDriver = "local";
        autoPrune.enable = true;
        rootless = {
          enable = true;
          setSocketVariable = true;
          daemon.settings = {
            dns = [ "8.8.8.8" "8.8.4.4" ];
          };
        };
        daemon.settings = {
          userland-proxy = false;
        };
      };

      libvirtd.enable = true;
      spiceUSBRedirection.enable = true;
    };
    programs.dconf.enable = true;
    environment.systemPackages = with pkgs; [ virt-manager ];
  };
}
