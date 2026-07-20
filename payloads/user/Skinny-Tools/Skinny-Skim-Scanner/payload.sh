#!/bin/bash
#
# Title: Skinny-Skim-Scanner (Dual Classic/BLE Active Radar)
# Description: Real-time dual-band Bluetooth stream engine catching all unseen devices
# Version: 14.2
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
#

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root."
  exit 1
fi

# --- 1. CONFIGURATION & SETUP ---
WORK_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$WORK_DIR/skimmer_detections.log"

# Anchor the signatures file directly to the directory where the script is running
SIGNATURES_FILE="$WORK_DIR/skimmer_signatures.txt"

# Ensure extended globbing is enabled for whitespace parsing
shopt -s extglob

# --- 2. CLEANUP FUNCTION ---
cleanup() {
    echo -e "\n[*] Terminating ALL capture and UI processes aggressively..."
    
    # 1. Clear out our traps so we don't loop endlessly during exit
    trap - EXIT SIGINT SIGTERM
    
    # 2. Kill every background task spawned by this specific shell PID
    kill $(jobs -p) 2>/dev/null
    
    # 3. Force-kill the UI/Alert queue to stop ghost alerts instantly
    killall -9 ALERT LED 2>/dev/null
    
    # 4. Global system sweep for orphaned radio loops
    killall -9 btmon 2>/dev/null
    killall -9 hcitool 2>/dev/null
    killall -9 bluetoothctl 2>/dev/null
    
    # 5. Clear hardware states directly on the pins
    echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
    LED OFF 2>/dev/null
    
    # 6. Safe hardware radio reset
    hciconfig hci0 down 2>/dev/null
    hciconfig hci0 up 2>/dev/null
    
    sleep 0.5
    exit 0
}
# Trap both normal exits and hard interruptions (like Ctrl+C or Pager Stop)
trap cleanup EXIT SIGINT SIGTERM

# --- 3. IN-MEMORY SIGNATURE EXTRACTION ---
RAW_GREP_PATTERN=""

compile_signatures() {
    if [ -f "$SIGNATURES_FILE" ]; then
        local patterns=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line##+([[:space:]])}"
            line="${line%%+([[:space:]])}"

            [[ -z "$line" || "$line" =~ ^# ]] && continue
            patterns+=("$line")
        done < "$SIGNATURES_FILE"

        if [ ${#patterns[@]} -gt 0 ]; then
            local IFS="|"
            RAW_GREP_PATTERN="${patterns[*]}"
        fi
    fi
}

compile_signatures

# Fallback block if patterns array compiled empty
if [ -z "$RAW_GREP_PATTERN" ]; then
    RAW_GREP_PATTERN="HC-05|HC-06|BT04|BT05|JDY-08|JDY-09|JDY-10|JDY-16|JDY-17|MLT-BT|SPP-C|linvor|RNBT-|BT[0-9]{2}|HC-[0-9]{2}"
fi

# Force master match matrix to ignore character casing natively
shopt -s nocasematch

# --- 4. HARDWARE NOTIFICATION ENGINE ---
trigger_pager_alert() {
    local match_line=$1
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Log to disk and stdout instantly
    echo "[$timestamp] ALERT: $match_line" >> "$LOG_FILE"
    echo -e "\n[\033;31mALERT\033[0m] [$timestamp] Match Found: $match_line"

    # Hardware LED Notification (Solid Red)
    LED R 255 G 0 B 0

    # Rapid Vibration Pulses
    for i in 1 2 3; do
        echo "1" > /sys/class/gpio/vibrator/value 2>/dev/null
        sleep 0.1
        echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
        sleep 0.1
    done

    # NATIVE BLOCKING SCREEN PROMPT
    ALERT "⚠ SKIMMER DETECTED" "Hardware Engine Match:\n\n$match_line\n\nDismiss this alert to resume radar scanning."

    LED OFF
}

# --- 5. INITIALIZATION UI ---
touch "$LOG_FILE"

PROMPT "SKIMMER SCANNER v14.2

Aggressive Dual-Mode Discovery Active.
Tracking Protocol Type (Classic vs BLE) via BlueZ Kernel Monitor.

Press OK to launch."

# --- 6. MASTER PERSISTENT STREAM LOOP ---
declare -A SEEN_DEVICES

echo "[+] Instantiating Radio Controller Hardware..."
hciconfig hci0 down 2>/dev/null
sleep 0.5
hciconfig hci0 up 2>/dev/null
sleep 0.5

echo "[+] Launching background discovery engine..."
hciconfig hci0 piscan 2>/dev/null 
hcitool lescan --duplicates > /dev/null 2>&1 & 
hcitool scan > /dev/null 2>&1 & 
sleep 1

echo "[+] Streaming raw kernel Bluetooth events..."

current_type="UNKNOWN"
event_mac=""
event_match_line=""

handle_detection() {
    local match_line=$1
    local bt_mac=$2
    local current_time=$(date +%s)

    if [ -n "${SEEN_DEVICES[$bt_mac]}" ]; then
        if [ $((current_time - ${SEEN_DEVICES[$bt_mac]})) -lt 15 ]; then
            return
        fi
    fi

    SEEN_DEVICES[$bt_mac]=$current_time
    killall -9 hcitool 2>/dev/null
    trigger_pager_alert "$match_line"
    hciconfig hci0 piscan 2>/dev/null
    hcitool lescan --duplicates > /dev/null 2>&1 &
    hcitool scan > /dev/null 2>&1 &
}

while IFS= read -r line; do
    if [[ "$line" =~ "LE Extended Advertising Report" || "$line" =~ "LE Advertising Report" ]]; then
        current_type="BLE"
        event_mac=""
        event_match_line=""
    elif [[ "$line" =~ "HCI Event: LE" ]]; then
        current_type="BLE"
        event_mac=""
        event_match_line=""
    elif [[ "$line" =~ "Inquiry Result" || "$line" =~ "Extended Inquiry Result" || "$line" =~ "HCI Event: Connect Request" || "$line" =~ "Remote Name Request Complete" ]]; then
        current_type="CLASSIC"
        event_mac=""
        event_match_line=""
    fi

    clean_line=$(echo "$line" | tr -d '\r\n' | sed 's/[[:space:]]\+/ /g')
    line_mac=""
    if [[ "$clean_line" =~ ([0-9A-F]{2}:){5}[0-9A-F]{2} ]]; then
        line_mac="${BASH_REMATCH[0]}"
        line_mac=$(echo "$line_mac" | tr '[:lower:]' '[:upper:]')
        event_mac="$line_mac"
    fi

    if [[ "$clean_line" =~ $RAW_GREP_PATTERN ]]; then
        event_match_line="$clean_line"
    fi

    if [ -n "$line_mac" ] || [[ "$clean_line" =~ $RAW_GREP_PATTERN ]]; then
        tagged_line="[$current_type] $clean_line"
        echo "$tagged_line"
    fi

    if [ -n "$event_mac" ] && [ -n "$event_match_line" ]; then
        match_line="[$current_type] $event_match_line"
        if [[ "$event_match_line" != *"$event_mac"* ]]; then
            match_line="$match_line | Address: $event_mac"
        fi
        handle_detection "$match_line" "$event_mac"
        event_match_line=""
    fi
done < <(btmon)
