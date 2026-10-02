#!/bin/sh
# v27_nat.sh — Firewall / NAT setup for v27 connection mode.
#
# The Pager runs OpenWrt firewall4 (nftables), not iptables. This script
# uses the UCI firewall abstraction so firewall4 generates the right
# nftables rules for us. We declare a new zone "att" for our br-att
# (or "lan" reuse for --no-isolate) and a forwarding att -> wan so
# phones can reach the internet via wlan0cli (SkinnyRD / IceCreamBase).
#
# Usage:
#   v27_nat.sh up    # install the firewall config for our zones
#   v27_nat.sh down  # remove the firewall config we added
#
# Idempotent: zone/forwarding presence is checked before insertion.

set -eu

ACTION="${1:-}"
UPLINK_ZONE="${UPLINK_ZONE:-wan}"

case "$ACTION" in
    up)
        # check if "att" zone already exists
        if ! uci -q get firewall.att_zone >/dev/null 2>&1; then
            # create the zone
            uci -q add firewall zone >/dev/null
            uci -q rename firewall.@zone[-1]=att_zone >/dev/null
            uci -q set firewall.att_zone.name='att'
            uci -q set firewall.att_zone.input='ACCEPT'
            uci -q set firewall.att_zone.output='ACCEPT'
            uci -q set firewall.att_zone.forward='ACCEPT'
            uci -q set firewall.att_zone.masq='1'
            uci -q set firewall.att_zone.masq6='0'
            uci -q set firewall.att_zone.device='br-att'
            uci -q set firewall.att_zone.family='ipv4'
            echo "[v27_nat] created firewall.att_zone"
        fi

        # create forwarding att -> wan if not present
        if ! uci -q get firewall.att_forwarding >/dev/null 2>&1; then
            uci -q add firewall forwarding >/dev/null
            uci -q rename firewall.@forwarding[-1]=att_forwarding >/dev/null
            uci -q set firewall.att_forwarding.src='att'
            uci -q set firewall.att_forwarding.dest="$UPLINK_ZONE"
            echo "[v27_nat] created forwarding att -> $UPLINK_ZONE"
        fi

        uci -q commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo "[v27_nat] firewall reloaded"
        ;;

    down)
        if uci -q get firewall.att_forwarding >/dev/null 2>&1; then
            uci -q delete firewall.att_forwarding
            echo "[v27_nat] removed att_forwarding"
        fi
        if uci -q get firewall.att_zone >/dev/null 2>&1; then
            uci -q delete firewall.att_zone
            echo "[v27_nat] removed att_zone"
        fi
        uci -q commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
        echo "[v27_nat] firewall reloaded (att zone removed)"
        ;;

    status)
        echo "--- UCI firewall zones ---"
        uci -q show firewall | grep -E "^firewall\.(att|@zone)" | head -10
        echo "--- UCI firewall forwarding ---"
        uci -q show firewall | grep -E "^firewall\.(att_forwarding|@forwarding)" | head -10
        echo "--- nftables ip nat ---"
        nft list table ip nat 2>/dev/null || echo "(no ip nat table)"
        ;;

    *)
        echo "usage: $0 {up|down|status}" >&2
        exit 2
        ;;
esac