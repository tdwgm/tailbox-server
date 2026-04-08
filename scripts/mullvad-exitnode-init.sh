#!/bin/bash
# mullvad-exitnode-init.sh
# Applies network routing rules for Tailscale socat-forwarding in the gluetun network namespace.
# Idempotent — safe to run multiple times.
# Called automatically by gluetun-watcher.sh on container restart.
#
# WHY THIS FIX IS NEEDED
# ----------------------
# Gluetun adds a policy routing rule with priority 101:
#   "not from all fwmark 0xca6c lookup 51820"
# This rule captures return traffic for Tailscale's CGNAT range (100.64.0.0/10)
# before it can reach the tailscale0 interface, causing Tailscale exit node
# traffic to fail or loop. This script injects two corrections inside gluetun's
# network namespace:
#
#   1. ip rule (priority 100): route packets destined for 100.64.0.0/10 via
#      table 52 — evaluated *before* gluetun's rule 101, so Tailscale CGNAT
#      return traffic is handled correctly.
#
#   2. ip route in table 51820 (WireGuard table): adds 100.64.0.0/10 via
#      tailscale0 so that the WireGuard routing table also forwards this
#      traffic to the Tailscale interface rather than dropping it.
#
# Together these two rules allow the Tailscale exit node inside gluetun's
# namespace to pass traffic correctly without conflicting with the VPN routes.

set -euo pipefail

VPN_CONTAINER="mullvad-gateway"
TS_CONTAINER="tailscale-endpoint"

for c in "$VPN_CONTAINER" "$TS_CONTAINER"; do
    if ! docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
        echo "SKIP: $c is not running"
        exit 0
    fi
done

PID=$(docker inspect -f '{{.State.Pid}}' "$VPN_CONTAINER")

echo "Waiting for tailscale0..."
for i in $(seq 1 30); do
    if nsenter -t "$PID" -n -- ip link show tailscale0 &>/dev/null; then
        break
    fi
    sleep 2
done

if ! nsenter -t "$PID" -n -- ip link show tailscale0 &>/dev/null; then
    echo "FAIL: tailscale0 not found after 60s"
    exit 1
fi

echo "tailscale0 found"

if ! nsenter -t "$PID" -n -- ip rule show | grep -q "to 100.64.0.0/10 lookup 52"; then
    nsenter -t "$PID" -n -- ip rule add to 100.64.0.0/10 lookup 52 priority 100
    echo "Added ip rule: to 100.64.0.0/10 lookup 52 prio 100"
else
    echo "ip rule 100.64.0.0/10 -> table 52 already exists"
fi

if ! nsenter -t "$PID" -n -- ip route show table 51820 | grep -q "100.64.0.0/10"; then
    nsenter -t "$PID" -n -- ip route add 100.64.0.0/10 dev tailscale0 table 51820
    echo "Added route 100.64.0.0/10 -> tailscale0 in table 51820"
else
    echo "Route 100.64.0.0/10 in table 51820 already exists"
fi

# --- DNS DNAT bypass ---
# Gluetun's built-in DNS proxy has hardcoded rebinding protection that blocks
# DNS responses containing private/RFC1918 IPs. This breaks split DNS for local
# domains (e.g. *.lan.example.com -> 192.168.x.x). The exempt-hostnames setting
# only supports exact hostnames, not wildcards or suffixes.
#
# Workaround: redirect all DNS queries in the namespace from :53 to :5353,
# bypassing gluetun's DNS proxy entirely. dnsmasq on :5353 handles the split
# routing (local domains -> LAN DNS, everything else -> Mullvad DNS).
if ! nsenter -t "$PID" -n -- iptables -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5353 2>/dev/null; then
    nsenter -t "$PID" -n -- iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:5353
    echo "Added DNS DNAT: udp :53 -> :5353"
else
    echo "DNS DNAT udp already exists"
fi
if ! nsenter -t "$PID" -n -- iptables -t nat -C OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5353 2>/dev/null; then
    nsenter -t "$PID" -n -- iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:5353
    echo "Added DNS DNAT: tcp :53 -> :5353"
else
    echo "DNS DNAT tcp already exists"
fi

echo "DONE: Tailscale routing and DNS rules applied"
