_:
{
  flake.modules.nixos.embedded = { modulesPath, pkgs, lib, ... }: {
    imports = [
      (modulesPath + "/profiles/minimal.nix")
    ];
    boot = {
      supportedFilesystems.zfs = lib.mkForce false;
      tmp.useTmpfs = true;
    };
    fileSystems = {
      "/" = {
        options = [ "noatime" ];
      };
    };
    services.journald.storage = "volatile";
    virtualisation.vmVariant = {
      virtualisation = {
        host.pkgs = import pkgs.path { localSystem = "x86_64-linux"; };
        qemu.guestAgent.enable = true;
      };
    };
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
      randomizedDelaySec = "5m";
    };
    users.mutableUsers = false;
    security.sudo.wheelNeedsPassword = false;
  };
}
