{ inputs, ... }:
{
  imports = [
    inputs.pre-commit-hooks.flakeModule
  ];

  perSystem = { config, pkgs, ... }: {
    pre-commit = {
      check.enable = true;

      settings = {
        hooks = {
          nixpkgs-fmt.enable = true;
          deadnix.enable = true;
          statix.enable = true;

          # Note: detect-private-keys is disabled for pre-commit
          # but you can still run it manually with:
          #   nix develop --command detect-private-keys
        };
      };
    };

    devShells.default = pkgs.mkShell {
      shellHook = ''
        ${config.pre-commit.installationScript}
      '';

      packages = with pkgs; [
        nixpkgs-fmt
        statix
        deadnix
        pre-commit
      ];
    };
  };
}
