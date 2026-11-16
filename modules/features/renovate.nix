_:
{
  flake.modules.nixos.renovate-self-hosted = { config, lib, pkgs, ... }:
    let
      cfg = config.services.renovate-self-hosted;
    in
    {
      options.services.renovate-self-hosted = {
        enable = lib.mkEnableOption "Renovate for a self-hosted Gitea or Forgejo server";

        endpoint = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Gitea or Forgejo base URL, without a trailing slash.";
        };

        platform = lib.mkOption {
          type = lib.types.enum [ "gitea" "forgejo" ];
          default = "gitea";
          description = "The Renovate platform type used by the server.";
        };

        repositories = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Repositories to process, in owner/name form.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "Mon *-*-* 03:17:00";
          description = "systemd calendar expression for Renovate runs.";
        };

        internalHostAccess = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum [ "allow" "warn" "block" ]);
          default = null;
          description = "Optional Renovate internal-host access policy.";
        };

        gitAuthor = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional Git author identity used for Renovate commits.";
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.endpoint != "" && !(lib.hasSuffix "/" cfg.endpoint);
            message = "services.renovate-self-hosted.endpoint must be set and must not end with a slash.";
          }
          {
            assertion = cfg.repositories != [ ];
            message = "services.renovate-self-hosted.repositories must contain at least one repository.";
          }
          {
            assertion = config.services.renovate.credentials ? RENOVATE_TOKEN;
            message = "services.renovate.credentials.RENOVATE_TOKEN must be configured with a credential file.";
          }
        ];

        services.renovate = {
          enable = true;
          inherit (cfg) schedule;
          runtimePackages = [ pkgs.nix pkgs.openssh pkgs.cacert ];
          settings = {
            inherit (cfg) platform;
            autodiscover = false;
          } // {
            inherit (cfg) endpoint repositories;
          } // lib.optionalAttrs (cfg.gitAuthor != null) {
            inherit (cfg) gitAuthor;
          };
          environment = {
            LOG_LEVEL = "info";
            RENOVATE_BINARY_SOURCE = "global";
          } // lib.optionalAttrs (cfg.internalHostAccess != null) {
            RENOVATE_INTERNAL_HOST_ACCESS = cfg.internalHostAccess;
          };
        };

        # Gitea or Forgejo may accept the token embedded in Renovate's clone
        # URL for the initial request but reject git's subsequent upload-pack
        # request. The native NixOS service loads credentials into systemd's
        # credential store; use that credential to configure git without
        # exposing it in the store.
        systemd.services.renovate.preStart = ''
          set -euo pipefail
          token="$(systemd-creds cat SECRET-RENOVATE_TOKEN)"
          umask 077
          printf '[http "%s/"]\n\textraheader = Authorization: token %s\n' \
            "${cfg.endpoint}" "$token" > "$HOME/.gitconfig"
        '';
      };
    };
}
