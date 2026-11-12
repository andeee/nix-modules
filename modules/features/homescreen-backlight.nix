_:
{
  flake.modules.nixos.homescreen-backlight = { lib, pkgs, ... }:
    let
      mqttHost = "mqtt.fbw9";
      baseTopic = "homescreen/attention";
      discoveryTopic = "homeassistant/button/homescreen_attention/config";
    in
    {
      environment.systemPackages = [ pkgs.mosquitto ];

      systemd.services.homescreen-attention-listener = {
        description = "Homescreen Attention MQTT Button";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.writeShellScript "homescreen-attention-listener" ''
            set -eu

            MQTT_HOST="${mqttHost}"
            BASE="${baseTopic}"
            BRIGHTNESSCTL="${lib.getExe pkgs.brightnessctl}"
            MOSQUITTO_PUB="${lib.getExe' pkgs.mosquitto "mosquitto_pub"}"
            MOSQUITTO_SUB="${lib.getExe' pkgs.mosquitto "mosquitto_sub"}"

            # Advertise as a stateless button in Home Assistant
            $MOSQUITTO_PUB -h "$MQTT_HOST" -t "${discoveryTopic}" -r -q 1 -m '{
              "name": "Homescreen Attention",
              "unique_id": "homescreen_attention",
              "cmd_t": "'"$BASE"'",
              "payload_press": "PRESS",
              "qos": 1,
              "device": {
                "ids": ["homescreen_pi4"],
                "name": "Homescreen Display",
                "mdl": "Raspberry Pi 4 Touch Display",
                "mf": "Raspberry Pi"
              }
            }'

            # Set initial brightness after boot
            # (swayidle starts later via cage and handles auto-dimming)
            $BRIGHTNESSCTL s 50%

            # Wait for button presses — turn the screen on to get attention
            while read -r payload; do
              case "$payload" in
                "PRESS")
                  $BRIGHTNESSCTL s 50%
                  ;;
              esac
            done < <($MOSQUITTO_SUB -h "$MQTT_HOST" -t "$BASE" -q 1)
          ''}";
          Restart = "always";
          RestartSec = "5s";
          User = "root";
        };
      };
    };
}
