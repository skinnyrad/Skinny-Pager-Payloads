#!/bin/bash
#
# Title: Skinny-Skim-Scanner
# Description: BLE lescan + signature grep, batched to LOG every 5s.
#              GREEN from broad scan opens a menu of detected skimmers
#              (LRU 10, most recent first). Selecting one enters isolation
#              tracking with live per-advertisement RSSI from btmon.
#              RED exits isolation back to broad scan.
#              Any other button from broad scan quits the payload.
# Version: 18.4
# Author: Jeff Benson (erg0Pr0xy)
#

if [ "$EUID" -ne 0 ]; then
  echo "[-] Run as root."
  exit 1
fi

WORK_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SIGNATURES="$WORK_DIR/skimmer_signatures.txt"
SCAN_PID=""
DRAIN_PID=""
ISOLATION_PID=""
ISOLATION_LESCAN_PID=""
BLOCKING_PID=""
BTN_FILE="/tmp/.skim_btn"
PICKED_FILE="/tmp/.skim_picked"
SEEN_FILE="/tmp/.skim_seen"
BUFFER_FILE="/tmp/.skim_buffer"
MAX_SEEN=10

# --- Helper: run a framework blocking call in a way that signals can interrupt.
# Backgrounds the command, writes its stdout to $2, then `wait`s for it.
# `wait` is signal-interruptible; `$(...)` is not (bash defers traps while
# a command substitution is in flight, so TERM/INT sent during $() never
# reaches cleanup). Uses `setsid` so the call (and any children it forks)
# live in their own process group; cleanup kills the whole group, so a
# framework binary that internally spawns a helper can't be left orphaned.
blocking_run() {
    local outfile="$1"
    shift
    : > "$outfile"
    setsid "$@" > "$outfile" 2>/dev/null &
    BLOCKING_PID=$!
    BLOCKING_PGID=$(ps -o pgid= -p "$BLOCKING_PID" 2>/dev/null | tr -d ' ')
    wait $BLOCKING_PID
    local rc=$?
    BLOCKING_PID=""
    BLOCKING_PGID=""
    return $rc
}

# --- 1. HCI health check + reset ---
killall -9 hcitool btmon 2>/dev/null
hciconfig hci0 down 2>/dev/null; sleep 0.5
hciconfig hci0 up 2>/dev/null; sleep 0.5
hciconfig hci0 reset 2>/dev/null; sleep 0.5
hciconfig hci0 piscan 2>/dev/null

# --- 2. Build grep pattern from signatures ---
PATTERN=""
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    PATTERN="${PATTERN:+$PATTERN|}$line"
done < "$SIGNATURES"
[ -z "$PATTERN" ] && PATTERN="HC-05|HC-06|linvor|JDY-|BT0[0-9]|HC-[0-9]"

# --- 3. Cleanup ---
cleanup() {
    [ -n "$BLOCKING_PGID" ] && kill -9 -$BLOCKING_PGID 2>/dev/null
    [ -n "$BLOCKING_PID" ] && kill -9 "$BLOCKING_PID" 2>/dev/null
    [ -n "$SCAN_PID" ] && kill -9 "$SCAN_PID" 2>/dev/null
    [ -n "$DRAIN_PID" ] && kill -9 "$DRAIN_PID" 2>/dev/null
    [ -n "$ISOLATION_PID" ] && kill -9 "$ISOLATION_PID" 2>/dev/null
    [ -n "$ISOLATION_LESCAN_PID" ] && kill -9 "$ISOLATION_LESCAN_PID" 2>/dev/null
    killall -9 hcitool btmon 2>/dev/null
    pkill -9 -f "/tmp/.skim" 2>/dev/null
    LED OFF 2>/dev/null
    rm -f "$BUFFER_FILE" "$SEEN_FILE" "$BTN_FILE" "$PICKED_FILE"
    exit 0
}
trap cleanup EXIT INT TERM HUP

# --- 4. Startup prompt ---
PROMPT "SKIMMER SCANNER v18.4

