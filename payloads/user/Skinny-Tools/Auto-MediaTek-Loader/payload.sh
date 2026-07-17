#!/bin/bash
# Title: Auto MediaTek Loader
# Description: Dynamically detects external MediaTek-based cards (including third-party VIDs like Netgear) and maps them natively via the background bus.
# Version: 1
# Author: Jeff Benson (erg0Proxy) - Skinny R&D
# Credit: Based on original hard-coded PID/VID loader by Huntz.


set -u

# Radio Setup
START_INDEX=2  # Start at radio2 / wlan2mon
MAX_INDEX=6    # Max radios to scan

# --- Native Pager Log Helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
log_y() { have LOG && LOG yellow "$1" || echo -e "\033[33m[*] $1\033[0m"; }
log_g() { have LOG && LOG green  "$1" || echo -e "\033[32m[+] $1\033[0m"; }

# ==========================================
# 1. SMART SCANNING & KERNEL BINDING
# ==========================================
log_y "Scanning USB bus for compatible external adapters..."

# A. Build Internal Blocklist to protect default radios
INTERNAL_BLOCKLIST=""
for iface in wlan0 wlan1 wlan0mon wlan1mon; do
    if [ -e "/sys/class/net/$iface/device" ]; then
        RP=$(readlink -f "/sys/class/net/$iface/device")
        INTERNAL_BLOCKLIST="$INTERNAL_BLOCKLIST $RP"
    fi
done

declare -a FOUND_DEVICES=()

