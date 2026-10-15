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

# Find all WireGuard server interfaces (wgsrv*) and Teleport interfaces (tlprt*)
wg_ifaces=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -E '^(wgsrv|tlprt)') || true

# Extract all domain match-sets and their corresponding fwmarks
# Parse lines e.g. -A UBIOS_PREROUTING_PBR ... -m set --match-set UBIOS_trafficroute_dn_1 dst ... -j MARK --set-xmark 0x6b0000/0x7f0000
# Output format: UBIOS_trafficroute_dn_1|0x6b0000/0x7f0000
rules=\$(iptables-save -t mangle | grep 'UBIOS_trafficroute_dn_' | grep 'MARK --set-xmark' | sed -n 's/.*--match-set \([^ ]*\) dst.*--set-xmark \([^ ]*\).*/\1|\2/p' | sort -u)

# Create a space-separated list of just the active match-set names for easy checking
active_sets=\$(echo "\$rules" | cut -d'|' -f1 | tr '\n' ' ')

for iface in \$wg_ifaces; do
    # 0. Clean up orphaned rules
    # Find all currently injected match-sets for this interface
    injected_sets=\$(iptables-save -t mangle | grep "\-A PREROUTING -i \$iface " | grep 'UBIOS_trafficroute_dn_' | sed -n 's/.*--match-set \([^ ]*\) dst.*/\1/p' | sort -u)
    
    for injected_set in \$injected_sets; do
        # If the injected set is not in the active_sets list, it was deleted from the GUI
        if ! echo "\$active_sets" | grep -qw "\$injected_set"; then
            # Delete MARK rules
            while iptables -w -t mangle -S PREROUTING | grep "\-i \$iface " | grep "\$injected_set" | grep -- "-j MARK" > /dev/null 2>&1; do
                rule=\$(iptables -w -t mangle -S PREROUTING | grep "\-i \$iface " | grep "\$injected_set" | grep -- "-j MARK" | head -n 1 | sed 's/^-A/iptables -w -t mangle -D/')
                [ -n "\$rule" ] && eval \$rule
            done
            # Delete RETURN rules
            while iptables -w -t mangle -S PREROUTING | grep "\-i \$iface " | grep "\$injected_set" | grep -- "-j RETURN" > /dev/null 2>&1; do
                rule=\$(iptables -w -t mangle -S PREROUTING | grep "\-i \$iface " | grep "\$injected_set" | grep -- "-j RETURN" | head -n 1 | sed 's/^-A/iptables -w -t mangle -D/')
                [ -n "\$rule" ] && eval \$rule
            done
        fi
    done

    # 1. Apply active rules
    for rule in \$rules; do
        match_set="\${rule%%|*}"
        mark="\${rule##*|}"
        
        # 1. Check and add the MARK rule
        iptables -w -t mangle -C PREROUTING -i "\$iface" -m set --match-set "\$match_set" dst -j MARK --set-xmark "\$mark" 2>/dev/null
        if [ \$? -ne 0 ]; then
            iptables -w -t mangle -A PREROUTING -i "\$iface" -m set --match-set "\$match_set" dst -j MARK --set-xmark "\$mark"
        fi

        # 2. Check and add the RETURN rule to prevent fallthrough overwrites
        iptables -w -t mangle -C PREROUTING -i "\$iface" -m set --match-set "\$match_set" dst -j RETURN 2>/dev/null
        if [ \$? -ne 0 ]; then
            iptables -w -t mangle -A PREROUTING -i "\$iface" -m set --match-set "\$match_set" dst -j RETURN
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
iptables -t mangle -S PREROUTING | grep -E "wgsrv|tlprt" | grep MARK || echo "!!! No PBR rules found for wgsrv or tlprt interfaces."
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
