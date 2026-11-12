_:
{
  flake.modules.nixos.light = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.brightnessctl ];
  };
}
