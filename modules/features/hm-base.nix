{ inputs, ... }:
{
  flake.modules.nixos.hm-base = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
    };
  };
}
