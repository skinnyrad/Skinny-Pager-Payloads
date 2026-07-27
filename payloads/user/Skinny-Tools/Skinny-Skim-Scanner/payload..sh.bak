#!/bin/bash
#
# Title: Skinny-Skim-Scanner
# Description: BLE lescan + signature grep, batched to LOG every 5s. Dies on stop.
# Version: 17.1
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

# --- 3. Die on stop — kill tracked PIDs + all hcitool + exit ---
cleanup() {
    [ -n "$SCAN_PID" ] && kill -9 "$SCAN_PID" 2>/dev/null
    [ -n "$DRAIN_PID" ] && kill -9 "$DRAIN_PID" 2>/dev/null
    killall -9 hcitool 2>/dev/null
    pkill -9 -f "tail -F /tmp/.skim" 2>/dev/null
    pkill -9 -f "grep -i -E $PATTERN" 2>/dev/null
    echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
    LED OFF 2>/dev/null
    rm -f /tmp/.skim_buffer
    exit 0
}
trap cleanup EXIT INT TERM HUP

# --- 4. Prompt + start ---
PROMPT "SKIMMER SCANNER v17.1

BLE lescan, signature grep, batched every 5s.
Press OK to launch."

LOG "[+] Pattern: $PATTERN"
LOG "[+] Scanning..."

# --- 5. Scanner pipeline (single tracked PID group via subshell) ---
(
    hcitool lescan --duplicates 2>/dev/null \
        | grep -i -E "$PATTERN" \
        | grep -v "(unknown)" \
        | awk '!seen[$0]++' \
        > /tmp/.skim_buffer
) &
SCAN_PID=$!

# --- 6. Drainer (single tracked PID) ---
(
    LAST=""
    while true; do
        sleep 5
        NEW=$(cat /tmp/.skim_buffer 2>/dev/null)
        if [ -n "$NEW" ] && [ "$NEW" != "$LAST" ]; then
            echo "$NEW" | while IFS= read -r line; do
                [ -n "$line" ] && LOG "⚠ $line"
            done
            LED R 255 G 0 B 0 2>/dev/null
            for i in 1 2 3; do
                echo "1" > /sys/class/gpio/vibrator/value 2>/dev/null
                sleep 0.1
                echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
                sleep 0.1
            done
            LED OFF 2>/dev/null
            LAST="$NEW"
            : > /tmp/.skim_buffer
        fi
    done
) &
DRAIN_PID=$!

# --- 7. Block until either child exits, then cleanup kills the other ---
wait -n
cleanup
