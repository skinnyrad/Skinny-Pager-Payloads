#!/usr/bin/env bash
# Title: Quick-Brown-Fox-AP
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
# Description: Uses stock pager functionality for fox hunting




if [ -z "$_RECON_SELECTED_AP_BSSID" ]; then
    LOG red "Error: No target BSSID selected from the Recon menu."
    exit 1
fi

TARGET_CHANNEL="${_RECON_SELECTED_AP_CHANNEL:-1}"
TARGET_BSSID="$_RECON_SELECTED_AP_BSSID"
TARGET_SSID="${_RECON_SELECTED_AP_SSID:-Unknown}"

export LD_LIBRARY_PATH="/usr/lib:/lib:$LD_LIBRARY_PATH"

LOG green "Target Locked: $TARGET_SSID ($TARGET_BSSID)"
LOG "Starting hardware monitor on Channel $TARGET_CHANNEL..."

# Start the targeted hardware monitor in the background
_pineap "MONITOR" "$TARGET_BSSID" "channel=$TARGET_CHANNEL" "rate=1000" > /dev/null 2>&1 &

# Dynamic hardware check (Replaces static sleep 1.5)
# Polls every 100ms and breaks the moment the interface is ready
for i in {1..30}; do
    if iw dev wlan1mon info >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# 3. Dynamic polling loop (Zero sleep - Max speed test)
while true; do
    # Fetch live RSSI from the scan cache on the monitor interface
    RSSI=$(iw dev wlan1mon scan dump 2>/dev/null | grep -i -A 10 "BSS $TARGET_BSSID" | grep "signal:" | awk '{print $2}')
    
    # Fallback 1: Check wlan0's scan cache
    if [ -z "$RSSI" ]; then
        RSSI=$(iw dev wlan0 scan dump 2>/dev/null | grep -i -A 10 "BSS $TARGET_BSSID" | grep "signal:" | awk '{print $2}')
    fi

    # Fallback 2: Force a live targeted scan if the cache is empty
    if [ -z "$RSSI" ]; then
        RSSI=$(iw dev wlan0 scan bssid "$TARGET_BSSID" 2>/dev/null | grep "signal:" | awk '{print $2}')
    fi

    # Clean up output to leave only the raw integer string (stripping decimals)
    RSSI=$(echo "$RSSI" | tr -d 'a-zA-Z/ -' | cut -d'.' -f1)

    if [ -z "$RSSI" ]; then
        LOG yellow "Tracking $TARGET_SSID... (Searching for signal)"
    else
        # Re-apply negative sign for proper dBm display
        RSSI="-$RSSI"

        if [ "$RSSI" -ge -60 ]; then
            LOG green "RSSI: ${RSSI} dBm - STRONG"
        elif [ "$RSSI" -ge -80 ]; then
            LOG "RSSI: ${RSSI} dBm - MODERATE"
        else
            LOG red "RSSI: ${RSSI} dBm - WEAK"
        fi
    fi
done
