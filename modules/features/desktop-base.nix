_:
let
  # Themes that ship with the plymouth package itself (see
  # pkgs.plymouth/share/plymouth/themes). Selecting one of these must not
  # pull in adi1090x-plymouth-themes, which throws on unknown names.
  builtInPlymouthThemes = [
    "bgrt"
    "details"
    "fade-in"
    "glow"
    "script"
    "solar"
    "spinfinity"
    "spinner"
    "text"
    "tribar"
  ];
in
{
  flake.modules.nixos.desktop-base = { pkgs, lib, config, ... }:
    let
      plymouthTheme = config.andeee.boot.plymouth.theme;
    in
    {
      options.andeee.boot.plymouth = {
        theme = lib.mkOption {
          type = lib.types.str;
          default = "glitch";
          description = ''
            Plymouth boot theme. Either an adi1090x theme or one of the
            themes built into plymouth itself (e.g. "bgrt", which keeps
            the firmware/vendor logo from the ACPI BGRT table on screen
            during boot).

            Built-in themes: ${lib.concatStringsSep ", " builtInPlymouthThemes}
          '';
        };
      };

      config = {
        # dbus + dconf
        programs.dconf.enable = true;

        services = {
          dbus = {
            enable = true;
            implementation = "broker";
            packages = [ pkgs.dconf ];
          };

          # fstrim
          fstrim = {
            enable = true;
          };

          gvfs.enable = true;

          # logind
          logind.settings.Login = {
            HandlePowerKey = "ignore";
            HandlePowerKeyLongPress = "reboot";
            HandleLidSwitchExternalPower = "ignore";
          };

          # udisks2
          udisks2 = {
            enable = true;
            mountOnMedia = true;
          };

          # upower
          upower.enable = true;

          # avahi + printing
          avahi = {
            enable = true;
            nssmdns4 = true;
            openFirewall = true;
          };

          printing = {
            enable = true;
            cups-pdf.enable = true;
          };
        };

        systemd.services.fstrim.unitConfig = {
          ConditionACPower = true;
        };

        # polkit
        security.polkit.enable = true;

        # plymouth
        stylix.targets.plymouth.enable = false;

        boot = {
          # Enable "Silent boot"
          consoleLogLevel = 3;
          initrd.verbose = false;
          kernelParams = [
            "quiet"
            "rd.udev.log_level=3"
            "rd.systemd.show_status=auto"
          ];

          # Hide the OS choice for bootloaders.
          # It's still possible to open the bootloader list by pressing any key
          # It will just not appear on screen unless a key is pressed
          loader.timeout = 0;
          initrd.systemd.enable = true;
          plymouth = {
            enable = true;
            themePackages = lib.optionals (!lib.elem plymouthTheme builtInPlymouthThemes) [
              (pkgs.adi1090x-plymouth-themes.override { selected_themes = [ plymouthTheme ]; })
            ];
            theme = plymouthTheme;
          };
        };
      };
    };
}
