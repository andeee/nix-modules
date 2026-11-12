_:
{
  flake.modules.homeManager.desktop-base = { inputs, pkgs, lib, config, osConfig, ... }:
    let
      mkMenu = menu:
        let
          configFile = pkgs.writeText "config.yaml"
            (lib.generators.toYAML { } {
              anchor = "bottom-right";
              inherit menu;
            });
        in
        pkgs.writeShellScriptBin "my-menu" ''
          exec ${lib.getExe pkgs.wlr-which-key} ${configFile}
        '';
      inherit (inputs.niri-float-sticky.packages.${pkgs.stdenv.hostPlatform.system}) niri-float-sticky;
      niri = lib.getExe config.programs.niri.package;
      xargs = lib.getExe' pkgs.findutils "xargs";
      jq = lib.getExe pkgs.jq;
      focus-urgent = pkgs.writeShellScriptBin "focus-urgent" ''
        ${niri} msg -j event-stream | \
          ${jq} --unbuffered -r '.WindowUrgencyChanged | select(. != null) | .id' | \
          ${xargs} -I{} ${niri} msg action focus-window --id {} && ${niri} msg unset-window-urgent --id {}
      '';
      neru = lib.getExe osConfig.services.neru.package;
    in
    {
      imports = [
        inputs.wayland-pipewire-idle-inhibit.homeModules.default
        inputs.dankMaterialShell.homeModules.dank-material-shell
        inputs.dankMaterialShell.homeModules.niri
      ];
      home.packages = with pkgs; [
        wtype
        rofi-rbw
        xwayland-satellite-stable
        nautilus
        satty
      ];

      programs = {
        niri = {
          settings = {
            environment = {
              DMS_SCREENSHOT_EDITOR = "satty";
              GDK_BACKEND = "wayland,x11";
            };
            input = {
              keyboard.xkb = {
                layout = "us";
                options = "compose:ralt,caps:swapescape";
              };
              touchpad.dwt = true;
            };
            cursor = {
              hide-when-typing = true;
              hide-after-inactive-ms = 1000;
            };
            hotkey-overlay.skip-at-startup = true;
            layout = {
              gaps = 10;
              center-focused-column = "never";
              always-center-single-column = true;
              default-column-width = { proportion = 0.5; };
              focus-ring = {
                enable = false;
              };
              border = {
                enable = true;
                width = 2;
              };
              shadow = {
                enable = lib.mkDefault true;
                softness = 30;
                spread = 5;
                offset = { x = 5; y = 5; };
              };
              background-color = "transparent";
            };
            prefer-no-csd = true;
            screenshot-path = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png";
            animations = { };
            spawn-at-startup = [
              { command = [ (lib.getExe niri-float-sticky) "-app-id" ''^mpv$'' "-app-id" ''^it\.catboy\.ripdrag$'' ]; }
              { command = [ (lib.getExe focus-urgent) ]; }
            ];
            layer-rules = [
              {
                matches = [{ namespace = "^notifications$"; }];
                block-out-from = "screen-capture";
              }
              {
                matches = [{ namespace = "^rofi$"; }];
                block-out-from = "screen-capture";
                opacity = 0.85;
              }
              {
                matches = [
                  { namespace = "^dms:bar$"; }
                  { namespace = "^dms:clipboard$"; }
                ];
                block-out-from = "screen-capture";
                opacity = 0.85;
              }
              {
                matches = [{ namespace = "^quickshell$"; }];
                place-within-backdrop = true;
              }
              {
                matches = [{ namespace = "dms:blurwallpaper"; }];
                place-within-backdrop = true;
              }
            ];
            window-rules = [
              {
                matches = [
                  { app-id = ''^org\.keepassxc\.KeePassXC$''; }
                  { app-id = ''^org\.gnome\.World\.Secrets$''; }
                  { app-id = ''^mpv$''; }
                  { app-id = ''^signal$''; }
                ];
                block-out-from = "screencast";
              }
              {
                matches = [
                  { app-id = ''^mpv$''; }
                ];
                open-floating = true;
                default-floating-position = { relative-to = "bottom-right"; x = 50; y = 50; };
                default-column-width = { fixed = 640; };
                default-window-height = { fixed = 360; };
                opacity = 0.85;
              }
            ];
            binds = with config.lib.niri.actions;
              let
                dms-ipc = spawn "dms" "ipc" "call";
              in
              {
                "Mod+Shift+Slash".action = show-hotkey-overlay;
                "Mod+Return".action = spawn "foot";
                "Mod+D".action = spawn "rofi" "-show" "combi" "-modes" "combi" "-combi-modes" "drun,run,window";

                "Super+Alt+L".action = dms-ipc "lock" "lock";

                "XF86AudioRaiseVolume" = { allow-when-locked = true; action = dms-ipc "audio" "increment" "5"; };
                "XF86AudioLowerVolume" = { allow-when-locked = true; action = dms-ipc "audio" "decrement" "5"; };
                "XF86AudioMute" = { allow-when-locked = true; action = dms-ipc "audio" "mute"; };
                "XF86AudioMicMute" = { allow-when-locked = true; action = dms-ipc "audio" "micmute"; };
                "XF86AudioPlay" = { allow-when-locked = true; action = dms-ipc "mpris" "playPause"; };
                "XF86AudioNext" = { allow-when-locked = true; action = dms-ipc "mpris" "next"; };
                "XF86AudioPrev" = { allow-when-locked = true; action = dms-ipc "mpris" "previous"; };
                "XF86MonBrightnessUp" = { allow-when-locked = true; action = dms-ipc "brightness" "increment" "5" ""; };
                "XF86MonBrightnessDown" = { allow-when-locked = true; action = dms-ipc "brightness" "decrement" "5" ""; };

                "Mod+Shift+Q".action = close-window;

                "Mod+Left".action = focus-column-left;
                "Mod+Down".action = focus-window-down;
                "Mod+Up".action = focus-window-up;
                "Mod+Right".action = focus-column-right;
                "Mod+H".action = focus-column-left;
                "Mod+J".action = focus-window-or-workspace-down;
                "Mod+K".action = focus-window-or-workspace-up;
                "Mod+L".action = focus-column-right;

                "Mod+Shift+Left".action = move-column-left;
                "Mod+Shift+Down".action = move-window-down-or-to-workspace-down;
                "Mod+Shift+Up".action = move-window-up-or-to-workspace-up;
                "Mod+Shift+Right".action = move-column-right;
                "Mod+Shift+H".action = move-column-left;
                "Mod+Shift+J".action = move-window-down-or-to-workspace-down;
                "Mod+Shift+K".action = move-window-up-or-to-workspace-up;
                "Mod+Shift+L".action = move-column-right;

                "Mod+Home".action = focus-column-first;
                "Mod+End".action = focus-column-last;
                "Mod+Shift+Home".action = move-column-to-first;
                "Mod+Shift+End".action = move-column-to-last;

                "Mod+Page_Down".action = focus-workspace-down;
                "Mod+Page_Up".action = focus-workspace-up;
                "Mod+I".action = focus-workspace-down;
                "Mod+U".action = focus-workspace-up;
                "Mod+Ctrl+Page_Down".action = move-column-to-workspace-down;
                "Mod+Ctrl+Page_Up".action = move-column-to-workspace-up;
                "Mod+Ctrl+I".action = move-column-to-workspace-down;
                "Mod+Ctrl+U".action = move-column-to-workspace-up;

                "Mod+Shift+Page_Down".action = move-workspace-down;
                "Mod+Shift+Page_Up".action = move-workspace-up;
                "Mod+Shift+I".action = move-workspace-down;
                "Mod+Shift+U".action = move-workspace-up;

                "Mod+1".action = focus-workspace 1;
                "Mod+2".action = focus-workspace 2;
                "Mod+3".action = focus-workspace 3;
                "Mod+4".action = focus-workspace 4;
                "Mod+5".action = focus-workspace 5;
                "Mod+6".action = focus-workspace 6;
                "Mod+7".action = focus-workspace 7;
                "Mod+8".action = focus-workspace 8;
                "Mod+9".action = focus-workspace 9;
                "Mod+Shift+1".action.move-column-to-workspace = 1;
                "Mod+Shift+2".action.move-column-to-workspace = 2;
                "Mod+Shift+3".action.move-column-to-workspace = 3;
                "Mod+Shift+4".action.move-column-to-workspace = 4;
                "Mod+Shift+5".action.move-column-to-workspace = 5;
                "Mod+Shift+6".action.move-column-to-workspace = 6;
                "Mod+Shift+7".action.move-column-to-workspace = 7;
                "Mod+Shift+8".action.move-column-to-workspace = 8;
                "Mod+Shift+9".action.move-column-to-workspace = 9;

                "Mod+BracketLeft".action = consume-or-expel-window-left;
                "Mod+BracketRight".action = consume-or-expel-window-right;

                "Mod+Comma".action = consume-window-into-column;
                "Mod+Period".action = expel-window-from-column;

                "Mod+R".action = switch-preset-column-width;
                "Mod+Shift+R".action = switch-preset-window-height;
                "Mod+Ctrl+R".action = reset-window-height;
                "Mod+F".action = maximize-column;
                "Mod+Shift+F".action = fullscreen-window;

                "Mod+Ctrl+F".action = expand-column-to-available-width;

                "Mod+C".action = center-column;
                "Mod+Minus".action = set-column-width "-10%";
                "Mod+Equal".action = set-column-width "+10%";

                "Mod+Shift+Minus".action = set-window-height "-10%";
                "Mod+Shift+Equal".action = set-window-height "+10%";

                "Mod+T".action = toggle-window-floating;
                "Mod+S".action = switch-focus-between-floating-and-tiling;

                "Mod+W".action = toggle-column-tabbed-display;

                "Print".action = dms-ipc "niri" "screenshot";
                "Ctrl+Print".action = dms-ipc "niri" "screenshotScreen";
                "Alt+Print".action = dms-ipc "niri" "screenshotWindow";

                "Mod+Escape" = {
                  allow-inhibiting = false;
                  action = toggle-keyboard-shortcuts-inhibit;
                };

                "Mod+Shift+E".action = dms-ipc "powermenu" "open";
                "Ctrl+Alt+Delete".action = quit;

                "Mod+P".action = spawn "rofi-rbw";

                "Mod+Shift+S".action = dms-ipc "niri" "screenshot";
                "Mod+Shift+V".action = dms-ipc "clipboard" "toggle";
                "Mod+E".action = spawn "rofi" "-modi" "emoji" "-show" "emoji";

                "Mod+X".action = dms-ipc "notifications" "dismissAllPopups";

                "Mod+M".action = spawn (lib.getExe (mkMenu [
                  { key = "space"; desc = "Play/Pause"; cmd = "dms ipc mpris playPause"; }
                  { key = "n"; desc = "Next"; cmd = "dms ipc mpris next"; }
                  { key = "p"; desc = "Previous"; cmd = "dms ipc mpris previous"; }
                ]));

                "Mod+semicolon".action = spawn neru "hints";
                "Mod+apostrophe".action = spawn neru "bisect" "--cursor-selection-mode" "hold";
              };
          };
        };

        dank-material-shell = {
          enable = true;
          systemd.enable = true;
          niri = {
            includes.enable = false;
          };
          settings = {
            matugenScheme = "scheme-tonal-spot";
            showOccupiedWorkspacesOnly = true;
            showWorkspaceApps = true;
            showWorkspaceIndex = true;
            workspaceDragReorder = false;
            maxWorkspaceIcons = 5;
            groupWorkspaceApps = false;
            launcherLogoMode = "os";
            lockBeforeSuspend = true;
            acProfileName = "2";
            acLockTimeout = 300;
            batteryProfileName = "0";
            batteryLockTimeout = 300;
            osdPowerProfileEnabled = true;
            configVersion = 13;
          };
          session = {
            wallpaperPath = "${config.stylix.image}";
            weatherLocation = "Viehhausen, 5071";
            weatherCoordinates = "47.7833407,12.9875478";
            nightModeEnabled = true;
            nightModeTemperature = 4500;
            nightModeHighTemperature = 6500;
            nightModeAutoEnabled = true;
            nightModeAutoMode = "location";
            latitude = 47.7833407;
            longitude = 12.9875478;
            configVersion = 3;
          };
        };

        foot = {
          enable = true;
          settings = {
            main = {
              term = "xterm-256color";
            };
            scrollback = {
              lines = 10000;
            };
          };
        };

        rofi = {
          enable = true;
          plugins = [
            pkgs.rofi-emoji
          ];
        };
      };

      services = {
        wayland-pipewire-idle-inhibit = {
          enable = lib.mkDefault true;
          systemdTarget = "graphical-session.target";
          settings = {
            verbosity = "INFO";
            media_minimum_duration = 10;
            idle_inhibitor = "wayland";
            sink_whitelist = [ ];
            node_blacklist = [
              { name = "spotify"; }
              { name = "[Ss]queeze[lL]ite"; }
            ];
          };
        };

        cliphist = {
          enable = true;
          systemdTargets = "graphical-session.target";
        };

        playerctld = {
          enable = true;
        };

        kanshi = {
          systemdTarget = "graphical-session.target";
          enable = true;
        };
      };

      gtk = {
        enable = true;
      };

      stylix = {
        cursor = {
          package = pkgs.capitaine-cursors-themed;
          name = "Capitaine Cursors (Gruvbox)";
          size = 32;
        };
        icons = {
          enable = true;
          package = pkgs.adwaita-icon-theme;
          light = "Adwaita";
          dark = "Adwaita";
        };
      };

      qt = {
        enable = true;
      };

      systemd.user = {
        startServices = true;
        services.polkit-gnome-authentication-agent-1 = {
          Unit = {
            Description = "polkit-gnome-authentication-agent-1";
            Wants = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Install = {
            WantedBy = [ "graphical-session.target" ];
          };
          Service = {
            Type = "simple";
            ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
            Restart = "on-failure";
            RestartSec = 1;
            TimeoutStopSec = 10;
          };
        };
      };
    };
}
