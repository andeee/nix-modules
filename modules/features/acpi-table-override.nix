_:
{
  flake.modules.nixos.acpi-table-override = { pkgs, lib, config, ... }:
    let
      inherit (lib) types;
    in
    {
      options.hardware.acpi.tableOverrides = {
        enableSsdt = lib.mkEnableOption "SSDT overlay compilation and loading";
        enableDsdt = lib.mkEnableOption "DSDT override compilation and loading";

        ssdtSources = lib.mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = "List of .asl source files to compile as SSDT overlays and load from initrd.";
        };

        dsdtOverride = lib.mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a compiled DSDT .aml to load from initrd instead of the firmware DSDT.";
        };
      };

      config =
        let
          cfg = config.hardware.acpi.tableOverrides;
        in
        lib.mkIf (cfg.enableSsdt || cfg.enableDsdt) (
          let
            # Derive SSDT filenames: ssdt-npcf.asl → SSDT-ssdt-npcf.aml
            ssdtInfos = map
              (src:
                let
                  name = builtins.baseNameOf src;
                  base = lib.removeSuffix ".asl" name;
                  # Use a short basename: ssdt-npcf.asl → npcf → SSDT-npcf.aml
                  # (kept under 18 chars to avoid kernel MAX_CPIO_FILE_NAME warning)
                  shortBase = lib.removePrefix "ssdt-" base;
                in
                {
                  inherit src shortBase;
                  amlName = "SSDT-${shortBase}.aml";
                })
              cfg.ssdtSources;

            # Compile each SSDT .asl source to .aml via iasl.
            # Each becomes its own derivation output (a single .aml file).
            compiledSsdt = map
              (info: rec {
                inherit (info) amlName;
                drv = pkgs.runCommand "ssdt-${info.amlName}"
                  {
                    nativeBuildInputs = [ pkgs.acpica-tools ];
                    srcFile = info.src;
                  } ''
                  cp "$srcFile" src.asl
                  iasl src.asl
                  cp src.aml "$out"
                '';
                outPath = drv;
              })
              ssdtInfos;

            # Build systemd initrd contents mapping
            ssdtEntries = lib.listToAttrs (map
              (info: {
                name = "/kernel/firmware/acpi/${info.amlName}";
                value = { source = info.drv; };
              })
              compiledSsdt);

            dsdtEntry = lib.optionalAttrs (cfg.dsdtOverride != null) {
              "/kernel/firmware/acpi/DSDT.aml" = { source = cfg.dsdtOverride; };
            };

            # Create an uncompressed cpio archive for the prepend section.
            # systemd stage-1 compresses the main initrd (zstd), which hides files
            # from the kernel's early ACPI table scanner. The scanner only reads
            # uncompressed cpio regions (prepend). Microcode uses the same trick.
            ssdtCpio = pkgs.runCommand "acpi-table-cpio"
              {
                nativeBuildInputs = [ pkgs.cpio ];
              } ''
              mkdir -p tmp/kernel/firmware/acpi
              ${lib.concatStringsSep "\n" (map (info: ''
                cp '${info.drv}' "tmp/kernel/firmware/acpi/${info.amlName}"
              '') compiledSsdt)}
              ${lib.optionalString (cfg.dsdtOverride != null) ''
                cp '${cfg.dsdtOverride}' tmp/kernel/firmware/acpi/DSDT.aml
              ''}
              cd tmp
              find . -print0 | sort -z | cpio --quiet -o -H newc -R +0:+0 --reproducible --null > "$out"
            '';
          in
          {
            # Prepend: uncompressed cpio with SSDT/DSDT — visible to kernel's early ACPI scanner
            boot.initrd.prepend = lib.mkOrder 50 [ "${ssdtCpio}" ];

            # Systemd initrd contents: also available after root switch
            boot.initrd.systemd.contents = ssdtEntries // dsdtEntry;
          }
        );
    };
}
