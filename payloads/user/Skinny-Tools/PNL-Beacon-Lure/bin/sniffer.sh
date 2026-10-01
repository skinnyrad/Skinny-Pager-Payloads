#!/bin/bash
# Title: PNL-Beacon-Lure Hit Sniffer
# Description: Passive monitor that logs only HITS to the daily loot log — a
#              device probing an SSID WE broadcast, or authenticating/(re)assoc
#              to one of our BSSIDs. Every directed probe we receive is also
#              recorded to lists/captured-probes.txt (SSID<TAB>first-seen) and
#              a detail log for retargeting. Optionally, captured SSIDs are
#              re-loaded into the broadcast set so rebroadcasting + hits on
#              them keep working as the flood picks them up (retarget mode).
#              Self-restarts if tcpdump exits.
# Author: Skinny Research & Development
# Version: 2.1
#
# Usage: sniffer.sh [mon_iface] [broadcast_file] [bssid_map] [lootdir] [retarget_file]
#
# Output:
#   LOOTDIR/YYYYMMDD-PNL-Beacon-Lure.log  TS EVENT MAC SSID NAME RSSI NOTE  (hits only)
#   lists/captured-probes.txt               SSID<TAB>first-seen  (retargeting)
#   lists/captured-probes.log               TS MAC SSID RSSI detail

set -u
MON_IFACE="${1:-wlan0mon}"
BROADCAST_FILE="${2:-/tmp/pnl-beacon-lure-broadcast.txt}"
BSSID_MAP="${3:-/tmp/pnl-beacon-lure-bssid-map.txt}"
LOOTDIR="${4:-/root/loot/pnl-beacon-lure}"
RETARGET_FILE="${5:-}"
PAYLOAD_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -n "$PAYLOAD_DIR" ] || PAYLOAD_DIR="/root/payloads/user/Skinny-Tools/PNL-Beacon-Lure"
CAPTURE="${PNL_CAPTURE:-$PAYLOAD_DIR/lists/captured-probes.txt}"
CAPTURE_LOG="${PNL_CAPTURE_LOG:-$PAYLOAD_DIR/lists/captured-probes.log}"
mkdir -p "$LOOTDIR" "$PAYLOAD_DIR/lists" 2>/dev/null

run_sniffer() {
tcpdump -i "$MON_IFACE" -l -e -s 256 -y IEEE802_11_RADIO \
    "wlan type mgt and (wlan subtype probe-req or wlan subtype auth or wlan subtype assoc-req or wlan subtype reassoc-req)" \
    2>/dev/null | awk -v dir="$LOOTDIR" -v bfile="$BROADCAST_FILE" \
        -v bmap="$BSSID_MAP" -v cap="$CAPTURE" -v caplog="$CAPTURE_LOG" -v rfile="$RETARGET_FILE" '
function loghit(ts, ev, mac, ssid, bssid, rssi, note,   f) {
    f = dir "/" strftime("%Y%m%d") "-PNL-Beacon-Lure.log"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts, ev, mac, \
        (ssid == "" ? "<none>" : ssid), "", rssi, note >> f
    close(f)
}
function load_retarget(   l, a, s, n) {
    if (rfile != "") {
        while ((getline l < rfile) > 0) {
            split(l, a, "\t"); s = a[1]; gsub(/\r/, "", s)
            if (s != "" && !(s in bcast)) bcast[s] = 1
        }
        close(rfile)
    }
    # refresh the BSSID map (the injector appends retargeted entries)
    while ((getline l < bmap) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") bsid[a[1]] = a[2] }
    close(bmap)
    last_reload = systime()
}
BEGIN {
    while ((getline l < bfile) > 0) { sub(/\r$/, "", l); if (l != "" && l !~ /^#/) bcast[l] = 1 }
    close(bfile)
    while ((getline l < bmap) > 0) { n = split(l, a, "\t"); if (n >= 2 && a[1] != "") bsid[a[1]] = a[2] }
    close(bmap)
    while ((getline l < cap) > 0) { split(l, a, "\t"); s0 = a[1]; sub(/\r$/, "", s0); if (s0 != "") capseen[s0] = 1 }
    close(cap)
    last_reload = systime()
    load_retarget()
}
/Probe Request/       { ev = "PROBE" }
/Authentication/      { ev = "AUTH" }
/Association Request|Reassociation Request/ { ev = "ASSOC" }
ev != "" {
    if (rfile != "" && (systime() - last_reload) >= 10) load_retarget()
    line = $0
    rssi = "?"
    if (match(line, /-[0-9][0-9]*dBm/)) rssi = substr(line, RSTART, RLENGTH - 3)
    mac = "?"
    if (match(line, /SA:[0-9a-fA-F][0-9a-fA-F:]*[0-9a-fA-F]/)) mac = substr(line, RSTART + 3, RLENGTH - 3)
    bssid = ""
    if (match(line, /BSSID:[0-9a-fA-F][0-9a-fA-F:]*[0-9a-fA-F]/)) bssid = substr(line, RSTART + 6, RLENGTH - 6)
    ssid = ""
    if (match(line, /Probe Request \([^)]*\)/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^Probe Request \(/, "", s); sub(/\)$/, "", s); ssid = s
    } else if (match(line, /Association Request \([^)]*\)/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^Association Request \(/, "", s); sub(/\)$/, "", s); ssid = s
    } else if (match(line, /Reassociation Request \([^)]*\)/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^Reassociation Request \(/, "", s); sub(/\)$/, "", s); ssid = s
    }
    ts = strftime("%Y-%m-%d %H:%M:%S")
    if (ev == "PROBE") {
        if (ssid != "") {
            if (!(ssid in capseen)) { capseen[ssid] = 1; print ssid "\t" ts >> cap; close(cap) }
            printf "%s\t%s\t%s\t%s\n", ts, mac, ssid, rssi >> caplog; close(caplog)
            if (ssid in bcast) loghit(ts, "PROBE", mac, ssid, bssid, rssi, "hit:probe")
        }
    } else {
        if (bssid in bsid) loghit(ts, ev, mac, bsid[bssid], bssid, rssi, "hit:" ev " bssid=" bssid)
    }
    ev = ""
}'
}

while true; do
    run_sniffer
    sleep 2
done
