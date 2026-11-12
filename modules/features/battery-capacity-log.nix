_:
{
  flake.modules.nixos.battery-capacity-log = {
    config = {
      systemd.services.battery-capacity-log = {
        description = "Log battery capacity (charge_full) for historical tracking";
        wantedBy = [ "multi-user.target" ];
        after = [ "upower.service" ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "battery-capacity";
          StateDirectoryMode = "0755";
          User = "root";
          # Lockdown
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [ "/var/lib/battery-capacity" ];
          # Only need sysfs access for battery
          ProtectKernelTunables = false;
          RestrictAddressFamilies = [ ];
          IPAddressDeny = "any";
        };
        script = ''
          LOGFILE=/var/lib/battery-capacity/capacity.log

          # Create header if file doesn't exist
          if [ ! -f "$LOGFILE" ]; then
            echo "# timestamp_boot	epoch	charge_full_uAh	charge_full_design_uAh	capacity_pct	raw_xif1_mAh	raw_xif2_mAh	cycle_count" > "$LOGFILE"
          fi

          # Get current boot ID
          BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")

          # Read battery values
          CHARGE_FULL=$(cat /sys/class/power_supply/BAT0/charge_full 2>/dev/null || echo "N/A")
          CHARGE_FULL_DESIGN=$(cat /sys/class/power_supply/BAT0/charge_full_design 2>/dev/null || echo "N/A")
          RAW_XIF1=$(cat /sys/class/power_supply/BAT0/raw_xif1 2>/dev/null || echo "N/A")
          RAW_XIF2=$(cat /sys/class/power_supply/BAT0/raw_xif2 2>/dev/null || echo "N/A")
          CYCLE_COUNT=$(cat /sys/class/power_supply/BAT0/raw_cycle_count 2>/dev/null || echo "N/A")

          # Calculate capacity percentage
          CAPACITY_PCT="N/A"
          if [ "$CHARGE_FULL" != "N/A" ] && [ "$CHARGE_FULL_DESIGN" != "N/A" ] && [ "$CHARGE_FULL_DESIGN" -gt 0 ] 2>/dev/null; then
            CAPACITY_PCT=$(( CHARGE_FULL * 100 / CHARGE_FULL_DESIGN ))
          fi

          EPOCH=$(date +%s)

          echo "$BOOT_ID	$EPOCH	$CHARGE_FULL	$CHARGE_FULL_DESIGN	$CAPACITY_PCT	$RAW_XIF1	$RAW_XIF2	$CYCLE_COUNT" >> "$LOGFILE"
        '';
      };

      systemd.timers.battery-capacity-log = {
        description = "Periodic battery capacity logging";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "6h";
          RandomizedDelaySec = "10min";
        };
      };
    };
  };
}
