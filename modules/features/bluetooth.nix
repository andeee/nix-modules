_:
{
  flake.modules.nixos.bluetooth = { pkgs, ... }: {
    hardware.bluetooth = {
      enable = true;
      settings = {
        General = {
          Enable = "Source,Sink,Media,Socket";
          Experimental = true;
          # Faster reconnection when a device temporarily disconnects.
          FastConnectable = true;
          # Power the adapter at boot so (bonded) controllers can auto-connect
          # right after power-on, without toggling BT first.
          AutoEnable = true;
        };
      };
      # Input profile: don't timeout idle gamepads (crucial for 4-player)
      # and handle HID in userspace for LE gamepads.
      input = {
        General = {
          IdleTimeout = 0;
          UserspaceHID = true;
        };
      };
    };
    services.blueman.enable = true;
    environment.systemPackages = [
      pkgs.bluetui
    ];
    boot.kernelModules = [ "uinput" ];
  };
}
