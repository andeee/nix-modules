_:
{
  # Binary caches as a *system-level* consumer.
  #
  # Why an option and not just `nix.settings.substituters` in a host file:
  #
  #   * `extra-substituters`/`extra-trusted-public-keys`, never the plain ones.
  #     Other modules contribute caches of their own (niri-flake adds its own,
  #     nixpkgs contributes cache.nixos.org), and assigning `substituters`
  #     wholesale is how a host silently loses access to the official cache and
  #     starts compiling a kernel.
  #
  #   * The settings have to be *system* settings, not flake `nixConfig`. A
  #     `nix build`/`nixos-rebuild` started by a systemd unit runs as root and
  #     only consults `nixConfig` when `accept-flake-config` is on — which is
  #     exactly the situation of an unattended upgrade or a CI job.
  #
  #   * A cache that is unreachable (a VPN that blocks it, a machine off site)
  #     must cost seconds, not minutes, and must never fail a build. Hence
  #     `connect-timeout` + `fallback` + a single download attempt: nix gives up
  #     on that substituter quickly and continues with the next one or builds.
  #     The Nix default for `connect-timeout` is "no timeout", which is the
  #     difference between a 5-second detour and a build that appears hung.
  flake.modules.nixos.binary-cache-client =
    { config, lib, ... }:
    let
      cfg = config.binaryCacheClient;
    in
    {
      options.binaryCacheClient = {
        enable = lib.mkEnableOption "substituting from additional binary caches";

        caches = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                url = lib.mkOption {
                  type = lib.types.str;
                  example = "https://cache.example.org/some-namespace";
                  description = "Cache URL, including any namespace path the cache server expects.";
                };

                publicKey = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "example-1:AbCdEf…";
                  description = ''
                    The cache's trusted public key. Public material, so it belongs
                    in the consuming repository, not in a secret. Leave null for a
                    cache whose signatures are trusted by other means.
                  '';
                };
              };
            }
          );
          default = [ ];
          description = "Additional substituters to consult, in the order nix should try them.";
        };

        connectTimeout = lib.mkOption {
          type = lib.types.ints.positive;
          default = 5;
          description = ''
            Seconds nix may spend establishing a connection to a substituter.

            Deliberately short: a cache that is unreachable because of a VPN or a
            network change is a routine condition, and the default (no timeout)
            turns every missing path into a stalled build.
          '';
        };

        fallback = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Continue with the remaining substituters (and then with a local
            build) when a path cannot be fetched. Turning this off makes any cache
            problem a build failure.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.caches != [ ];
            message = "binaryCacheClient.caches must list at least one cache when the module is enabled.";
          }
          {
            assertion = lib.all (c: c.url != "") cfg.caches;
            message = "binaryCacheClient.caches[*].url must not be empty.";
          }
        ];

        nix.settings = {
          connect-timeout = cfg.connectTimeout;
          inherit (cfg) fallback;

          extra-substituters = map (cache: cache.url) cfg.caches;

          extra-trusted-public-keys = map (cache: cache.publicKey) (
            builtins.filter (cache: cache.publicKey != null) cfg.caches
          );

          # One attempt per path: a retry storm against an unreachable cache is
          # how a "quick" build turns into a five-minute one.
          download-attempts = 1;
        };
      };
    };
}
