#!/bin/sh
# WPAD-SWAP -- Pager-UI front-end for the non-destructive wpad hot-swap engine.
#
# Lets you manually flip the Pager between the factory wpad-basic-mbedtls and
# wpad-wolfssl (Passpoint / Hotspot2.0 capable) without touching the stock
# package. Use this to enable wolfssl before running an ATT/Passpoint payload,
# and Restore Stock afterwards (or just reboot).
#
# The real logic lives in wpad-swap.sh next to this file.

set -u
PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$PAYLOAD_DIR/wpad-swap.sh"
LOOT_DIR=/mmc/root/loot/wpad-swap

[ -x "$ENGINE" ] || { ALERT "wpad-swap engine missing at $ENGINE"; exit 1; }

mode() {
    if mount 2>/dev/null | awk '{print $3}' | grep -qx /usr/sbin/wpad; then
        printf 'wolfssl'
    else
        printf 'stock'
    fi
}

show_status() {
    local a pid
    if [ "$(mode)" = "wolfssl" ]; then
        a="wolfssl (Passpoint capable)"
    else
        a="stock (factory mbedtls)"
    fi
    pid=$(pidof hostapd 2>/dev/null | awk '{print $1}')
    local rsha="(not running)"
    [ -n "$pid" ] && rsha=$(sha256sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}' | cut -c1-16)
    ALERT "wpad mode: $a\nhostapd: ${rsha}..."
    sleep 1
}

while true; do
    CHOICE=$(CONFIRMATION_DIALOG "[WPAD-SWAP]\nCurrent mode: $(mode)\n\nChoose an action:" \
             "Status" "Enable wolfssl" "Restore stock" "Recover" "Exit")
    case "$CHOICE" in
        "Status")
            show_status
            ;;
        "Enable wolfssl")
            LOG green "Enabling wpad-wolfssl..."
            "$ENGINE" wolfssl 2>&1 | LOG
            ALERT "Enabled: $?"
            ;;
        "Restore stock")
            LOG green "Restoring factory wpad..."
            "$ENGINE" stock 2>&1 | LOG
            ALERT "Restored: $?"
            ;;
        "Recover")
            LOG green "Forcing factory state..."
            "$ENGINE" recover 2>&1 | LOG
            ALERT "Recovered."
            ;;
        "Exit"|*)
            exit 0
            ;;
    esac
done
