#!/bin/sh
# v27_isolate.sh — Bridge create/destroy helpers for v27 connection mode.
#
# Usage:
#   v27_isolate.sh up    # bring up br-att with 192.168.99.1/24
#   v27_isolate.sh down  # tear down br-att, return wlan0open to br-lan
#
# Idempotent: `up` succeeds if br-att already exists; `down` succeeds
# if br-att doesn't exist.

set -eu

ACTION="${1:-}"
IFACE="${WLAN_OPEN:-wlan0open}"
BR="${BR_ATT:-br-att}"
BR_IP="${BR_IP:-192.168.99.1/24}"

case "$ACTION" in
    up)
        # create bridge if missing
        if ! ip link show "$BR" >/dev/null 2>&1; then
            ip link add name "$BR" type bridge
            echo "[v27_isolate] created $BR"
        fi
        # remove wlan0open from br-lan, add to br-att (only if not already)
        if ip link show "$IFACE" 2>/dev/null | grep -q "master $BR"; then
            echo "[v27_isolate] $IFACE already on $BR"
        else
            if ip link show "$IFACE" 2>/dev/null | grep -q "master br-lan"; then
                ip link set "$IFACE" nomaster
            fi
            ip link set "$IFACE" master "$BR"
            echo "[v27_isolate] $IFACE now on $BR"
        fi
        # assign IP
        if ! ip addr show "$BR" 2>/dev/null | grep -q "inet $BR_IP"; then
            ip addr add "$BR_IP" dev "$BR"
        fi
        ip link set "$BR" up
        ip link set "$IFACE" up 2>/dev/null || true
        echo "[v27_isolate] $BR up with $BR_IP"
        ;;

    down)
        # move wlan0open back to br-lan
        if ip link show "$IFACE" 2>/dev/null | grep -q "master $BR"; then
            ip link set "$IFACE" nomaster
            echo "[v27_isolate] $IFACE removed from $BR"
        fi
        if ip link show "$IFACE" 2>/dev/null | grep -q "master br-lan"; then
            echo "[v27_isolate] $IFACE already on br-lan"
        else
            ip link set "$IFACE" master br-lan
            echo "[v27_isolate] $IFACE returned to br-lan"
        fi
        # remove bridge
        if ip link show "$BR" >/dev/null 2>&1; then
            ip link set "$BR" down 2>/dev/null || true
            ip addr flush dev "$BR" 2>/dev/null || true
            ip link delete "$BR" type bridge 2>/dev/null || true
            echo "[v27_isolate] $BR deleted"
        fi
        ip link set "$IFACE" up 2>/dev/null || true
        ;;

    status)
        echo "--- $BR ---"
        ip addr show "$BR" 2>/dev/null || echo "no $BR"
        echo "--- $IFACE ---"
        ip link show "$IFACE" 2>/dev/null | grep -E "master|state" || echo "no $IFACE"
        ;;

    *)
        echo "usage: $0 {up|down|status}" >&2
        exit 2
        ;;
esac