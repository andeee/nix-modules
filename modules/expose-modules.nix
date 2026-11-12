{ config, ... }:
{
  # Expose all registered NixOS modules as flake outputs
  flake.nixosModules = config.flake.modules.nixos;

  # Expose all registered Home Manager modules as flake outputs
  # (empty until the first modules/hm/ module lands here)
  flake.homeManagerModules = config.flake.modules.homeManager or { };
}
