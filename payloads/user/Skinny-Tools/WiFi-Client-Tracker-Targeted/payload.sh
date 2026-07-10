#!/bin/bash

## Title: WiFi-Client-Tracker-Targeted
## Description: Real-time targeted WiFi client proximity tracker for the Evil WPA AP (wlan0wpa)
##              Meant for tracking clients that are not currently connected to an SSID they are out of range for
##              but are still probing for.
##
## Version: 16.0
## Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
##
## Usage:
##   payload.sh [TARGET_MAC] [SCAN_SECONDS]
##     TARGET_MAC:    optional MAC to track directly. If omitted, the script
##                    scans for SCAN_SECONDS, builds a list of clients, and
##                    asks the user to pick one (via Pager LIST_PICKER when
##                    launched as a payload, or via terminal 'select' when
##                    run from an interactive SSH session).
##     SCAN_SECONDS:  how long to scan for clients when no TARGET_MAC is
##                    given. Default 20.
##
## Notes:
##   - Does NOT bring up or tear down the WPA AP. Manage that with:
##       WIFI_WPA_AP wlan0wpa SSID psk2 22222222
##       WIFI_WPA_AP_DISABLE wlan0wpa
##   - Output is mirrored to BOTH the Pager payload log (LOG hak5cmd) and
##     stdout, so it shows on the Pager screen AND in any SSH terminal.
##   - When no payload is running, the LOG call is a silent no-op (safe
##     to call from a raw SSH session).

IFACE="wlan0wpa"
TARGET="${1:-}"
SCAN_SECONDS="${2:-20}"
export LD_LIBRARY_PATH="/usr/lib:/lib:$LD_LIBRARY_PATH"

# ---- helpers ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Send a line to the Pager payload log AND stdout.
# Usage:
#   emit "message"                  -> LOG "message" + printf
#   emit red "message"              -> LOG red "message" + printf
emit() {
    local first="$1"
    case "$first" in
        red|green|yellow|blue|magenta|cyan|white)
            shift
            LOG "$first" "$*"
            printf '%s\n' "$*"
            ;;
        *)
            LOG "$*"
            printf '%s\n' "$*"
            ;;
    esac
}

# ---- signal handling ----
shutdown() {
    emit yellow ""
    emit yellow "[$(ts)] Tracking stopped. AP left running on $IFACE."
    emit yellow "       Run: WIFI_WPA_AP_DISABLE $IFACE"
    exit 0
}
trap shutdown SIGINT SIGTERM

# ---- header ----
emit yellow "================================================="
emit yellow "  TARGET PROXIMITY TRACKER  (wlan0wpa)"
emit        "  Started: $(ts)"
emit yellow "================================================="
emit        "Interface:    $IFACE"
if [ -n "$TARGET" ]; then
    emit    "Target:       $TARGET (passed as arg)"
    emit    "Scan window:  skipped (target given)"
else
    emit    "Target:       none (will scan + prompt)"
    emit    "Scan window:  ${SCAN_SECONDS}s"
fi
emit yellow "-------------------------------------------------"

# Sanity: AP up?
if ! iw dev "$IFACE" info >/dev/null 2>&1; then
    emit red "[$(ts)] ERROR: $IFACE is DOWN. Start it with:"
    emit red "         WIFI_WPA_AP $IFACE SSID psk2 22222222"
    exit 1
fi
emit green "[$(ts)] AP is up."
emit yellow "-------------------------------------------------"

