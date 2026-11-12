_:
{
  flake.modules.nixos.programs = { pkgs, ... }: {
    users.defaultUserShell = pkgs.zsh;
    programs.zsh.enable = true;

    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc
        zlib
        freetype
        fontconfig
        libxext
        libx11
        libxrender
        libxtst
        libxi
        libxcb
        glib
        nss
        nspr
      ];
    };

    home-manager.backupFileExtension = "hmbak";
  };
}
