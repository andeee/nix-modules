_:
{
  # Low-latency audio configuration for live performance use.
  # Designed for use with a Focusrite Scarlett Solo as the primary
  # audio interface (input and output). Disables power-saving features
  # that cause latency spikes and configures PipeWire for minimum latency.
  #
  # Usage: import nixos.audio-live on hosts used for live performances.
  # This module is intentionally separate from nixos.audio so it can be
  # applied only where needed.
  #
  # Refactored into toggleable tuning groups for empirical validation.
  # Each group can be measured independently; proven defaults are
  # hardcoded after testing. See docs/audio-latency-winterfell-results.md
  # for the measurement procedure and results.
  flake.modules.nixos.audio-live = { config, lib, pkgs, ... }:
    let
      cfg = config.services.audio.live;
    in
    {
      options.services.audio.live = {
        enable = lib.mkEnableOption "low-latency live audio configuration";

        baseline = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Baseline audio-live settings (quantum 128, pro-audio profile, PAM RT, threadirqs)";
        };

        kernelTuning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Kernel boot parameters (preempt=full, nowatchdog, nohz_full)";
        };

        governorTuning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "CPU performance governor";
        };

        sysctlTuning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Sysctl settings (swappiness, inotify)";
        };

        pipewireTuning = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "PipeWire quantum and buffer settings (proven to reduce latency)";
        };

        alsaTuning = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "ALSA period count reduction (proven to improve latency)";
        };

        irqAffinity = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "USB audio IRQ affinity pinning (proven to reduce latency)";
        };
      };

      config = lib.mkIf cfg.enable {
        # statix: services key is assigned multiple times via mkIf conditionals — intentional
        services = lib.mkMerge [
          # --- Baseline: existing audio-live behavior ---
          (lib.mkIf cfg.baseline {
            boot.kernelParams = lib.mkAfter [
              "threadirqs"
              "snd_hda_intel.power_save=0"
              "pcie_aspm.policy=performance"
            ];

            pipewire.extraConfig.pipewire."10-live-performance" = {
              "context.properties" = {
                "default.clock.rate" = 48000;
                "default.clock.allowed-rates" = [ 48000 ];
                "default.clock.quantum" = 128;
                "default.clock.min-quantum" = 64;
                "default.clock.max-quantum" = 256;
              };
            };

            pipewire.wireplumber.extraConfig."50-scarlett-solo-props" = {
              "monitor.alsa.rules" = [
                {
                  matches = [{ "device.name" = "~alsa_card.usb-Focusrite_Scarlett_Solo.*"; }];
                  actions.update-props = {
                    "device.profile" = "pro-audio";
                  };
                }
                {
                  matches = [{ "node.name" = "~alsa_(input|output).usb-Focusrite_Scarlett_Solo.*"; }];
                  actions.update-props = {
                    "audio.rate" = 48000;
                    "api.alsa.headroom" = 0;
                    "session.suspend-timeout-seconds" = 0;
                    "priority.driver" = 300000;
                    "priority.session" = 300000;
                  };
                }
                {
                  matches = [{ "node.name" = "~alsa_(input|output).pci-.*"; }];
                  actions.update-props = {
                    "session.suspend-timeout-seconds" = 5;
                    "node.linger" = false;
                  };
                }
              ];
            };

            security.pam.loginLimits = [
              { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
              { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
              { domain = "@audio"; item = "nofile"; type = "-"; value = "524288"; }
            ];

            users.groups.audio = { };
            users.users.andi.extraGroups = [ "audio" ];
          })

          # --- Kernel tuning ---
          (lib.mkIf cfg.kernelTuning {
            boot.kernelParams = [ "preempt=full" "nowatchdog" "nohz_full=1" ];
          })

          # --- Governor tuning ---
          (lib.mkIf cfg.governorTuning {
            powerManagement.cpuFreqGovernor = "performance";
          })

          # --- Sysctl tuning ---
          (lib.mkIf cfg.sysctlTuning {
            boot.kernel.sysctl = {
              "vm.swappiness" = 10;
              "fs.inotify.max_user_watches" = 524288;
            };
          })

          # --- PipeWire buffer tuning ---
          (lib.mkIf cfg.pipewireTuning {
            pipewire.extraConfig.pipewire."11-buffer-tuning" = {
              "context.properties" = {
                "link.max-buffers" = 16;
              };
            };
          })

          # --- ALSA period tuning ---
          (lib.mkIf cfg.alsaTuning {
            pipewire.wireplumber.extraConfig."51-alsa-period-tuning" = {
              "monitor.alsa.rules" = [
                {
                  matches = [{ "node.name" = "~alsa_(input|output).usb-Focusrite_Scarlett_Solo.*"; }];
                  actions.update-props = {
                    "api.alsa.period-num" = 2;
                  };
                }
              ];
            };
          })
        ];

        # --- IRQ affinity (separate service, not merged) ---
        systemd.services.usb-audio-irq-affinity = lib.mkIf cfg.irqAffinity {
          description = "Pin USB audio IRQ to dedicated CPU core";
          after = [ "multi-user.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeScript "usb-audio-irq-affinity" ''
              #!/bin/sh
              set -e

              # Find xhci_hcd IRQ number
              IRQ=$(grep -m 1 xhci_hcd /proc/interrupts | ${lib.getExe' pkgs.coreutils "tr"} -s ' ' | ${lib.getExe' pkgs.coreutils "cut"} -d' ' -f1 | ${lib.getExe' pkgs.coreutils "tr"} -d ':')

              if [ -n "$IRQ" ] && [ -d "/proc/irq/$IRQ" ]; then
                echo "2" > /proc/irq/$IRQ/smp_affinity
                echo "Pinned xhci_hcd IRQ $IRQ to CPU 1"
              else
                echo "xhci_hcd IRQ not found or not accessible"
                exit 0  # Don't fail if IRQ not found
              fi
            '';
          };
        };
      };
    };
}
