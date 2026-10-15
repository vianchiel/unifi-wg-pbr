#!/bin/sh

# ==========================================

WG_DIR="/data/unifi-wg-pbr"
SERVICE_NAME="unifi-wg-pbr.service"
TIMER_NAME="unifi-wg-pbr.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

INTERVAL_MIN="5"

mkdir -p "$WG_DIR"

echo "Writing PBR apply script..."
cat << EOF > "$WG_DIR/apply-pbr.sh"
#!/bin/sh

# Find all WireGuard server interfaces (wgsrv*)
wg_ifaces=\$(ip -o link show | awk -F': ' '{print \$2}' | grep '^wgsrv') || true

# Extract all unique fwmarks used for PBR matching sets
# grep for 'match-set' and 'MARK' to extract the mask and value, e.g., 0x6b0000/0x7f0000
marks=\$(iptables-save -t mangle | grep match-set | grep 'MARK --set-xmark' | awk '{for(i=1;i<=NF;i++) if(\$i=="--set-xmark") print \$(i+1)}' | sort -u)

for iface in \$wg_ifaces; do
    for mark in \$marks; do
        # Check if rule exists
        iptables -w -t mangle -C PREROUTING -i "\$iface" -j MARK --set-xmark "\$mark" 2>/dev/null
        
        # If rule doesn't exist (exit code != 0), add it
        if [ \$? -ne 0 ]; then
            iptables -w -t mangle -A PREROUTING -i "\$iface" -j MARK --set-xmark "\$mark"
        fi
    done
done

exit 0
EOF
chmod +x "$WG_DIR/apply-pbr.sh"

echo "Creating systemd service..."
cat << EOF > "$WG_DIR/$SERVICE_NAME"
[Unit]
Description=Apply PBR fwmark for WireGuard Server Interfaces
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$WG_DIR/apply-pbr.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

echo "Creating systemd timer with $INTERVAL_MIN min interval..."
cat << EOF > "$WG_DIR/$TIMER_NAME"
[Unit]
Description=Run UniFi WG PBR every $INTERVAL_MIN minutes

[Timer]
OnBootSec=30
OnCalendar=*:0/${INTERVAL_MIN}
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

echo "Adding status.sh..."
cat << EOF > "$WG_DIR/status.sh"
#!/bin/sh

echo "UniFi WireGuard PBR Status"
echo "---------------------------------------"

echo "\nService Status:"
if systemctl is-active --quiet unifi-wg-pbr.service; then
  echo "unifi-wg-pbr.service is active"
else
  echo "unifi-wg-pbr.service is currently inactive (normal). It is triggered by the timer."
fi

echo "\nTimer Status:"
if systemctl is-active --quiet unifi-wg-pbr.timer; then
  echo "unifi-wg-pbr.timer is active"
else
  echo "unifi-wg-pbr.timer is inactive"
fi

echo "\nNext Timer Trigger:"
systemctl list-timers --all | grep unifi-wg-pbr || echo "!!! Timer not scheduled"

echo "\nLast Service Run Log:"
journalctl -u unifi-wg-pbr.service --no-pager -n 5

echo "\nCurrent PBR iptables Rules (mangle PREROUTING):"
iptables -t mangle -S PREROUTING | grep "wgsrv" | grep MARK || echo "!!! No PBR rules found for wgsrv interfaces."
EOF
chmod +x "$WG_DIR/status.sh"

ln -sf "$WG_DIR/$SERVICE_NAME" "$SERVICE_PATH"
ln -sf "$WG_DIR/$TIMER_NAME" "$TIMER_PATH"

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl enable "$TIMER_NAME"
systemctl start "$SERVICE_NAME"
systemctl start "$TIMER_NAME"

echo "Installed and scheduled every $INTERVAL_MIN min."