BLE broad scan every 5s.
GREEN = menu of detected skimmers.
Pick one to isolate with live RSSI.
RED exits isolation.
Any other button = quit."

LOG "[+] Pattern: $PATTERN"
LOG "[+] Scanning..."

# One-time init
rm -f "$BUFFER_FILE" "$SEEN_FILE"

# --- 5. Seen-list helper (LRU by recency, max $MAX_SEEN entries) ---
add_seen() {
    local mac="$1" name="$2" tmp
    [ -z "$mac" ] && return
    tmp=$(mktemp 2>/dev/null) || return
    {
        printf '%s %s\n' "$mac" "$name"
        awk -v m="$mac" '{ split($0, p, " "); if (p[1] != m) print }' "$SEEN_FILE" 2>/dev/null
    } | head -n "$MAX_SEEN" > "$tmp"
    mv "$tmp" "$SEEN_FILE"
}

# --- 6. Broad scan pipeline ---
start_broad() {
    stop_broad
    stop_isolation
    rm -f "$BUFFER_FILE"
    killall -9 hcitool 2>/dev/null
    sleep 0.3
    hciconfig hci0 up 2>/dev/null
    hciconfig hci0 piscan 2>/dev/null

    (
        hcitool lescan --duplicates 2>/dev/null \
            | grep -i -E "$PATTERN" \
            | grep -v "(unknown)" \
            > "$BUFFER_FILE"
    ) &
    SCAN_PID=$!

    (
        LAST=""
        while true; do
            sleep 5
            NEW=$(sort -u "$BUFFER_FILE" 2>/dev/null)

            if [ -n "$NEW" ]; then
                if [ -n "$LAST" ]; then
                    NEW_LINES=$(comm -23 <(printf '%s\n' "$NEW") <(printf '%s\n' "$LAST"))
                    STILL_LINES=$(comm -12 <(printf '%s\n' "$NEW") <(printf '%s\n' "$LAST"))
                else
                    NEW_LINES="$NEW"
                    STILL_LINES=""
                fi

                if [ -n "$NEW_LINES" ]; then
                    printf '%s\n' "$NEW_LINES" | while IFS= read -r line; do
                        [ -n "$line" ] && {
                            LOG "⚠ $line"
                            MAC=$(echo "$line" | awk '{print $1}')
                            NAME=$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}')
                            [ -n "$MAC" ] && add_seen "$MAC" "$NAME"
                        }
                    done
                    LED R 255 G 0 B 0 2>/dev/null
                    sleep 0.6
                    LED OFF 2>/dev/null
                fi

                if [ -n "$STILL_LINES" ]; then
                    COUNT=$(printf '%s\n' "$STILL_LINES" | grep -c .)
                    LOG "[~] Still detecting $COUNT skimmer(s)."
                fi
            fi

            LAST="$NEW"
            : > "$BUFFER_FILE"
        done
    ) &
    DRAIN_PID=$!
}

stop_broad() {
    [ -n "$SCAN_PID" ] && kill -9 "$SCAN_PID" 2>/dev/null
    [ -n "$DRAIN_PID" ] && kill -9 "$DRAIN_PID" 2>/dev/null
    killall -9 hcitool 2>/dev/null
    SCAN_PID=""
    DRAIN_PID=""
    sleep 0.3
}

