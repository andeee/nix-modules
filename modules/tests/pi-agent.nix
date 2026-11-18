{ inputs, ... }:
{
  # Checks for the `pi-agent` Home Manager module (modules/hm/pi-agent.nix).
  #
  # The module generates JSON and shell strings, so its failure modes are merge
  # order, file placement and quoting — all eval-time or single-derivation
  # problems. No VM: a boot would add minutes and cover nothing here.
  #
  # Every instance is given a *stub* pi. The library has no `llm-agents` input
  # and a check must not introduce one; what is under test is the wrapper's
  # contract (env + PATH + exec passthrough), not pi itself.
  perSystem = { pkgs, lib, ... }:
    let
      stubPi = pkgs.writeShellScriptBin "pi" ''
        echo "agentDir=''${PI_CODING_AGENT_DIR-<unset>}"
        echo "sessionDir=''${PI_CODING_AGENT_SESSION_DIR-<unset>}"
        echo "greeting=''${GREETING-<unset>}"
        echo "args=$*"
        if command -v jq >/dev/null; then echo "jq=yes"; else echo "jq=no"; fi
      '';

      base = {
        home = {
          username = "tester";
          homeDirectory = "/home/tester";
          stateVersion = "26.05";
        };
      };

      # One fixture that exercises every generator (settings, models, mcp,
      # bundled extension, `files`, wrapper env/PATH), plus a values-only
      # instance that must stay inert because `enable` defaults to false.
      hmConfig = (inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          inputs.self.homeManagerModules.pi-agent
          base
          {
            custom.pi-agents.t = {
              enable = true;
              package = stubPi;
              configDir = ".t/agent";
              wrapperName = "tpi";
              # A dedicated option and the same key in `settings`: the latter
              # must win, and that precedence is easy to invert by refactoring.
              theme = "from-option";
              settings.theme = "from-settings";
              settings.enabledModels = [ "a/b" ];
              providers.example = {
                api = "openai-completions";
                baseUrl = "http://127.0.0.1:1/v1";
              };
              bundledExtensions = [ "opencode-go-quota" ];
              # `$()` proves extraEnv is expanded by the shell at run time,
              # which is what lets consumers read sops secrets without an option.
              extraEnv.GREETING = "hi $(echo there)";
              extraPackages = [ pkgs.jq ];
              files."themes/t.json" = pkgs.writeText "pi-test-theme.json" "{ }";
            };

            custom.pi-agents.off = {
              package = stubPi;
              configDir = ".off/agent";
            };
          }
        ];
      }).config;

      settings = builtins.fromJSON (builtins.readFile hmConfig.home.file.".t/agent/settings.json".source);
      piFiles = lib.filter (path: lib.hasPrefix "." path) (lib.attrNames hmConfig.home.file);
      wrapper = lib.findFirst (package: package.name == "tpi")
        (throw "pi-agent test fixture produced no `tpi` wrapper")
        hmConfig.home.packages;

      # Eval-only assertion rendered as a buildable no-op, so each property
      # shows up as its own named check instead of one opaque failure.
      checked = name: problems:
        if problems == [ ] then
          pkgs.runCommand name { } "touch $out"
        else
          throw "${name}: ${lib.concatStringsSep "; " problems}";

      # Negative cases run through tryEval, which swallows *any* eval error —
      # hence the valid control in the list: without it a typo in the harness
      # itself would make every "must fail" case pass.
      evaluatesWith = extra:
        (builtins.tryEval (inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            inputs.self.homeManagerModules.pi-agent
            base
            { custom.pi-agents.a = { enable = true; package = stubPi; }; }
            extra
          ];
        }).activationPackage).success;

      assertionCases = [
        {
          name = "valid control evaluates";
          expect = true;
          config = {
            custom.pi-agents.b = {
              enable = true;
              package = stubPi;
              configDir = ".b/agent";
              wrapperName = "bpi";
            };
          };
        }
        {
          name = "shared configDir rejected";
          expect = false;
          config.custom.pi-agents.b = {
            enable = true;
            package = stubPi;
            wrapperName = "bpi";
          };
        }
        {
          name = "absolute configDir rejected";
          expect = false;
          config.custom.pi-agents.b = {
            enable = true;
            package = stubPi;
            configDir = "/absolute";
          };
        }
        {
          name = "duplicate wrapperName rejected";
          expect = false;
          config.custom.pi-agents.b = {
            enable = true;
            package = stubPi;
            configDir = ".b/agent";
            wrapperName = "a";
          };
        }
      ];

      mergeProblems =
        lib.optional (settings.theme != "from-settings")
          "settings.theme must win over the theme option, got ${settings.theme}"
        ++ lib.optional (settings.enabledModels != [ "a/b" ])
          "settings.enabledModels did not reach settings.json"
        ++ lib.optional (!(builtins.elem "npm:pi-web-access" settings.packages))
          "default packages list is missing its default entries";
    in
    {
      checks = {
        pi-agent-files = checked "pi-agent-files" (
          lib.optional
            (piFiles != [
              ".t/agent/extensions/opencode-go-quota.ts"
              ".t/agent/mcp.json"
              ".t/agent/models.json"
              ".t/agent/settings.json"
              ".t/agent/themes/t.json"
            ]) "unexpected file set: ${builtins.toJSON piFiles}"
        );

        pi-agent-wrapper = pkgs.runCommand "pi-agent-wrapper" { } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          got=$(${wrapper}/bin/tpi --foo bar)
          echo "$got"

          grep -qx "agentDir=$HOME/.t/agent" <<<"$got"
          # Sessions live under the agent dir, so no override may be set.
          grep -qx "sessionDir=<unset>" <<<"$got"
          grep -qx "greeting=hi there" <<<"$got"
          grep -qx "args=--foo bar" <<<"$got"
          grep -qx "jq=yes" <<<"$got"

          touch $out
        '';

        pi-agent-merge-precedence = checked "pi-agent-merge-precedence" mergeProblems;

        pi-agent-assertions = checked "pi-agent-assertions" (
          map (case: "${case.name} (expected evaluates=${toString case.expect})")
            (lib.filter (case: evaluatesWith case.config != case.expect) assertionCases)
        );
      };
    };
}