# B. Scan all physical USB entries
for dev in /sys/bus/usb/devices/*; do
    [ ! -e "$dev" ] && continue
    [ ! -f "$dev/idVendor" ] && continue
    [ ! -f "$dev/idProduct" ] && continue

    VID=$(cat "$dev/idVendor" | tr '[:upper:]' '[:lower:]')
    PID=$(cat "$dev/idProduct" | tr '[:upper:]' '[:lower:]')

    # Identify if the vendor uses MediaTek hardware under the hood
    # 0e8d = MediaTek, 0846 = Netgear, 2357 = TP-Link, 0b05 = ASUS, 0df6 = Sitecom
    IS_TARGET_VENDOR=0
    case "$VID" in
        "0e8d"|"0846"|"2357"|"0b05"|"0df6")
            IS_TARGET_VENDOR=1
            ;;
    esac

    if [ "$IS_TARGET_VENDOR" -eq 1 ]; then
        FULL_DEV_PATH=$(readlink -f "$dev")
        
        # Skip internal system components
        IS_INTERNAL=0
        for int_path in $INTERNAL_BLOCKLIST; do
            [ -z "$int_path" ] && continue
            if [[ "$int_path" == *"$FULL_DEV_PATH"* ]]; then
                IS_INTERNAL=1; break
            fi
        done
        [ "$IS_INTERNAL" -eq 1 ] && continue

        # Force-inject this newly discovered ID into the driver namespace before checking interfaces
        if [ -d /sys/bus/usb/drivers/mt7921u ]; then
            log_y "Binding driver to target $VID:$PID..."
            echo "$VID $PID" > /sys/bus/usb/drivers/mt7921u/new_id 2>/dev/null
            sleep 1
        fi

        # C. Endpoint Ranking (ff > e0)
        BEST_EP_PATH=""
        HIGHEST_SCORE=-1
        
        for endpoint_dir in "$dev":*; do
            [ ! -d "$endpoint_dir" ] && continue
            if [ -f "$endpoint_dir/bInterfaceClass" ]; then
                CLASS=$(cat "$endpoint_dir/bInterfaceClass")
                
                CURRENT_SCORE=0
                if [ "$CLASS" == "ff" ]; then CURRENT_SCORE=20; 
                elif [ "$CLASS" == "e0" ]; then CURRENT_SCORE=10; 
                else continue; fi
                
                EP_ID=$(echo "$endpoint_dir" | awk -F: '{print $NF}')
                EP_NUM=$(echo "$EP_ID" | awk -F. '{print $2}')
                [ -z "$EP_NUM" ] && EP_NUM=0

                FINAL_SCORE=$((CURRENT_SCORE + EP_NUM))
                
                if [ "$FINAL_SCORE" -gt "$HIGHEST_SCORE" ]; then
                    HIGHEST_SCORE=$FINAL_SCORE
                    BEST_EP_PATH="$endpoint_dir"
                fi
            fi
        done
        
        if [ -n "$BEST_EP_PATH" ]; then
            FOUND_DEVICES+=("$BEST_EP_PATH")
        fi
    fi
done

# ==========================================
# 2. READ PINEAP DEFAULTS
# ==========================================
INT_IFACE="wlan1mon"
[ ! -d "/sys/class/net/$INT_IFACE" ] && INT_IFACE="wlan1"
CURRENT_BANDS=$(uci -q get pineapd.${INT_IFACE}.bands)
[ -z "$CURRENT_BANDS" ] && CURRENT_BANDS="2,5"

# ==========================================
# 3. CONFIGURE DETECTED RADIOS
# ==========================================
COUNT=${#FOUND_DEVICES[@]}
log_g "Found $COUNT external device(s)."

CURRENT_IDX=$START_INDEX

for DEV_PATH in "${FOUND_DEVICES[@]}"; do
    RADIO_NAME="radio${CURRENT_IDX}"
    IFACE_NAME="wlan${CURRENT_IDX}mon"
    WIFI_IFACE_SEC="default_${RADIO_NAME}"       
    PINE_IFACE_SEC="${IFACE_NAME}"

    UCI_PATH=$(readlink -f "$DEV_PATH" | sed 's#^/sys/devices/##')
    log_y "[$RADIO_NAME] Auto-configuring interface..."

    uci -q delete wireless.${RADIO_NAME}
    uci -q delete wireless.${WIFI_IFACE_SEC}

    uci set wireless.${RADIO_NAME}=wifi-device
    uci set wireless.${RADIO_NAME}.type='mac80211'
    uci set wireless.${RADIO_NAME}.path="${UCI_PATH}"
    uci set wireless.${RADIO_NAME}.band='5g'
    uci set wireless.${RADIO_NAME}.channel='auto'
    uci set wireless.${RADIO_NAME}.htmode='VHT80'
    uci set wireless.${RADIO_NAME}.disabled='0'
    
    uci set wireless.${WIFI_IFACE_SEC}=wifi-iface
    uci set wireless.${WIFI_IFACE_SEC}.device="${RADIO_NAME}"
    uci set wireless.${WIFI_IFACE_SEC}.ifname="${IFACE_NAME}"
    uci set wireless.${WIFI_IFACE_SEC}.mode='monitor'
    uci set wireless.${WIFI_IFACE_SEC}.disabled='0'

    uci -q delete pineapd.${PINE_IFACE_SEC}
    uci set pineapd.${PINE_IFACE_SEC}=interface
    uci set pineapd.${PINE_IFACE_SEC}.device="${IFACE_NAME}"
    uci set pineapd.${PINE_IFACE_SEC}.disable='0'
    uci set pineapd.${PINE_IFACE_SEC}.bands="$CURRENT_BANDS"
    uci set pineapd.${PINE_IFACE_SEC}.primary='0'
    uci set pineapd.${PINE_IFACE_SEC}.inject='0'
    uci set pineapd.${PINE_IFACE_SEC}.hop='1'
    uci set pineapd.${PINE_IFACE_SEC}.hopspeed='fast'
    uci set pineapd.${PINE_IFACE_SEC}.chantype='max'

    CURRENT_IDX=$((CURRENT_IDX + 1))
done

# ==========================================
# 4. CLEANUP STALE CONFIGS
# ==========================================
CLEANUP_IDX=$CURRENT_IDX
while [ $CLEANUP_IDX -le $MAX_INDEX ]; do
    RADIO_NAME="radio${CLEANUP_IDX}"
    WIFI_IFACE_SEC="default_${RADIO_NAME}"
    PINE_IFACE_SEC="wlan${CLEANUP_IDX}mon"
    
    if uci -q get wireless.${RADIO_NAME} >/dev/null; then
        uci set wireless.${RADIO_NAME}.disabled='1'
        if uci -q get wireless.${WIFI_IFACE_SEC} >/dev/null; then
             uci set wireless.${WIFI_IFACE_SEC}.disabled='1'
        fi
    fi

    if uci -q get pineapd.${PINE_IFACE_SEC} >/dev/null; then
        uci set pineapd.${PINE_IFACE_SEC}.disable='1'
        uci set pineapd.${PINE_IFACE_SEC}.inject='0'
        uci set pineapd.${PINE_IFACE_SEC}.hop='0'
    fi

    CLEANUP_IDX=$((CLEANUP_IDX + 1))
done

uci commit wireless
uci commit pineapd

# ==========================================
# 5. RELOAD & VERIFY
# ==========================================
log_y "Reloading WiFi services..."
wifi reload

if [ "$COUNT" -eq 0 ]; then
    log_y "No external radios active. Clean synchronization finalized."
    service pineapd restart
    exit 0
fi

log_y "Waiting for hardware to register..."
sleep 2

MAX_RETRIES=15
WAIT_IDX=$START_INDEX
TARGET_IDX=$CURRENT_IDX

while [ $WAIT_IDX -lt $TARGET_IDX ]; do
    IFACE_NAME="wlan${WAIT_IDX}mon"
    RETRY=0
    while [ $RETRY -lt $MAX_RETRIES ]; do
        if [ -d "/sys/class/net/${IFACE_NAME}" ]; then break; fi
        sleep 1
        RETRY=$((RETRY+1))
    done
    WAIT_IDX=$((WAIT_IDX + 1))
done

log_g "Restarting PineAP..."
service pineapd restart

log_g "LOAD SUCCESS: $((TARGET_IDX - START_INDEX)) External Radio(s) Mapped."
