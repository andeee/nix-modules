_:
{
  # Multiple pi instances per user. Each instance owns a config directory
  # (`<agent-dir>`) AND its wrapper binary, because pi picks its config dir
  # only from `PI_CODING_AGENT_DIR` (docs/environment-variables.md) — writing
  # files alone leaves the caller to hand-write the wrapper, which is exactly
  # the duplication this module exists to remove.
  #
  # Consumers supply `package`: pi is not a nixpkgs attribute this library can
  # name (`pkgs.llm-agents.pi` in the work repo, `inputs.llm-agents.packages`
  # in the private one), so there is deliberately no default.
  #
  # Secrets stay consumer-side: `extraEnv` values are exported verbatim inside
  # double quotes, so `"$(cat ${path})"` works and no sops option is needed.
  flake.modules.homeManager.pi-agent = { config, lib, pkgs, ... }:
    let
      cfg = config.custom.pi-agents;
      jsonFormat = pkgs.formats.json { };

      # Enabled instances only; a values-only module (shared defaults, host
      # flips `enable`) must not touch the filesystem.
      instances = lib.filterAttrs (_: inst: inst.enable) cfg;

      # Extension sources shipped *with this module*. Consumers cannot reference
      # these paths themselves (they live in the library's store copy), so they
      # opt in by name.
      bundledExtensions = {
        opencode-go-quota = ./pi-agent/opencode-go-quota.ts;
      };

      mkSettings = inst:
        {
          # `packages`/`npmCommand` are generated because they interpolate the
          # instance's config dir, which a static option default cannot do.
          npmCommand =
            if inst.npmCommand != null then
              inst.npmCommand
            else
              [
                "env"
                "NPM_CONFIG_PREFIX=~/${inst.configDir}/npm"
                "nix"
                "shell"
                "nixpkgs#nodejs"
                "--command"
                "npm"
              ];
          inherit (inst) packages;
        }
        // lib.filterAttrs (_: v: v != null) {
          inherit (inst) defaultProvider defaultModel defaultThinkingLevel theme;
        }
        # Freeform escape hatch for everything without a dedicated option
        # (enabledModels, defaultTools, compaction, cacheWarming, ...).
        # Wins over the options above when a key appears in both.
        // inst.settings;

      mkWrapper = inst: pkgs.writeShellScriptBin inst.wrapperName ''
        export PI_CODING_AGENT_DIR="$HOME/${inst.configDir}"
        ${lib.optionalString (inst.sessionDir != null) ''
          export PI_CODING_AGENT_SESSION_DIR="$HOME/${inst.sessionDir}"
        ''}
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: ''export ${name}="${value}"'') inst.extraEnv
        )}
        ${lib.optionalString (inst.extraPackages != [ ]) ''
          export PATH="${lib.makeBinPath inst.extraPackages}:$PATH"
        ''}
        exec ${lib.getExe inst.package} "$@"
      '';

      # home.file keys its entries by path, so two enabled instances sharing a
      # config dir or a wrapper name silently fight (or collide in the profile).
      duplicateOf = attr: set:
        let
          values = map attr (lib.attrValues set);
          counted = lib.foldl'
            (acc: value: acc // { ${value} = (acc.${value} or 0) + 1; })
            { }
            values;
        in
        lib.attrNames (lib.filterAttrs (_: count: count > 1) counted);

      duplicateDirs = duplicateOf (inst: inst.configDir) instances;
      duplicateWrappers = duplicateOf (inst: inst.wrapperName) instances;
    in
    {
      options.custom.pi-agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Materialize this instance's config files and wrapper. Default
                false so a shared module can declare values and each host decides
                whether the instance exists there.
              '';
            };

            configDir = lib.mkOption {
              type = lib.types.str;
              default = ".pi/agent";
              example = ".pri/agent";
              description = ''
                Agent directory relative to `$HOME`, i.e. what
                `PI_CODING_AGENT_DIR` points at. Pi also keeps `auth.json`,
                `sessions/`, `themes/` and `skills/` here, so each instance is
                fully isolated.
              '';
            };

            package = lib.mkOption {
              type = lib.types.package;
              description = ''
                The pi binary to wrap. No default: pi comes from a flake input
                the consumer owns. Must set `meta.mainProgram`.
              '';
            };

            wrapperName = lib.mkOption {
              type = lib.types.str;
              default = name;
              defaultText = lib.literalExpression "<instance name>";
              example = "pri";
              description = "Name of the generated wrapper binary.";
            };

            install = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Add the wrapper to `home.packages`. Turn off when the consumer
                already provides a binary with the same name.
              '';
            };

            force = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Overwrite an existing file in the agent directory. Pi's
                `/settings` writes `settings.json` itself; `true` keeps the
                declarative config authoritative across switches.
              '';
            };

            providers = lib.mkOption {
              inherit (jsonFormat) type;
              default = { };
              example = {
                switchyard = {
                  api = "openai-completions";
                  apiKey = "none";
                  baseUrl = "http://llm.fbw9:8888/v1";
                  models = [{ id = "general"; }];
                };
              };
              description = ''
                `models.json` providers. No `models.json` is written when empty,
                so a hand-managed one is left alone.
              '';
            };

            settings = lib.mkOption {
              inherit (jsonFormat) type;
              default = { };
              description = ''
                Extra `settings.json` keys, merged last. Use it for anything
                without a dedicated option: `enabledModels`, `defaultTools`,
                `compaction.*`, `cacheWarming`, `$schema`, ...
              '';
            };

            mcpServers = lib.mkOption {
              inherit (jsonFormat) type;
              default = {
                context7 = { url = "https://mcp.context7.com/mcp"; };
                nixos = {
                  command = "nix";
                  args = [ "run" "github:utensils/mcp-nixos" "--" ];
                };
              };
              defaultText = lib.literalExpression ''{ context7, nixos }'';
              description = ''
                `mcp.json` servers. Defaults to the library's two generic ones;
                `lib.mkForce { }` drops them.
              '';
            };

            packages = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "npm:pi-web-access"
                "npm:pi-hermes-memory"
              ];
              description = ''
                `settings.json` pi packages (npm specifiers), installed into
                `<configDir>/npm`.
              '';
            };

            npmCommand = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = ''
                Override the npm invocation used to install `packages`. Null
                generates one with `NPM_CONFIG_PREFIX=~/<configDir>/npm`.
              '';
            };

            defaultProvider = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "`settings.json` defaultProvider; null leaves it unset.";
            };

            defaultModel = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "`settings.json` defaultModel; null leaves it unset.";
            };

            defaultThinkingLevel = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "`settings.json` defaultThinkingLevel; null leaves it unset.";
            };

            theme = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "`settings.json` theme; null leaves it unset.";
            };

            sessionDir = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Override `PI_CODING_AGENT_SESSION_DIR`. Radioactive by default:
                pi already stores sessions under `<configDir>/sessions`, so this
                is only for deliberately sharing or relocating history.
              '';
            };

            extensions = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              default = [ ];
              description = ''
                Extension files copied into `<configDir>/extensions/`. Importing
                from a flake input works: `extensions = [ input.pkg.ext ];`.
              '';
            };

            bundledExtensions = lib.mkOption {
              type = lib.types.listOf (lib.types.enum (lib.attrNames bundledExtensions));
              default = [ ];
              example = [ "opencode-go-quota" ];
              description = ''
                Extensions shipped with this module, opted into by name
                (the paths live in the library, not in the consumer).
              '';
            };

            files = lib.mkOption {
              type = lib.types.attrsOf lib.types.path;
              default = { };
              example = {
                "themes/private-theme.json" = ./theme.json;
                "keybindings.json" = ./keybindings.json;
                "AGENTS.md" = ./AGENTS.md;
              };
              description = ''
                Arbitrary extra files, placed relative to the agent directory.
                Covers `themes/`, `keybindings.json`, `AGENTS.md`,
                `APPEND_SYSTEM.md`, `skills/` without an option per file type.
              '';
            };

            extraEnv = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              example = {
                OPENCODE_API_KEY = "$(cat /run/secrets/opencode-api-key)";
              };
              description = ''
                Environment exported by the wrapper. Values are expanded by the
                shell at run time, so `$(cat …)` reads a sops secret without this
                module knowing about sops.
              '';
            };

            extraPackages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              example = lib.literalExpression "with pkgs; [ poppler-utils pandoc fzf ]";
              description = ''
                Packages prepended to the wrapper's `PATH` for tools that
                extensions or bash calls expect to find.
              '';
            };
          };
        }));

        default = { };
        description = ''
          Named pi instances for this user. Each one gets an isolated agent
          directory plus a wrapper binary that sets `PI_CODING_AGENT_DIR`:

          ```nix
          custom.pi-agents.pi  = { enable = true; package = llmAgents.pi; };
          custom.pi-agents.pri = {
            enable = true;
            package = llmAgents.pi;
            configDir = ".pri/agent";
          };
          ```
        '';
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = duplicateDirs == [ ];
              message = "custom.pi-agents: configDir shared by several instances: "
                + lib.concatStringsSep ", " duplicateDirs;
            }
            {
              assertion = duplicateWrappers == [ ];
              message = "custom.pi-agents: wrapperName used by several instances: "
                + lib.concatStringsSep ", " duplicateWrappers;
            }
            {
              assertion = lib.all (inst: !(lib.hasPrefix "/" inst.configDir)) (lib.attrValues cfg);
              message = "custom.pi-agents: configDir must be relative to \$HOME.";
            }
          ];
        }

        (lib.mkIf (instances != { }) {
          home.packages = map mkWrapper (
            lib.attrValues (lib.filterAttrs (_: inst: inst.install) instances)
          );

          home.file = lib.mkMerge (lib.mapAttrsToList
            (name: inst:
              let
                dir = inst.configDir;
                entry = source: { inherit (inst) force; inherit source; };
              in
              {
                "${dir}/settings.json" = entry (jsonFormat.generate "pi-${name}-settings.json" (mkSettings inst));
                "${dir}/mcp.json" = entry (jsonFormat.generate "pi-${name}-mcp.json" {
                  inherit (inst) mcpServers;
                });
              }
              // lib.optionalAttrs (inst.providers != { }) {
                "${dir}/models.json" = entry (jsonFormat.generate "pi-${name}-models.json" {
                  inherit (inst) providers;
                });
              }
              // lib.listToAttrs (map
                (extension: lib.nameValuePair "${dir}/extensions/${baseNameOf (toString extension)}" (entry extension))
                (inst.extensions
                ++ map (extension: bundledExtensions.${extension}) inst.bundledExtensions))
              // lib.mapAttrs' (path: source: lib.nameValuePair "${dir}/${path}" (entry source)) inst.files
            )
            instances);
        })
      ];
    };
}
