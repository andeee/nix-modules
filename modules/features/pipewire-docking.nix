_:
{
  flake.modules.nixos.pipewire-docking = { lib, config, ... }:
    let
      cfg = config.services.pipewire.docking;
    in
    {
      options.services.pipewire.docking = {
        enable = lib.mkEnableOption "automatic multi-device audio priority management";

        externalDevices = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Device identifier (for documentation/debugging)";
              };

              devicePattern = lib.mkOption {
                type = lib.types.str;
                description = "ALSA device pattern to match (supports ~regex)";
              };

              outputPattern = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Node pattern for output (speakers/headphones)";
              };

              inputPattern = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Node pattern for input (microphone)";
              };

              portIgnorePlug = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Ignore jack detection and always report ports as available";
              };

              outputPriority = lib.mkOption {
                type = lib.types.int;
                default = 2000;
                description = "Priority for output devices (higher = preferred)";
              };

              inputPriority = lib.mkOption {
                type = lib.types.int;
                default = 2000;
                description = "Priority for input devices (higher = preferred)";
              };

              description = lib.mkOption {
                type = lib.types.str;
                description = "Human-readable description";
              };
            };
          });

          default = [ ];
          description = "External audio devices with priority configuration";
        };

        internalAudio = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable internal audio as fallback";
          };

          devicePattern = lib.mkOption {
            type = lib.types.str;
            default = "~alsa_card.pci-.*";
            description = "Pattern to match internal audio device";
          };

          outputPriority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Priority for internal speakers";
          };

          inputPriority = lib.mkOption {
            type = lib.types.int;
            default = 50;
            description = "Priority for internal microphone";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        # Assertion: PipeWire must be enabled
        assertions = [
          {
            assertion = config.services.pipewire.enable;
            message = "PipeWire must be enabled to use pipewire-docking module";
          }
        ];

        services.pipewire.wireplumber.extraConfig = {
          "50-docking-priority" = {
            "monitor.alsa.rules" =
              # External device rules (device-level)
              (lib.lists.flatten (map
                (device: [
                  {
                    matches = [
                      { "device.name" = device.devicePattern; }
                    ];
                    actions = {
                      update-props = {
                        "device.description" = "${device.description}";
                        "priority.driver" = device.outputPriority;
                        "priority.session" = device.outputPriority;
                      };
                    };
                  }
                ])
                cfg.externalDevices))
              ++
              # External device rules (output nodes)
              (lib.lists.flatten (map
                (device:
                  lib.optional (device.outputPattern != null) {
                    matches = [
                      { "node.name" = device.outputPattern; }
                    ];
                    actions = {
                      update-props = {
                        "node.description" = "${device.description} Output";
                        "priority.driver" = device.outputPriority;
                        "priority.session" = device.outputPriority;
                      } // lib.optionalAttrs device.portIgnorePlug {
                        "port.available" = "ignore";
                      };
                    };
                  }
                )
                cfg.externalDevices))
              ++
              # External device rules (input nodes)
              (lib.lists.flatten (map
                (device:
                  lib.optional (device.inputPattern != null) {
                    matches = [
                      { "node.name" = device.inputPattern; }
                    ];
                    actions = {
                      update-props = {
                        "node.description" = "${device.description} Input";
                        "priority.driver" = device.inputPriority;
                        "priority.session" = device.inputPriority;
                      } // lib.optionalAttrs device.portIgnorePlug {
                        "port.available" = "ignore";
                      };
                    };
                  }
                )
                cfg.externalDevices))
              ++
              # Internal audio rules (if enabled)
              (lib.optionals cfg.internalAudio.enable [
                # Internal device
                {
                  matches = [
                    { "device.name" = cfg.internalAudio.devicePattern; }
                  ];
                  actions = {
                    update-props = {
                      "device.description" = "Internal Audio (Fallback)";
                      "priority.driver" = cfg.internalAudio.outputPriority;
                      "priority.session" = cfg.internalAudio.outputPriority;
                    };
                  };
                }
                # Internal outputs
                {
                  matches = [
                    { "node.name" = "~alsa_output.pci-.*"; }
                  ];
                  actions = {
                    update-props = {
                      "node.description" = "Internal Speakers (Fallback)";
                      "priority.driver" = cfg.internalAudio.outputPriority;
                      "priority.session" = cfg.internalAudio.outputPriority;
                    };
                  };
                }
                # Internal inputs
                {
                  matches = [
                    { "node.name" = "~alsa_input.pci-.*"; }
                  ];
                  actions = {
                    update-props = {
                      "node.description" = "Internal Microphone (Fallback)";
                      "priority.driver" = cfg.internalAudio.inputPriority;
                      "priority.session" = cfg.internalAudio.inputPriority;
                    };
                  };
                }
              ]);
          };
        };
      };
    };
}
