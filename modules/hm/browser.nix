_:
{
  flake.modules.homeManager.browser = { pkgs, lib, config, ... }:
    let
      cfg = config.custom.browser;
      # wrap the userscript so it finds its tools from the store — no reliance on the host's PATH
      # The userscript itself is repo-local (it carries the user's Kindle address),
      # so it is injected through `custom.browser.sendToKindleScript`.
      sendToKindle = pkgs.writeShellScriptBin "send-to-kindle" (
        ''
          export PATH="${lib.makeBinPath [ pkgs.readability-cli pkgs.pandoc pkgs.mutt pkgs.wl-clipboard pkgs.coreutils ]}:$PATH"
        ''
        + builtins.readFile cfg.sendToKindleScript
      );
    in
    {
      options.custom.browser = {
        sendToKindleScript = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = ''
            Path to a send-to-kindle qutebrowser userscript. Null disables the
            Kindle bindings — the script holds a personal mail address, so it
            stays in the consuming repo instead of this library.
          '';
        };
      };

      config = {
        home.sessionVariables = {
          MPV_FLAGS = "--quiet --ytdl";
          QTWEBENGINE_FORCE_USE_GBM = "0";
        };

        programs.qutebrowser = {
          enable = true;
          keyBindings = {
            normal = {
              "xv" = "spawn --userscript view_in_mpv";
              ";v" = "hint links userscript view_in_mpv";
              "td" = "config-cycle -t -p colors.webpage.darkmode.enabled";
            } // lib.optionalAttrs (cfg.sendToKindleScript != null) {
              "xk" = "spawn --userscript send-to-kindle";
              ";k" = "hint links userscript send-to-kindle";
            };
            command = {
              "<Ctrl+p>" = "completion-item-focus prev";
              "<Ctrl+n>" = "completion-item-focus next";
              "<Ctrl+y>" = "command-accept";
            };
          };
          package = pkgs.callPackage ../../packages/qutebrowser { };
          settings = {
            auto_save.session = true;
            zoom.default = lib.mkDefault "100%";
            input.media_keys = true;
            fonts.web.size.default = lib.mkForce 16;
            tabs.select_on_remove = "last-used";
            content.javascript.clipboard = "access";
            colors.webpage.darkmode = {
              policy.images = "smart-simple";
              threshold = {
                foreground = 150;
                background = 205;
              };
            };
            editor.command = [ "foot" "-T" "auxiliary text edit" "nvim" "{file}" "+startinsert" "+call cursor({line} {column})" ];
            qt.args = [ "disable-features=WebAuth" "force-renderer-accessibility" ];
          };
          extraConfig = ''
        '';
        };
        xdg = {
          dataFile = lib.optionalAttrs (cfg.sendToKindleScript != null) {
            "qutebrowser/userscripts/send-to-kindle" = {
              source = "${sendToKindle}/bin/send-to-kindle";
              executable = true;
            };
          };
          mimeApps = {
            enable = true;
            defaultApplications = {
              "text/html" = "org.qutebrowser.qutebrowser.desktop";
              "x-scheme-handler/http" = "qutebrowser-handler.desktop";
              "x-scheme-handler/https" = "qutebrowser-handler.desktop";
              "x-scheme-handler/about" = "org.qutebrowser.qutebrowser.desktop";
              "x-scheme-handler/unknown" = "org.qutebrowser.qutebrowser.desktop";
            };
          };
          desktopEntries = {
            qutebrowser-handler = {
              name = "Qutebrowser Handler";
              genericName = "Web Browser Handler";
              exec = ''zsh ${./qutebrowser/handler.sh} %u'';
              terminal = false;
              categories = [ ];
              mimeType = [ "x-scheme-handler/http" "x-scheme-handler/https" ];
            };
          };
          configFile."mimeapps.list".force = true;
        };
      };
    };
}
