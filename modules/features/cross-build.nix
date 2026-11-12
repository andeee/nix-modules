_:
{
  flake.modules.nixos.cross-build = _: {
    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  };
}
