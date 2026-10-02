#!/bin/bash
## Title: ATT-Hotspot2-Tracker
## Description: Finds hidden AT&T iPhones in secure facilities via two paths:
##                1. connection mode - an open `attwifi` BSS + IE-221 / WISPr
##                   captive portal + DHCP so the phone fully associates and
##                   gets an IP (strong persistent RSSI, pingable).
##                2. pseudonym mode - a Passpoint / HS2.0 enterprise BSS
##                   (wlan0wpa) pointed at a local RADIUS that rejects, so the
##                   phone returns an EAP-AKA' pseudonym (IMSI-derived) we can
##                   use to correlate randomized MACs to one device.
##              Uses the shared WPAD-SWAP engine to temporarily run
##              wpad-wolfssl (Passpoint capable) and ALWAYS restores the factory
##              wpad-basic-mbedtls on exit, so stock Pager/PineAP functionality
##              is never permanently affected. A reboot is a universal undo.
## Version: 28-swap
## Author: Skinny Research & Development
##
## Usage: launch from the Pager UI (mode picker) or:
##          ATT/v28_run.py --mode {pseudonym|connection|both|hybrid}
##
## Notes:
##   - Requires the WPAD-SWAP engine + staged wolfssl assets. If missing, this
##     payload offers to stage them (offline; nothing is opkg-installed).
##   - Do NOT run over a Wi-Fi SSH session (the wpad restart drops it). Use
##     USB-C Ethernet or on-Pager tmux. The orchestrator refuses otherwise.
##   - Loot: /mmc/root/loot/att-hotspot2-tracker/run-*/

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
RUN="$SCRIPT_DIR/v28_run.sh"
[ -x "$RUN" ] || RUN="$SCRIPT_DIR/v28_run.py"

# Shared engine (installed as a sibling Skinny-Tools utility).
find_engine() {
    for c in "${WPAD_SWAP:-}" \
             /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh \
             /root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

ensure_ready() {
    local eng
    eng="$(find_engine)" || {
        ALERT "WPAD-SWAP engine missing.\nRun the Skinny-Tools installer, then retry."
        return 1
    }
    local missing=""
    for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl libwolfssl.so.5.9.1.e624513f; do
        [ -f "/mmc/root/wpad-swap/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        if [ "$(CONFIRMATION_DIALOG "Staged wpad-wolfssl assets are missing:$missing\n\nStage them now?" "Yes" "No")" = "Yes" ]; then
            "$eng" stage || { ALERT "Stage failed; see log."; return 1; }
        else
            return 1
        fi
    fi
    return 0
}

ensure_ready || exit 1

MODE="$(LIST_PICKER "ATT-Hotspot2-Tracker mode?" \
        "connection" "pseudonym" "both" "hybrid" "Status" "Exit" "connection" 2>/dev/null)"
[ -z "${MODE:-}" ] && MODE="connection"

case "$MODE" in
    "Exit") exit 0 ;;
    "Status")
        "$(find_engine)" status 2>&1 | LOG
        exit 0
        ;;
    connection) NEEDS_WOLFSSL=0; ARGS="--mode connection" ;;
    pseudonym)  NEEDS_WOLFSSL=1; ARGS="--mode pseudonym --no-rotate" ;;
    both)       NEEDS_WOLFSSL=1; ARGS="--mode both --phase1-duration 60" ;;
    hybrid)     NEEDS_WOLFSSL=1; ARGS="--mode hybrid" ;;
    *)
        # No UI / picker unavailable: pass through CLI args if any, else default.
        NEEDS_WOLFSSL=1; ARGS="${*:---mode connection}"
        ;;
esac

# The orchestrator swaps wpad per mode and its cleanup() ALWAYS restores stock
# (guarded by signal handlers + atexit).
#   - Passpoint modes (pseudonym/both/hybrid) need wolfssl. Run them under the
#     engine's `run` wrapper so an EXIT/INT/TERM/HUP trap guarantees stock is
#     restored even if the orchestrator is SIGKILLed mid-run.
#   - connection mode does not need wolfssl; run it directly so we don't fight
#     the orchestrator's own stock swap (avoids a needless wpad restart).
ENG="$(find_engine)"
LOG green "ATT-Hotspot2-Tracker: $MODE"

if [ "$NEEDS_WOLFSSL" = "1" ]; then
    "$ENG" run -- "$RUN" $ARGS 2>&1 | LOG
    RC=${PIPESTATUS[0]}
else
    "$RUN" $ARGS 2>&1 | LOG
    RC=${PIPESTATUS[0]}
fi

# Final safety: make sure we are on stock no matter what happened above.
"$ENG" stock >/dev/null 2>&1 || true

ALERT "ATT run finished (rc=$RC).\nLoot: /mmc/root/loot/att-hotspot2-tracker/"
exit "$RC"
