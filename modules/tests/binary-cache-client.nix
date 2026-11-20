{ inputs, ... }:
{
  # Checks for `binary-cache-client` (modules/features/binary-cache-client.nix).
  #
  # The whole point of this module is *which* settings it writes: `extra-*`
  # rather than the plain lists (so a consumer does not lose cache.nixos.org and
  # any cache another module contributes), and the bounded-failure trio
  # (`connect-timeout`, `fallback`, `download-attempts`) that turns an
  # unreachable cache into seconds instead of a stalled build. Both are one-word
  # mistakes, so both are asserted.
  perSystem =
    { pkgs, lib, system, ... }:
    let
      mkNode =
        extra:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.self.nixosModules.binary-cache-client
            {
              system.stateVersion = "26.05";
              networking.hostName = "synthetic";
              binaryCacheClient = {
                enable = true;
                caches = [
                  {
                    url = "http://cache.invalid/synthetic";
                    publicKey = "synthetic-1:AAAA";
                  }
                  # A cache without a key: contributes a substituter, no key.
                  { url = "https://unsigned.invalid"; }
                ];
              };
            }
            extra
          ];
        };

      node = mkNode { };
      cfg = node.config;

      failures =
        lib.optional
          (cfg.nix.settings."extra-substituters" != [
            "http://cache.invalid/synthetic"
            "https://unsigned.invalid"
          ])
          "the configured caches are not in extra-substituters (got ${lib.concatStringsSep ", " cfg.nix.settings."extra-substituters"})"
        ++ lib.optional (cfg.nix.settings."extra-trusted-public-keys" != [ "synthetic-1:AAAA" ])
          "the public keys are wrong (got ${lib.concatStringsSep ", " cfg.nix.settings."extra-trusted-public-keys"})"
        # The values that are actually rendered, not the module's intent: a
        # consumer's nix.conf must still list the official cache.
        ++ lib.optional (!(lib.elem "https://cache.nixos.org/" cfg.nix.settings.substituters))
          "cache.nixos.org disappeared from substituters: the module must add, not replace"
        ++ lib.optional (cfg.nix.settings."connect-timeout" != 5)
          "connect-timeout is ${toString cfg.nix.settings."connect-timeout"}: an unreachable cache must cost seconds, not the default of forever"
        ++ lib.optional (!cfg.nix.settings.fallback)
          "fallback is off: any cache problem would fail the build"
        ++ lib.optional (cfg.nix.settings."download-attempts" != 1)
          "download-attempts is ${toString cfg.nix.settings."download-attempts"}: retries against a dead cache are how a build appears hung";
    in
    {
      checks.binary-cache-client =
        pkgs.runCommand "check-binary-cache-client"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
            ];
            settings = builtins.toJSON {
              inherit (cfg.nix.settings)
                substituters
                fallback
                ;
              "extra-substituters" = cfg.nix.settings."extra-substituters";
              "extra-trusted-public-keys" = cfg.nix.settings."extra-trusted-public-keys";
              "connect-timeout" = cfg.nix.settings."connect-timeout";
              "download-attempts" = cfg.nix.settings."download-attempts";
            };
          }
          (
            lib.optionalString (failures != [ ]) ''
              cat >&2 <<'EOF'
              FAIL: binary-cache-client renders the wrong settings:
              ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failures}

              See modules/features/binary-cache-client.nix.
              EOF
              exit 1
            ''
            + ''
              set -euo pipefail

              # The rendered settings, for the record, and a guard against the
              # module ever emitting an empty substituter (which nix reads as
              # "the list ends here").
              printf '%s' "$settings" | jq -e '.substituters | length > 0' > /dev/null \
                || { echo "FAIL: no substituters at all" >&2; exit 1; }
              printf '%s' "$settings" | jq -e '."extra-substituters" | all(. != "")' > /dev/null \
                || { echo "FAIL: an empty substituter URL was rendered" >&2; exit 1; }

              echo "✓ binary-cache-client: additive substituters, bounded failure settings"
              touch $out
            ''
          );
    };
}
