_:
{
  flake.modules.nixos.audio = { pkgs, lib, config, ... }: {
    options.services.pipewire.deepfilter.enable = lib.mkEnableOption
      "DeepFilter ML noise cancellation filter-chain node";

    config = {
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;
        raopOpenFirewall = true;
        extraLadspaPackages = [ pkgs.deepfilternet ];
        extraConfig.pipewire = {
          "99-raop-discover" = {
            "context.modules" = [{
              name = "libpipewire-module-raop-discover";
              args = { };
            }];
          };
        } // lib.optionalAttrs config.services.pipewire.deepfilter.enable {
          "99-input-denoising" = {
            "context.modules" = [{
              "name" = "libpipewire-module-filter-chain";
              "args" = {
                "node.description" = "DeepFilter Noise Cancelling Source";
                "media.name" = "DeepFilter Noise Cancelling Source";
                "filter.graph" = {
                  "nodes" = [
                    {
                      "type" = "ladspa";
                      "name" = "DeepFilter Mono";
                      "plugin" = "libdeep_filter_ladspa";
                      "label" = "deep_filter_mono";
                    }
                  ];
                };
                "audio.rate" = 48000;
                "capture.props" = {
                  "node.name" = "deep_filter_mono_input";
                  "node.passive" = true;
                };
                "playback.props" = {
                  "node.name" = "deep_filter_mono_output";
                  "media.class" = "Audio/Source";
                  # Smart filter: follow the default source (dock headset mic
                  # at the office, Scarlett at home) and relink automatically
                  # when the default source changes. Without this the filter
                  # input gets pinned to whatever source was default when
                  # PipeWire started (usually the internal mic).
                  "filter.smart" = true;
                };
              };
            }];
          };
        };
      };
      services.avahi.enable = true;
    };
  };
}
