_:
{
  flake.modules.nixos.pipewire-camera = { lib, config, ... }:
    let
      cfg = config.services.pipewire.camera;
    in
    {
      options.services.pipewire.camera = {
        enable = lib.mkEnableOption "automatic V4L2 camera priority management";

        externalCameras = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Camera identifier (for documentation/debugging)";
              };

              nodePattern = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "V4L2 node name pattern (supports ~regex)";
              };

              productId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "USB product ID (e.g. 0x082d) - most reliable match";
              };

              vendorId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "USB vendor ID (e.g. 0x046d for Logitech)";
              };

              nodeNick = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Node nickname pattern (supports ~regex)";
              };

              priority = lib.mkOption {
                type = lib.types.int;
                default = 2000;
                description = "Camera priority (higher = preferred)";
              };

              description = lib.mkOption {
                type = lib.types.str;
                description = "Human-readable description";
              };
            };
          });

          default = [ ];
          description = "External cameras with priority configuration";
        };

        internalCamera = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable internal camera as fallback";
          };

          nodePattern = lib.mkOption {
            type = lib.types.str;
            default = "~v4l2_input.pci-0000_00_.*";
            description = "Pattern to match internal camera nodes";
          };

          priority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Priority for internal camera";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        # Assertion: PipeWire must be enabled
        assertions = [
          {
            assertion = config.services.pipewire.enable;
            message = "PipeWire must be enabled to use pipewire-camera module";
          }
        ];

        services.pipewire.wireplumber.extraConfig = {
          "50-camera-priority" = {
            "monitor.v4l2.rules" =
              # External camera rules - generate matches for each camera
              (lib.lists.flatten (map
                (camera:
                  let
                    # Build match conditions based on provided criteria
                    # Multiple conditions are combined with OR logic by WirePlumber
                    matches = lib.filter (x: x != { }) [
                      (lib.optionalAttrs (camera.nodePattern != null) {
                        "node.name" = camera.nodePattern;
                      })
                      (lib.optionalAttrs (camera.productId != null) {
                        "device.product.id" = camera.productId;
                      })
                      (lib.optionalAttrs (camera.vendorId != null) {
                        "device.vendor.id" = camera.vendorId;
                      })
                      (lib.optionalAttrs (camera.nodeNick != null) {
                        "node.nick" = camera.nodeNick;
                      })
                    ];
                  in
                  # Only create rule if we have at least one match condition
                  lib.optional (matches != [ ]) {
                    inherit matches;
                    actions = {
                      update-props = {
                        "node.description" = "${camera.description}";
                        "priority.session" = camera.priority;
                        "priority.driver" = camera.priority;
                      };
                    };
                  }
                )
                cfg.externalCameras))
              ++
              # Internal camera rule
              (lib.optionals cfg.internalCamera.enable [
                {
                  matches = [
                    { "node.name" = cfg.internalCamera.nodePattern; }
                  ];
                  actions = {
                    update-props = {
                      "node.description" = "Internal Camera (Fallback)";
                      "priority.session" = cfg.internalCamera.priority;
                      "priority.driver" = cfg.internalCamera.priority;
                    };
                  };
                }
              ]);
          };
        };
      };
    };
}