# ---- discovery + selection (only when no TARGET) ----
if [ -z "$TARGET" ]; then
    emit yellow "Scanning for clients on $IFACE..."

    FOUND=()
    SCAN_START=$SECONDS
    LAST_COUNT=-1

    while true; do
        ELAPSED=$((SECONDS - SCAN_START))

        # Collect MACs currently associated
        DUMP="$(iw dev "$IFACE" station dump 2>/dev/null)"
        while read -r mac; do
            [ -z "$mac" ] && continue
            # add to FOUND if new
            already=0
            for m in "${FOUND[@]}"; do
                if [ "$m" = "$mac" ]; then already=1; break; fi
            done
            if [ $already -eq 0 ]; then
                FOUND+=("$mac")
                SIG="$(echo "$DUMP" | awk -v t="$mac" '
                    $0 ~ "Station "t { found=1; next }
                    found && /signal:[ \t]+-/ { gsub(/[^0-9-]/, "", $2); print $2; exit }
                ')"
                [ -z "$SIG" ] && SIG="?"
                emit green "[$(ts)] NEW CLIENT  MAC: $mac  Signal: $SIG dBm"
            fi
        done < <(echo "$DUMP" | awk '/^Station/{print $2}')

        # Update countdown
        if [ ${#FOUND[@]} -ne $LAST_COUNT ]; then
            LAST_COUNT=${#FOUND[@]}
        fi
        if [ $ELAPSED -lt $SCAN_SECONDS ]; then
            REMAINING=$((SCAN_SECONDS - ELAPSED))
            emit "  Scanning... (${REMAINING}s remaining, ${#FOUND[@]} client(s) found)"
        fi

        # Exit conditions
        if [ $ELAPSED -ge $SCAN_SECONDS ]; then
            if [ ${#FOUND[@]} -eq 0 ]; then
                emit red "[$(ts)] No clients found in ${SCAN_SECONDS}s. Exiting."
                exit 0
            fi
            break
        fi

        sleep 1
    done

    emit yellow "-------------------------------------------------"
    emit yellow "Found ${#FOUND[@]} client(s). Select a target to track:"

    # Try Pager LIST_PICKER first (works on Pager screen as a payload).
    # Build the options list - first option is "Rescan", rest are MACs.
    PICKER_ARGS=("Rescan..." "${FOUND[@]}")
    PICKER_DEFAULT="0"
    SELECTED=$(LIST_PICKER "Track which client on $IFACE?" "${PICKER_ARGS[@]}" "$PICKER_DEFAULT" 2>/dev/null)

    if [ -z "$SELECTED" ] || [ "$SELECTED" = "Rescan..." ]; then
        # LIST_PICKER not available (running from SSH without payload) or
        # user picked "Rescan...". Try terminal fallback.
        if tty -s 2>/dev/null; then
            emit yellow "Terminal picker:"
            PS3="Enter the number of the target: "
            select CHOSEN in "${FOUND[@]}"; do
                if [ -n "$CHOSEN" ]; then
                    SELECTED="$CHOSEN"
                    break
                fi
            done
        else
            emit red "No interactive picker available."
            emit red "Re-run with a MAC as arg, e.g.:"
            emit red "  $0 ${FOUND[0]}"
            exit 1
        fi
    fi

    if [ -z "$SELECTED" ] || [ "$SELECTED" = "Rescan..." ]; then
        emit red "No target selected. Exiting."
        exit 1
    fi

    TARGET="$SELECTED"
    emit green "[$(ts)] Target selected: $TARGET"
    emit yellow "-------------------------------------------------"
fi

# ---- main tracking loop ----
LAST=""

while true; do
    DUMP="$(iw dev "$IFACE" station dump 2>/dev/null)"

    NOW="$(echo "$DUMP" | awk -v t="$TARGET" '$0 ~ t {print "present"}')"
    if [ "$NOW" != "$LAST" ]; then
        if [ "$NOW" = "present" ]; then
            SIG="$(echo "$DUMP" | awk -v t="$TARGET" '
                $0 ~ "Station "t { found=1; next }
                found && /signal:[ \t]+-/ { gsub(/[^0-9-]/, "", $2); print $2; exit }
            ')"
            if [ -z "$SIG" ]; then SIG="?"; fi
            emit green "[$(ts)] CONNECT    MAC: $TARGET  Signal: $SIG dBm"
        else
            emit red "[$(ts)] DISCONNECT MAC: $TARGET"
        fi
        LAST="$NOW"
    fi

    sleep 1
done
