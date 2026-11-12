_:
{
  flake.modules.nixos.powertop = { pkgs, lib, config, ... }: {
    options.powerManagement.usbAutoSuspendWhitelist = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      default = [
        { vendor = "046a"; product = "c091"; name = "CHERRY Wireless Desktop receiver"; }
        { vendor = "0461"; product = "4d51"; name = "Dell Laser Mouse"; }
        { vendor = "24f0"; product = "0142"; name = "Das Keyboard D4269"; }
        { vendor = "2b89"; product = "0038"; name = "UGREEN 2.4G Receiver"; }
        { vendor = "2b89"; product = "0043"; name = "UGREEN Receiver"; }
        { vendor = "0bda"; product = "0852"; name = "Realtek Bluetooth Radio"; }
      ];
      description = "List of USB vendor/product pairs to keep out of autosuspend.\nEach entry is an attribute set with 'vendor', 'product' and optional 'name'.";
    };

    config = {
      powerManagement.powertop.enable = true;

      services.udev.extraRules =
        let
          rules = lib.concatStringsSep "\n" (map
            (d:
              let nm = d.name or ""; comment = if nm != "" then "# " + nm + "\n" else ""; in
              ''${comment}ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="${d.vendor}", ATTR{idProduct}=="${d.product}", ATTR{power/control}="on"''
            )
            config.powerManagement.usbAutoSuspendWhitelist);
        in
        ''${rules}'';

      # Run the fix script as ExecStartPost of powertop.service to avoid
      # systemd ordering cycles (powertop <-> multi-user.target <-> fix-service).
      systemd.services.powertop.serviceConfig.ExecStartPost = pkgs.writeShellScript "fix-usb-whitelist-power" ''
        IDS="${lib.concatStringsSep " " (map (d: "${d.vendor}:${d.product}") config.powerManagement.usbAutoSuspendWhitelist)}"
        for dev in /sys/bus/usb/devices/*; do
          [ -r "$dev/idVendor" ] || continue
          [ -r "$dev/idProduct" ] || continue
          vendor=$(cat "$dev/idVendor")
          product=$(cat "$dev/idProduct")
          for id in $IDS; do
            if [ "$vendor:$product" = "$id" ]; then
              if [ -w "$dev/power/control" ]; then
                echo on > "$dev/power/control"
              fi
              break
            fi
          done
        done
      '';
    };
  };
}
