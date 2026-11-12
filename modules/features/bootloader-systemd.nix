_:
{
  flake.modules.nixos.bootloader-systemd = _: {
    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
}
