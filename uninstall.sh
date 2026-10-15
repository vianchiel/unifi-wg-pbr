#!/bin/sh
# Uninstall script for UniFi WireGuard PBR

WG_DIR="/data/unifi-wg-pbr"
SERVICE_NAME="unifi-wg-pbr.service"
TIMER_NAME="unifi-wg-pbr.timer"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
TIMER_PATH="/etc/systemd/system/$TIMER_NAME"

echo "Stopping and disabling systemd timer and service..."
systemctl stop "$TIMER_NAME" 2>/dev/null
systemctl disable "$TIMER_NAME" 2>/dev/null
systemctl stop "$SERVICE_NAME" 2>/dev/null
systemctl disable "$SERVICE_NAME" 2>/dev/null

echo "Removing systemd symlinks..."
rm -f "$SERVICE_PATH"
rm -f "$TIMER_PATH"

systemctl daemon-reload
systemctl daemon-reexec

echo "Cleaning up iptables rules..."
# We remove any MARK or RETURN rule added for wgsrv* or tlprt* interfaces in mangle PREROUTING matching a UBIOS set.
wg_ifaces=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -E '^(wgsrv|tlprt)') || true

for iface in $wg_ifaces; do
    # 1. Clean up MARK rules
    while iptables -w -t mangle -S PREROUTING | grep "\-i $iface " | grep "UBIOS_trafficroute_dn" | grep -- "-j MARK" > /dev/null 2>&1; do
        rule=$(iptables -w -t mangle -S PREROUTING | grep "\-i $iface " | grep "UBIOS_trafficroute_dn" | grep -- "-j MARK" | head -n 1 | sed 's/^-A/iptables -w -t mangle -D/')
        if [ -n "$rule" ]; then
            eval $rule
        fi
    done

    # 2. Clean up RETURN rules
    while iptables -w -t mangle -S PREROUTING | grep "\-i $iface " | grep "UBIOS_trafficroute_dn" | grep -- "-j RETURN" > /dev/null 2>&1; do
        rule=$(iptables -w -t mangle -S PREROUTING | grep "\-i $iface " | grep "UBIOS_trafficroute_dn" | grep -- "-j RETURN" | head -n 1 | sed 's/^-A/iptables -w -t mangle -D/')
        if [ -n "$rule" ]; then
            eval $rule
        fi
    done
done

echo "Deleting directory $WG_DIR..."
rm -rf "$WG_DIR"

echo "Uninstallation complete."
