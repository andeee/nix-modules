{ inputs, ... }:
{
  flake.modules.homeManager.shell = { pkgs, lib, config, ... }: {

    imports = [
      inputs.nix-index-database.homeModules.default
    ];

    options.custom.shell = {
      atuinSyncAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Atuin history sync server. Null keeps atuin local-only, the safe
          default for a shared module — set it in the consuming repo to opt
          into syncing.
        '';
      };
    };

    home.packages = with pkgs; [
      subversion
      ripgrep
      fd
      jq
      libqalculate
    ];

    programs = {
      atuin = {
        enable = true;
        enableZshIntegration = true;
        daemon.enable = true;
        settings = {
          keymap_mode = "vim-insert";
          search_mode = "skim";
          store_failed = false;
          invert = true;
          workspaces = true;
          enter_accept = false;
          ctrl_n_shortcuts = true;
          # try search_mode = "deamon-fuzzy" and this config for future
          # search = {
          #   recency_score_multiplier = 10.0;
          #   frequency_score_multiplier = 0.8;
          #   frecency_score_multiplier = 2.0;
          # };
          keymap.vim-insert = {
            "ctrl-y" = "return-selection";
          };
        } // lib.optionalAttrs (config.custom.shell.atuinSyncAddress != null) {
          sync_address = config.custom.shell.atuinSyncAddress;
        };
      };

      direnv = {
        enable = true;
        nix-direnv.enable = true;
        enableZshIntegration = true;
      };

      nix-index = {
        enable = true;
        enableZshIntegration = true;
      };
      nix-index-database.comma.enable = true;

      nh.enable = true;

      zsh =
        let
          initExtraFirst = lib.mkOrder 500 ''
            ### Added by Zplugin's installer
            ZINIT_HOME="''${XDG_DATA_HOME:-''${HOME}/.local/share}/zinit/zinit.git"
            [ ! -d ''$ZINIT_HOME ] && mkdir -p "$(dirname ''$ZINIT_HOME)"
            [ ! -d ''$ZINIT_HOME/.git ] && git clone https://github.com/zdharma-continuum/zinit.git "''$ZINIT_HOME"
            source "''${ZINIT_HOME}/zinit.zsh"
            autoload -Uz _zinit
            (( ''${+_comps} )) && _comps[zinit]=_zinit
            ### End of Zplugin's installer chunk
          '';
          initExtra = lib.mkOrder 1000 ''
            zinit snippet OMZP::mvn
            zinit light "zdharma/fast-syntax-highlighting"
            zinit light "hkupty/ssh-agent"

            if [[ -n "$IS_WSL" || -n "$WSL_DISTRO_NAME" ]]; then
              unsetopt pathdirs
            fi

            # Load a few important annexes, without Turbo
            # (this is currently required for annexes)
            zinit light-mode for \
              zdharma-continuum/zinit-annex-as-monitor \
              zdharma-continuum/zinit-annex-bin-gem-node \
              zdharma-continuum/zinit-annex-patch-dl \
              zdharma-continuum/zinit-annex-rust

            ### End of Zinit's installer chunk
            if (( $+commands[rbw] ))  then
              eval "$(rbw gen-completions zsh)"
            fi

            alias ducks='du -cks -- * | sort -rn | head'

            # ns <pkg>... [-c <cmd>...] — nix shell with automatic nixpkgs# prefix
            # Accepts multiple packages, e.g. ns python3 nodejs -c python3 script.py
            ns() {
              local -a pkgs=()
              local -a cmd=()
              local after_c=0
              for arg in "$@"; do
                if (( after_c )); then
                  cmd+=("$arg")
                elif [[ "$arg" == "-c" ]]; then
                  after_c=1
                else
                  [[ "$arg" != *"#"* ]] && arg="nixpkgs#$arg"
                  pkgs+=("$arg")
                fi
              done
              if (( ''${#cmd[@]} == 0 )); then
                nix shell "''${pkgs[@]}"
              else
                nix shell "''${pkgs[@]}" -c "''${cmd[@]}"
              fi
            }
          '';
        in
        {
          enable = true;
          defaultKeymap = "viins";
          sessionVariables = {
            EDITOR = "nvim";
            VISUAL = "nvim";
            # Ardour (and other LV2 hosts) use the compiled-in default paths
            # (/usr/lib/lv2 etc.) which don't exist on NixOS. Point them at
            # the nix-profile path so user-installed LV2 plugins are found.
            LV2_PATH = "$HOME/.lv2:$HOME/.nix-profile/lib/lv2:/run/current-system/sw/lib/lv2";
          };
          prezto = {
            enable = true;
            pmodules = [
              "environment"
              "terminal"
              "history"
              "completion"
              "git"
              "editor"
              "directory"
              "spectrum"
            ];
            editor.keymap = "vi";
          };
          initContent = lib.mkMerge [ initExtraFirst initExtra ];
        };

      starship = {
        enable = true;
        enableZshIntegration = true;
      };

      tmux = {
        enable = true;
        baseIndex = 1;
        clock24 = true;
        keyMode = "vi";
        mouse = true;
        historyLimit = 10000;
        shell = "${lib.getExe pkgs.zsh}";
        plugins = with pkgs.tmuxPlugins; [
          {
            plugin = gruvbox;
          }
        ];
        extraConfig = ''
          bind-key -T root -n M-1 select-window -t :=1
          bind-key -T root -n M-2 select-window -t :=2
          bind-key -T root -n M-3 select-window -t :=3
          bind-key -T root -n M-4 select-window -t :=4
          bind-key -T root -n M-5 select-window -t :=5
          bind-key -T root -n M-6 select-window -t :=6
          bind-key -T root -n M-7 select-window -t :=7
          bind-key -T root -n M-8 select-window -t :=8
          bind-key -T root -n M-9 select-window -t :=9
          set -g default-terminal "tmux-256color"
          set -ag terminal-overrides ",xterm-256color:RGB"
          set -g extended-keys on
          set -g extended-keys-format csi-u
        '';
      };
    };
  };
}
