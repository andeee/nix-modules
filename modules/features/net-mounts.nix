_:
{
  flake.modules.nixos.net-mounts = _:
    let
      shares = [ "backup" "book" "family" "andi" "music" "photo" "roms" "video" "scan" "paperless-archive" ];
    in
    {
      fileSystems = builtins.listToAttrs (builtins.map
        (share: {
          name = "/media/${share}";
          value = {
            device = "//data.fbw9/${share}";
            fsType = "cifs";
            options =
              let
                automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
              in
              [ "${automount_opts},credentials=/etc/nixos/smb-secrets,uid=1000,gid=100,forcegid,forceuid,iocharset=utf8,echo_interval=10,nodfs" ];
          };
        })
        shares);
    };
}