# --- 7. Skimmer menu ---
show_menu() {
    if [ ! -s "$SEEN_FILE" ]; then
        LOG yellow "[-] No skimmers detected yet."
        sleep 2
        return 1
    fi

    local opts=()
    local macs=()
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        opts+=("$line")
        macs+=("${line%% *}")
    done < "$SEEN_FILE"

    opts+=("<< Back to scan")
    opts+=("X  Quit")

    blocking_run "$PICKED_FILE" LIST_PICKER "Skimmers (most recent first)" "${opts[@]}" "${opts[0]}"
    local rc=$?
    PICKED=$(cat "$PICKED_FILE" 2>/dev/null)
    case "$rc" in
        "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED")
            return 1
            ;;
        "$DUCKYSCRIPT_ERROR")
            LOG red "[-] Picker error."
            return 1
            ;;
    esac

    case "$PICKED" in
        "<< Back to scan")
            return 1
            ;;
        "X  Quit")
            cleanup
            ;;
    esac

    # PICKED may be the option text or a 1-based index
    local picked_idx=-1
    if [[ "$PICKED" =~ ^[0-9]+$ ]] && [ "$PICKED" -ge 1 ] && [ "$PICKED" -le "${#opts[@]}" ]; then
        picked_idx=$((PICKED - 1))
    else
        local i
        for i in "${!opts[@]}"; do
            if [ "${opts[$i]}" = "$PICKED" ]; then
                picked_idx=$i
                break
            fi
        done
    fi

    local n_skimmers=${#macs[@]}
    if [ "$picked_idx" -ge 0 ] && [ "$picked_idx" -lt "$n_skimmers" ]; then
        start_isolation "${macs[$picked_idx]}"
    fi
}

# --- 8. Isolation mode ---
start_isolation() {
    local target_mac="$1"
    local target_name
    target_name=$(awk -v m="$target_mac" '$1==m { $1=""; sub(/^ /,""); print; exit }' "$SEEN_FILE" 2>/dev/null)
    [ -z "$target_name" ] && target_name="(unknown)"

    stop_broad
    killall -9 btmon 2>/dev/null
    sleep 0.3
    hciconfig hci0 reset 2>/dev/null
    sleep 0.3
    hciconfig hci0 up 2>/dev/null
    sleep 0.3
    hciconfig hci0 piscan 2>/dev/null

    LED R 255 G 0 B 0 2>/dev/null
    LOG green "[+] ISOLATION: $target_mac  ($target_name)"
    LOG "[+] Live RSSI per advertisement. RED = back to broad scan."

    # btmon is passive - it only logs HCI traffic. Drive the HCI into
    # active LE scanning with a parallel lescan so btmon actually
    # receives advertisements to filter.
    (
        hcitool lescan --duplicates 2>/dev/null > /dev/null
    ) &
    ISOLATION_LESCAN_PID=$!

    (
        btmon -i hci0 2>/dev/null | awk -v target="$target_mac" '
            /Address:/ { gsub(/[()]/,""); split($0, a, " "); addr = a[2] }
            /RSSI:/ && addr == target { print "RSSI: " $2 " dBm" }
        ' | while IFS= read -r rline; do
            [ -n "$rline" ] && {
                LOG "$rline"
            }
        done
    ) &
    ISOLATION_PID=$!

    local btn
    while true; do
        blocking_run "$BTN_FILE" WAIT_FOR_INPUT
        btn=$(cat "$BTN_FILE" 2>/dev/null)
        case "$btn" in
            "RED"|"B")
                LOG yellow "[-] Exiting isolation."
                stop_isolation
                return 0
                ;;
        esac
    done
}

stop_isolation() {
    [ -n "$ISOLATION_PID" ] && kill -9 "$ISOLATION_PID" 2>/dev/null
    [ -n "$ISOLATION_LESCAN_PID" ] && kill -9 "$ISOLATION_LESCAN_PID" 2>/dev/null
    killall -9 btmon hcitool 2>/dev/null
    ISOLATION_PID=""
    ISOLATION_LESCAN_PID=""
    LED OFF 2>/dev/null
}

# --- 9. Main loop ---
start_broad

while true; do
    blocking_run "$BTN_FILE" WAIT_FOR_INPUT
    BTN=$(cat "$BTN_FILE" 2>/dev/null)
    case "$BTN" in
        "GREEN"|"A")
            stop_broad
            show_menu
            start_broad
            ;;
        "RED"|"B")
            cleanup
            ;;
        *)
            # Ignore UP/DOWN/LEFT/RIGHT/CENTER/POWER - keep broad scan running
            LOG "[-] (ignored button: $BTN)"
            ;;
    esac
done
