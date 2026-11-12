_:
{
  # `inputs` must come from the CONSUMER's specialArgs (the consumer's
  # nixosSystem passes `specialArgs.inputs`), not from this flake's
  # flake-parts args — otherwise a library consumer would get *this*
  # repo's inputs, missing anything it does not declare (e.g.
  # inputs.dankMaterialShell).
  flake.modules.nixos.hm-base = { inputs, ... }: {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
    };
  };
}
