# UniFi WireGuard Policy-Based Routing (PBR) Fix

Automatically applies `iptables` rules to all `wgsrv*` (WireGuard Server) and `tlprt*` (Teleport) interfaces on UniFi OS to ensure Policy-Based Routing (Traffic Routes) work for VPN clients.

## Problem
UniFi's implementation of Traffic Routes (Policy-Based Routing) applies an `iptables` `fwmark` to traffic matching a PBR rule. However, their scripts only apply the `PREROUTING` mangle rules to standard local LAN bridge interfaces (like `br0`, `br1`) and ignore `wgsrv*` (WireGuard Server) and `tlprt*` (Teleport) interfaces. This results in VPN client traffic bypassing Traffic Routes and routing via the default WAN.

## Solution
This script creates a persistent `systemd` service and timer that dynamically applies the missing `PREROUTING` `fwmark` rule to all `wgsrv*` and `tlprt*` interfaces every 5 minutes (to ensure persistence after reprovisioning). It dynamically scrapes the existing active PBR fwmarks (like `0x6b0000/0x7f0000`) injected by UniFi OS and sequentially applies them to your VPN server interfaces.

## Installation

```bash
chmod +x install.sh
./install.sh
```

This will create a `/data/unifi-wg-pbr/` directory (which survives UniFi OS updates) and set up the `systemd` timer.

## Verification

You can verify the service status and current iptables rules by running the included status check:

```bash
/data/unifi-wg-pbr/status.sh
```

## Uninstallation

```bash
chmod +x uninstall.sh
./uninstall.sh
```
