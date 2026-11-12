_:
{
  # power-profiles-daemon + NM dispatcher scripts (wifi/wired exclusive, wireguard-when-away)
  flake.modules.nixos.laptop = { pkgs, lib, ... }: {
    services = {
      power-profiles-daemon.enable = true;
      # Shut down on critical battery instead of hibernating
      upower.criticalPowerAction = "PowerOff";
    };
    networking.networkmanager.dispatcherScripts = [{
      source = pkgs.writeShellScript "wifi-wired-exclusive" ''
        if [[ $# -ne 2 ]]; then
          exit 0
        fi

        INTERFACE=$1
        EVENT=$2

        nmcli_exec() { "${lib.getExe' pkgs.networkmanager "nmcli"}" "$@"; }
        awk_exec()  { "${lib.getExe' pkgs.gawk "awk"}" "$@"; }
        grep_exec() { "${lib.getExe pkgs.gnugrep}" "$@"; }
        echo_exec() { "${lib.getExe' pkgs.coreutils "echo"}" "$@"; }

        ethernet_connected() {
          nmcli_exec dev status | grep_exec -E 'ethernet.*connected' > /dev/null
        }

        iftype=$(
          nmcli_exec -f GENERAL.TYPE device show $1 |
          awk_exec '{print $2}'
        )

        case "$EVENT" in
          up)
            if [[ "$iftype" == "ethernet" ]]; then
              echo_exec "Ethernet up: disabling Wi-Fi radio"
              nmcli_exec radio wifi off
            elif [[ "$iftype" == "wifi" ]]; then
              if ethernet_connected; then
                echo_exec "Wi-Fi up but Ethernet is already connected - disabling Wi-Fi radio"
                nmcli_exec radio wifi off
              fi
            fi
            ;;
          down)
            if [ "$iftype" == "ethernet" ]; then
              echo_exec "Ethernet down: enabling Wi-Fi radio"
              nmcli_exec radio wifi on
            fi
            ;;
          *)
            ;;
        esac

        if [[ "$iftype" == "wifi" && "$(nmcli_exec radio wifi)" == "off" ]]; then
          if ! ethernet_connected; then
            echo_exec "No Ethernet detected and Wi-Fi radio is off - turning it on"
            nmcli_exec radio wifi on
          fi
        fi
      '';
      type = "basic";
    }
      {
        # Reactivated from commit d09f6b3 ("move to tailscale"): bring wg0 up only
        # when NOT on the home LAN, and keep it down at home. Requires
        # `nmcli con mod wg0 connection.autoconnect no` so NM never races it at boot.
        source = pkgs.writeShellScript "enable-wireguard-when-not-at-home" ''
          if [[ $# -ne 2 ]]; then
            exit 0
          fi

          INTERFACE=$1
          EVENT=$2

          nmcli_exec() { "${lib.getExe' pkgs.networkmanager "nmcli"}" "$@"; }
          awk_exec()  { "${lib.getExe' pkgs.gawk "awk"}" "$@"; }
          grep_exec() { "${lib.getExe pkgs.gnugrep}" "$@"; }
          ip_exec()   { "${lib.getExe' pkgs.iproute2 "ip"}" "$@"; }

          # Only act once a device finished coming up
          [[ "$EVENT" == "up" ]] || exit 0

          WG_CONNECTION=$(nmcli_exec -f TYPE,NAME connection show | grep_exec '^wireguard' | awk_exec '{print $2}')
          if [[ -z "$WG_CONNECTION" ]]; then
            exit 0
          fi

          iftype=$(nmcli_exec -f GENERAL.TYPE device show "$INTERFACE" | awk_exec '{print $2}')

          case "$iftype" in
            wifi)
              current_ssid=$(nmcli_exec -f GENERAL.CONNECTION device show "$INTERFACE" | awk_exec '{print $2}')
              if [[ "$current_ssid" == "FBW9" ]]; then
                echo "wireguard-when-away: at home (FBW9) - WireGuard stays down"
                nmcli_exec connection down "$WG_CONNECTION" >/dev/null 2>&1 &
              else
                echo "wireguard-when-away: away ($current_ssid) - bringing WireGuard up"
                nmcli_exec connection up "$WG_CONNECTION" &
              fi
              ;;
            ethernet)
              if ip_exec addr | grep_exec -q 'inet 10\.9\.[0-3]\.'; then
                echo "wireguard-when-away: at home (10.9.0.0/22) - WireGuard stays down"
                nmcli_exec connection down "$WG_CONNECTION" >/dev/null 2>&1 &
              else
                echo "wireguard-when-away: away from home LAN - bringing WireGuard up"
                nmcli_exec connection up "$WG_CONNECTION" &
              fi
              ;;
          esac
        '';
        type = "basic";
      }];
  };
}
