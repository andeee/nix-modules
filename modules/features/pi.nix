_:
{
  flake.modules.nixos.pi = { pkgs, lib, config, ... }: {
    imports = [
      # Reuse embedded base config
      # (Pi hosts need embedded base plus SD image settings)
    ];

    sdImage = {
      compressImage = false;
    };
    image.baseName = lib.mkForce config.networking.hostName;
    environment = {
      defaultPackages = [ ];
      systemPackages = with pkgs; [ libraspberrypi ];
    };
  };
}
