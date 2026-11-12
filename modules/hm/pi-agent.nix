_:
{
  flake.modules.homeManager.pi-agent = { config, lib, pkgs, ... }:
    let
      cfg = config.custom.pi-agent;
      jsonFormat = pkgs.formats.json { };

      mkSettings = configDir: {
        # Provider/model routing is consumer-specific (hosted provider vs. a
        # LAN LLM host), so it comes from options instead of being baked in.
        npmCommand = [
          "env"
          "NPM_CONFIG_PREFIX=~/${configDir}/npm"
          "nix"
          "shell"
          "nixpkgs#nodejs"
          "--command"
          "npm"
        ];
        packages = [
          "npm:pi-web-access"
          "npm:pi-hermes-memory"
        ];
      }
      // lib.optionalAttrs (cfg.defaultProvider != null) { inherit (cfg) defaultProvider; }
      // lib.optionalAttrs (cfg.defaultModel != null) { inherit (cfg) defaultModel; }
      // lib.optionalAttrs (cfg.defaultThinkingLevel != null) { inherit (cfg) defaultThinkingLevel; }
      // lib.optionalAttrs (cfg.theme != null) { inherit (cfg) theme; };

      mcp = {
        mcpServers = {
          context7 = { url = "https://mcp.context7.com/mcp"; };
          nixos = {
            command = "nix";
            args = [
              "run"
              "github:utensils/mcp-nixos"
              "--"
            ];
          };
        };
      };
    in
    {
      options.custom.pi-agent = {
        enable = lib.mkEnableOption "shared pi/pri agent configuration";
        configDir = lib.mkOption {
          type = lib.types.str;
          default = ".pi/agent";
          description = "Directory relative to HOME for agent configuration";
        };
        providers = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        defaultProvider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "pi settings.json defaultProvider; null leaves it unset.";
        };
        defaultModel = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "pi settings.json defaultModel; null leaves it unset.";
        };
        defaultThinkingLevel = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "pi settings.json defaultThinkingLevel; null leaves it unset.";
        };
        theme = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "pi settings.json theme; null leaves it unset.";
        };
        switchyardProvider = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = ''
            Optional pi models.json provider entry for a routing proxy (e.g.
            switchyard on a LAN LLM host). Empty by default so this module
            carries no endpoint of its own; the consuming repo sets it.
          '';
        };
      };

      config = {
        config = lib.mkIf cfg.enable {
          home.file = {
            "${cfg.configDir}/settings.json".source =
              jsonFormat.generate "pi-agent-settings.json" (mkSettings cfg.configDir);
            "${cfg.configDir}/mcp.json".source =
              jsonFormat.generate "pi-agent-mcp.json" mcp;
            "${cfg.configDir}/extensions/opencode-go-quota.ts".source = ./pi-agent/opencode-go-quota.ts;
            "${cfg.configDir}/models.json".source = jsonFormat.generate "pi-agent-models.json" {
              providers = lib.optionalAttrs (cfg.switchyardProvider != { })
                {
                  switchyard = cfg.switchyardProvider;
                } // cfg.providers;
            };
          };
        };
      };
    };
}
