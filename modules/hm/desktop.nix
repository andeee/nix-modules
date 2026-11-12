{ config, ... }:
let
  home = config.flake.modules.homeManager;
in
{
  flake.modules.homeManager.desktop = { pkgs, lib, config, ... }: {
    imports = [
      home.desktop-base
    ];

    options.custom.desktop = {
      rbw = {
        enable = lib.mkEnableOption "rbw (Bitwarden CLI) against a vaultwarden server";
        baseUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Vaultwarden base URL; required when custom.desktop.rbw.enable.";
        };
        email = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "rbw login email; required when custom.desktop.rbw.enable.";
        };
      };
      gpgPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = ''
          Extra GPG public keys to import ({ source, trust }). Defaults to none
          so a shared module carries nobody's key material.
        '';
      };
    };

    programs.niri = {
      settings = {
        workspaces = {
          "1" = { name = "terminal"; };
          "2" = { name = "browser"; };
        };
        spawn-at-startup = [
          { command = [ "qutebrowser" ]; }
          { command = [ "foot" ]; }
        ];
        window-rules = [
          {
            matches = [
              { at-startup = true; app-id = "^foot$"; }
            ];
            open-on-workspace = "terminal";
            open-maximized = true;
          }
          {
            matches = [
              { at-startup = true; app-id = ''^org\.qutebrowser\.qutebrowser$''; }
            ];
            open-on-workspace = "browser";
            open-maximized = true;
          }
        ];
      };
    };

    programs = {
      rbw = lib.mkIf config.custom.desktop.rbw.enable {
        enable = true;
        settings = {
          base_url = config.custom.desktop.rbw.baseUrl;
          email = config.custom.desktop.rbw.email;
          lock_timeout = 300;
          pinentry = pkgs.pinentry-qt;
        };
      };

      gpg = lib.mkIf (config.custom.desktop.gpgPublicKeys != [ ]) {
        enable = true;
        publicKeys = config.custom.desktop.gpgPublicKeys;
      };
    };

    services = {
      poweralertd.enable = true;

      udiskie = {
        tray = "always";
        enable = true;
      };

      gpg-agent = {
        enable = true;
        enableZshIntegration = true;
        pinentry.package = pkgs.pinentry-qt;
      };
    };

    systemd.user.services.udiskie = {
      Unit = {
        Requires = lib.mkForce [ ];
        After = lib.mkForce [ "graphical-session-pre.target" ];
      };
    };

    xdg = {
      mimeApps = {
        enable = true;
        defaultApplications = {
          "application/pdf" = "okularApplication_pdf.desktop";
          "application/x-gzpdf" = "okularApplication_pdf.desktop";
          "application/x-bzpdf" = "okularApplication_pdf.desktop";
          "application/x-wwf" = "okularApplication_pdf.desktop";
        };
      };
    };
  };
}
