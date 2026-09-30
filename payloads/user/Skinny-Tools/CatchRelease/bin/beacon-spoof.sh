#!/bin/bash
# Title: Catch-and-Release WPA Beacon Spoofer
# Description: Beacons WPA-lure SSIDs with real WPA2-CCMP (RSN) tags via
#              airbase-ng so they look encrypted in scan lists. Nothing is
#              associable: airbase answers probes/auth with fake EAPOL and
#              the at0 data interface is flushed and held down, so clients
#              can never get an IP or passthrough. Attempts are observed
#              passively by bin/sniffer.sh (MAC + SSID + RSSI).
# Author: Skinny Research & Development
# Version: 1.0
#
# Usage: beacon-spoof.sh [wpa_list] [channel] [mon_iface]
#   wpa_list  - file with SSID|enc lines (default: ../lists/wpa.txt)
#   channel   - 2.4GHz channel to pin (default: 1, matches radio0)
#   mon_iface - monitor interface airbase transmits on (default: wlan0mon)
#
# Notes:
#   - BSSID is derived from the Pager's real wlan0 MAC (real OUI,
#     locally-administered bit CLEAR). iOS ignores LAA BSSIDs, so the
#     02:13:37 style used by older injectors is deliberately avoided.
#   - Requires channel-hop STOP on the tx interface (caller handles it).
#   - airbase-ng creates at0; this script locks it down (flush + down)
#     so no data path can ever exist.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WPA_LIST="${1:-$SCRIPT_DIR/../lists/wpa.txt}"
CHANNEL="${2:-1}"
MON_IFACE="${3:-wlan0mon}"
ESSIDS_FILE="/tmp/catch-release-essids"
APID=""

cleanup() {
    [ -n "$APID" ] && kill "$APID" 2>/dev/null
    sleep 0.5
    [ -n "$APID" ] && kill -KILL "$APID" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# ---- derive a real-OUI, non-LAA BSSID from a hardware MAC ----
# wlan0's MAC can be locally-administered (e.g. 02:13:37:..); iOS ignores
# LAA BSSIDs, so scan for an interface with a real (globally unique) OUI.
BASE_MAC=""
for _if in wlan0mon wlan0mgmt wlan1mon wlan0; do
    _m="$(cat /sys/class/net/$_if/address 2>/dev/null)"
    [ -n "$_m" ] || continue
    _o="$(echo "$_m" | cut -d: -f1)"
    [ $((0x$_o & 2)) -eq 0 ] || continue
    BASE_MAC="$_m"; break
done
[ -n "$BASE_MAC" ] || BASE_MAC="00:13:37:ac:af:24"
# Bump last octet by 1 so we don't clone the mgmt BSS; keep OUI intact.
LAST_HEX="$(echo "$BASE_MAC" | awk -F: '{print $6}')"
LAST_DEC=$((16#$LAST_HEX + 1))
[ "$LAST_DEC" -gt 255 ] && LAST_DEC=0
BSSID="$(echo "$BASE_MAC" | awk -F: -v last="$LAST_DEC" '{printf "%s:%s:%s:%s:%s:%02x", $1,$2,$3,$4,$5,last}')"
BSSID="$(echo "$BSSID" | tr 'A-Z' 'a-z')"
# Safety: refuse locally-administered BSSIDs (first-octet bit 1 set).
FIRST_OCTET="$(echo "$BSSID" | cut -d: -f1)"
if [ $((0x$FIRST_OCTET & 2)) -ne 0 ]; then
    echo "beacon-spoof: derived BSSID $BSSID is locally administered, aborting" >&2
    exit 1
fi

# ---- build clean ESSID list (strip comments, blanks, |enc suffix) ----
grep -v '^[[:space:]]*#' "$WPA_LIST" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | sed 's/|.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' \
    > "$ESSIDS_FILE"
if [ ! -s "$ESSIDS_FILE" ]; then
    echo "beacon-spoof: no SSIDs in $WPA_LIST" >&2
    exit 1
fi
COUNT="$(wc -l < "$ESSIDS_FILE" | tr -d ' ')"
echo "beacon-spoof: advertising $COUNT WPA2-CCMP SSID(s) as $BSSID on $MON_IFACE ch $CHANNEL"

# ---- transmit: WPA2 tags (-Z 4=CCMP), answer all probes (-P),
# ---- beacon probed names too (-C 30), 100ms beacons, quiet ----
airbase-ng --essids "$ESSIDS_FILE" -a "$BSSID" -c "$CHANNEL" \
    -Z 4 -P -C 30 -I 100 -q \
    -F /tmp/catch-release-airbase.pcap \
    "$MON_IFACE" >/tmp/catch-release-airbase.log 2>&1 &
APID=$!
sleep 2
if ! kill -0 "$APID" 2>/dev/null; then
    echo "beacon-spoof: airbase-ng failed to start (see /tmp/catch-release-airbase.log)" >&2
    tail -5 /tmp/catch-release-airbase.log 2>/dev/null >&2
    exit 1
fi

# ---- lockdown: at0 must never carry traffic ----
if ip link show at0 >/dev/null 2>&1; then
    ip addr flush dev at0 2>/dev/null
    ip link set at0 down 2>/dev/null
    echo "beacon-spoof: at0 data interface flushed and held DOWN (no data path)"
fi
echo "beacon-spoof: running (airbase pid $APID)"
wait "$APID"
