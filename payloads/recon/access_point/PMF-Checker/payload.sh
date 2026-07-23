#!/usr/bin/env bash
# Title: PMF-Checker
# Author: Skinny R&D
# Description: Displays PMF/MFP status and security type for a selected Recon AP

# 1. Ensure an Access Point was selected from the Recon menu
if [ -z "$_RECON_SELECTED_AP_BSSID" ]; then
    LOG red "Error: No target BSSID selected from Recon menu."
    exit 1
fi

# Sanitize BSSID: Strip colons and convert to uppercase to match SQLite schema
RAW_BSSID="$_RECON_SELECTED_AP_BSSID"
TARGET_BSSID=$(echo "$RAW_BSSID" | tr -d ':' | tr 'a-z' 'A-Z')
TARGET_SSID="${_RECON_SELECTED_AP_SSID:-<Hidden>}"

LOG "Analyzing Target: $TARGET_SSID"
LOG "BSSID: $RAW_BSSID"

DB_PATH="/root/recon/recon.db"

if [ ! -f "$DB_PATH" ]; then
    LOG red "Error: Recon DB not found at $DB_PATH"
    exit 1
fi

# 2. Query the encryption bitmask for the sanitized BSSID
ENC_VAL=$(sqlite3 "$DB_PATH" "SELECT encryption FROM ssid WHERE UPPER(REPLACE(bssid, ':', '')) = '$TARGET_BSSID' ORDER BY time DESC LIMIT 1;" 2>/dev/null)

if [ -z "$ENC_VAL" ]; then
    LOG yellow "No security record found for $RAW_BSSID"
    exit 0
fi

# 3. Parse security protocol and PMF status from bitmask
eval $(awk -v enc="$ENC_VAL" 'BEGIN {
    # Check WPA3 / PMF bitmask capability flags (0x20, 0x40, 0x80)
    if (and(enc, 0x20) || and(enc, 0x40) || and(enc, 0x80)) {
        pmf = "ENABLED"
        sec = "WPA3 / WPA2-PMF"
    } else if (and(enc, 0x08) || and(enc, 0x10)) {
        pmf = "DISABLED"
        sec = "WPA2-PSK"
    } else if (and(enc, 0x01)) {
        pmf = "N/A"
        sec = "OPEN"
    } else {
        pmf = "DISABLED"
        sec = "WPA2 / Standard"
    }
    
    printf "PMF_STATUS=\"%s\"; SEC_TYPE=\"%s\";\n", pmf, sec
}')

# 4. Print results using Pager LOG helpers
LOG "Security: $SEC_TYPE"

if [ "$PMF_STATUS" = "ENABLED" ]; then
    LOG green "PMF/MFP: ENABLED (Protected)"
elif [ "$PMF_STATUS" = "DISABLED" ]; then
    LOG red "PMF/MFP: DISABLED (Vulnerable)"
else
    LOG yellow "PMF/MFP: N/A (Open Network)"
fi
