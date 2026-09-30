#!/bin/bash
## Title: Catch-and-Release TSCM Lure
## Description: TSCM catch-and-release lure. Floods a large set of lure SSIDs
##              (WiGLE-targeted + common router defaults + store/retail/hotel +
##              open + Enterprise) as real WPA2/Enterprise/open beacons on the
##              inject radio, so nearby devices that recognize an SSID from
##              their preferred-network list probe/attempt it — we never
##              provide a network. Store SSIDs are beaconed as BOTH open and
##              WPA2 (security varies). The loot log records only HITS; every
##              probe heard is saved to lists/captured-probes.txt (retargeting)
##              and can optionally be folded back into the live flood.
## Version: 2.0
## Author: Skinny Research & Development
##
## Notes:
##   - WPA lures are broadcast as up to WPA_R0_MAX+WPA_R1_MAX native hostapd
##     AP BSSes (radio0 + the USB radio), one BSSID + WPA2 SSID each, all at
##     once. They can never complete association (no matching PSK). Extra
##     SSIDs in the list cycle through the slots every WPA_ROTATE_SECS via
##     live hostapd_cli set ssid (no reload).
##   - wlan0mon is used as the passive RX sniffer. wlan0mon/wlan2mon cannot
##     inject, so airbase modes are legacy/experimental (WPA_TRANSPORT).
##   - Open lures (PineAP pool + wlan0open) are off unless OPEN_ENABLE=1.
## Layout (under this payload dir):
##   lists/open.txt                - open SSIDs, one per line
##   lists/wpa.txt                 - targeted WPA/WPA2-PSK SSIDs (SSID|enc)
##   lists/common_router_ssids.txt - default router SSIDs, ALWAYS flooded
##   lists/stores.txt              - retail/food/hotel SSIDs (open AND WPA2)
##   lists/apple.txt               - Apple Store SSIDs (open AND WPA2)
##   lists/wpa_ent.txt             - WPA2-Enterprise (802.1X) SSIDs
##   bin/beacon-flood.py           - raw 802.11 beacon injector (PSK/open/Ent)
##   bin/gen-common-ssids.py       - expand router SSID templates -> common list
##   bin/sniffer.sh                - HITS-only logger + captured-probes
##   bin/beacon-spoof.sh           - airbase-ng WPA2 beacon TX (legacy)
## Assessment: pre-pull target SSIDs with WiGLE yourself into lists/wpa.txt and
## open.txt; the payload always floods common_router_ssids.txt too. The phone
## only has to ATTEMPT; no real network is ever provided.
## Loot:
##   LOOTDIR/YYYYMMDD-Catch-and-release.log - HITS only: a device probed an SSID
##     we broadcast, or AUTH/ASSOC'd to one of our BSSIDs (daily rollover)
##   lists/captured-probes.txt    - unique probed SSIDs we heard (retargeting)
##   lists/captured-probes.log    - TS MAC SSID RSSI detail of received probes

# Resolve our own directory robustly: the Pager UI may launch us with a
# relative $0 and an unexpected cwd, so fall back to known install roots.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ ! -f "$SCRIPT_DIR/bin/beacon-flood.py" ]; then
    for _d in \
        "$SCRIPT_DIR" "$PWD" \
        "/root/payloads/$(dirname "$0")" "/mmc/root/payloads/$(dirname "$0")" \
        /mmc/root/payloads/user/Skinny-Tools/CatchRelease \
        /root/payloads/user/Skinny-Tools/CatchRelease; do
        [ -f "$_d/bin/beacon-flood.py" ] && { SCRIPT_DIR="$(cd "$_d" 2>/dev/null && pwd)"; break; }
    done
fi
OPEN_LIST="$SCRIPT_DIR/lists/open.txt"
WPA_LIST="$SCRIPT_DIR/lists/wpa.txt"
COMMON_LIST="$SCRIPT_DIR/lists/common_router_ssids.txt"
STORES_LIST="$SCRIPT_DIR/lists/stores.txt"
APPLE_LIST="$SCRIPT_DIR/lists/apple.txt"
ENT_LIST="$SCRIPT_DIR/lists/wpa_ent.txt"
RETARGET_FILE="$SCRIPT_DIR/lists/captured-probes.txt"
SPOOFER="$SCRIPT_DIR/bin/beacon-spoof.sh"
SNIFFER="$SCRIPT_DIR/bin/sniffer.sh"

LOOTDIR="/root/loot/catch-release"
BAKDIR="/root/.catch-release.bak"   # persistent: survives reboot/crash
SEEN_NONAME="/tmp/catch-release-noname"
CHANNEL="1"
MON_IFACE="wlan0mon"
OPEN_IFACE="wlan0open"
OPEN_SSID="CatchRelease-TEST"
WPA_IFACE="wlan0wpa"
WPA_KEY="CatchRelease123"
WPA_ROTATE_SECS="0.5"  # cycle overflow WPA SSIDs through the slots (0 = off)
OPEN_ENABLE="0"        # 1 = open AP + PineAP pool/mimic (uses the inject radio)
OPEN_FLOOD="1"         # 1 = also beacon lists/open.txt as OPEN during flood mode
ENT_FLOOD="1"          # 1 = also beacon lists/wpa_ent.txt as WPA2-Enterprise
# Lure-type checklist (set at run time from the Pager UI; see choose_lures)
ENABLE_COMMON="1"      # lists/common_router_ssids.txt
ENABLE_WPA="1"         # lists/wpa.txt (+ lists/wpa_ent.txt)
ENABLE_OPEN="1"        # lists/open.txt
ENABLE_STORES="1"      # lists/stores.txt (beaconed as BOTH open and WPA2)
ENABLE_APPLE="1"       # lists/apple.txt  (beaconed as BOTH open and WPA2)
ENABLE_RETARGET="0"    # fold captured probes back into the live flood
WPA_TRANSPORT="flood"  # flood (whole list via injection) | hostapd_multi | airbase | native
WPA_R0_MAX="3"         # WPA2 AP BSSes on radio0 (hw: mgmt+APs <= 4 total)
WPA_R1_MAX="1"         # WPA2 AP BSSes on the USB radio (hw: AP <= 1)
WPA5_CHANNEL="36"      # fixed 5GHz channel for the USB-radio AP
WPA_MON_IFACE="wlan1mon" # USB-radio monitor (5GHz sniff + flood TX + airbase legacy)
WPA_FLOOD_CYCLE_MS="200" # beacon-flood target ms per full pass over the SSID list
WPA_SLOTS=""           # active WPA AP ifaces (built at setup)
CATCH_IP="10.99.99.1"
SUMMARY_SECS="60"
DWELL_SECS="6"   # seconds to let an open client DHCP before the kick

KICK_PID=""; WPA_PID=""; SPOOF_PID=""; SNIFF_PID=""; SNIFF2_PID=""; FLOOD_PID=""; CHAN_PID=""
WPA_SSID_LIVE=""
OPEN_BSSID=""; OPEN_SSID_LIVE=""
PRIOR_POOL=""; PRIOR_NMODE=""; PRIOR_DMODE=""
EVIL_SVC=""; EVIL_WAS_ON="0"

export LD_LIBRARY_PATH="/usr/lib:/lib:$LD_LIBRARY_PATH"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Mirror to Pager payload log AND stdout (LOG is a no-op over raw SSH).
emit() {
    local first="$1"
    case "$first" in
        red|green|yellow|blue|magenta|cyan|white)
            shift
            LOG "$first" "$*" 2>/dev/null
            printf '%s\n' "$*"
            ;;
        *)
            LOG "$*" 2>/dev/null
            printf '%s\n' "$*"
            ;;
    esac
}

cr_logfile() { date +"$LOOTDIR/%Y%m%d-Catch-and-release.log"; }

cr_log() { # $1=event $2=mac $3=ssid $4=name $5=rssi $6=note
    local f
    f="$(cr_logfile)"
    mkdir -p "$LOOTDIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        flock -x "$LOOTDIR/.lock" -c "printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \"$(ts)\" \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" >> \"$f\"" 2>/dev/null \
        || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" "$4" "$5" "$6" >> "$f" 2>/dev/null
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" "$4" "$5" "$6" >> "$f" 2>/dev/null
    fi
}

cr_hostname() { # $1=mac -> hostname from dummy-DHCP leases, else empty
    awk -v m="$1" 'tolower($2)==tolower(m) {print $4; exit}' /tmp/dhcp.leases 2>/dev/null
}

cr_vendor() { # $1=mac -> OUI vendor, else empty
    local oui vn
    oui="$(echo "$1" | tr 'A-F' 'a-f' | cut -d: -f1-3)"
    if [ -r /lib/hak5/oui.txt ]; then
        vn="$(awk -F'\t' -v o="$oui" 'tolower($1)==o {print $2; exit}' /lib/hak5/oui.txt 2>/dev/null)"
        [ -n "$vn" ] && { echo "$vn"; return; }
    fi
    if [ -r "$HOME/.hcxtools/oui.txt" ]; then
        whoismac -m "$1" 2>/dev/null \
            | grep -viE 'failed|download|oui\.txt|^[[:space:]]*$|^use ' \
            | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
}

cr_name_for() { # $1=mac -> hostname, vendor, or unknown
    local hn vn
    hn="$(cr_hostname "$1")"
    if [ -n "$hn" ] && [ "$hn" != "*" ]; then echo "$hn"; return; fi
    vn="$(cr_vendor "$1")"
    if [ -n "$vn" ]; then echo "$vn"; return; fi
    echo "unknown"
}

clean_list() { # $1=file -> stdout clean lines (no comments/blanks, strip |suffix)
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        | sed 's/|.*//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---- interactive lure-type checklist (Pager UI) -----------------------

gui_confirm() { # $1=message -> 0 if the user confirmed
    local resp rc
    resp="$(CONFIRMATION_DIALOG "$1" 2>/dev/null)"
    rc=$?
    case "$rc" in
        "${DUCKYSCRIPT_REJECTED:-3}"|"${DUCKYSCRIPT_CANCELLED:-2}"|"${DUCKYSCRIPT_ERROR:-4}") return 1 ;;
    esac
    [ "$resp" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ] && return 0
    return 1
}

# Lure selection. Shows a LIST_PICKER preset menu (multi-select emulation)
# when launched from the Pager UI, plus a "Retarget?" confirmation. Over
# SSH/automation set CATCH_NO_PROMPT=1 and override with CATCH_COMMON/CATCH_WPA/
# CATCH_OPEN/CATCH_RETARGET (0/1).
choose_lures() {
    ENABLE_COMMON="${CATCH_COMMON:-1}"
    ENABLE_WPA="${CATCH_WPA:-1}"
    ENABLE_OPEN="${CATCH_OPEN:-1}"
    ENABLE_STORES="${CATCH_STORES:-1}"
    ENABLE_APPLE="${CATCH_APPLE:-1}"
    ENABLE_RETARGET="${CATCH_RETARGET:-0}"
    if [ "${CATCH_NO_PROMPT:-0}" = "1" ] || ! command -v LIST_PICKER >/dev/null 2>&1; then
        emit yellow "[$(ts)] Lure selection (no prompt): router=$ENABLE_COMMON wpa=$ENABLE_WPA open=$ENABLE_OPEN stores=$ENABLE_STORES apple=$ENABLE_APPLE retarget=$ENABLE_RETARGET"
        return 0
    fi
    local choice
    choice="$(LIST_PICKER "Broadcast which lures?" \
        "All" "Router only" "Open only" "WPA only" "Store only" "Apple only" "Open + WPA only" "All" 2>/dev/null)"
    ENABLE_COMMON=0; ENABLE_WPA=0; ENABLE_OPEN=0; ENABLE_STORES=0; ENABLE_APPLE=0
    case "$choice" in
        "Router only")    ENABLE_COMMON=1 ;;
        "Open only")      ENABLE_OPEN=1 ;;
        "WPA only")       ENABLE_WPA=1 ;;
        "Store only")     ENABLE_STORES=1 ;;
        "Apple only")     ENABLE_APPLE=1 ;;
        "Open + WPA only") ENABLE_OPEN=1; ENABLE_WPA=1 ;;
        *)                ENABLE_COMMON=1; ENABLE_WPA=1; ENABLE_OPEN=1; ENABLE_STORES=1; ENABLE_APPLE=1 ;;
    esac
    gui_confirm "Retarget captured probes (rebroadcast them)?" && ENABLE_RETARGET=1 || ENABLE_RETARGET=0
    emit green "[$(ts)] Lure selection '$choice': router=$ENABLE_COMMON wpa=$ENABLE_WPA open=$ENABLE_OPEN stores=$ENABLE_STORES apple=$ENABLE_APPLE retarget=$ENABLE_RETARGET"
}

# ------------------------------ setup ---------------------------------

snapshot() {
    mkdir -p "$BAKDIR" 2>/dev/null
    for f in wireless network dhcp firewall pineapd; do
        cp "/etc/config/$f" "$BAKDIR/$f" 2>/dev/null
    done
    PRIOR_POOL="$(PINEAPPLE_SSID_POOL_LIST 2>/dev/null)"
    PRIOR_NMODE="$(PINEAPPLE_NETWORK_FILTER_MODE 2>/dev/null; echo)"
    PRIOR_DMODE="$(PINEAPPLE_DEVICE_FILTER_MODE 2>/dev/null; echo)"
    emit "[$(ts)] pre-state saved -> $BAKDIR"
}

evilportal_off() {
    local svc
    svc="$(ls /etc/init.d/ 2>/dev/null | grep -iE '^evil.?portal$' | head -n 1)"
    [ -z "$svc" ] && return
    EVIL_SVC="/etc/init.d/$svc"
    if "$EVIL_SVC" enabled >/dev/null 2>&1; then EVIL_WAS_ON="1"; fi
    "$EVIL_SVC" stop >/dev/null 2>&1
    "$EVIL_SVC" disable >/dev/null 2>&1
    emit yellow "[$(ts)] Evil portal stopped/disabled (was_on=$EVIL_WAS_ON)"
}

# Isolate lure ifaces on br-catch with dummy DHCP (IP, NO gateway) and a
# dedicated REJECT-forward firewall zone. mgmt (wlan0mgmt/eth0) stays on
# br-lan so SSH/UI survive every reload.
isolate_net() {
    emit yellow "[$(ts)] Isolating $OPEN_IFACE/wlan0wpa onto br-catch ($CATCH_IP, no gateway)..."
    uci del_list network.brlan.ports="$OPEN_IFACE" 2>/dev/null
    uci del_list network.brlan.ports='wlan0wpa' 2>/dev/null

    uci set network.catch=device 2>/dev/null
    uci set network.catch.name='br-catch' 2>/dev/null
    uci set network.catch.type='bridge' 2>/dev/null
    uci del_list network.catch.ports="$OPEN_IFACE" 2>/dev/null
    uci del_list network.catch.ports='wlan0wpa' 2>/dev/null
    uci add_list network.catch.ports="$OPEN_IFACE" 2>/dev/null
    uci add_list network.catch.ports='wlan0wpa' 2>/dev/null

    uci set network.catchif=interface 2>/dev/null
    uci set network.catchif.device='br-catch' 2>/dev/null
    uci set network.catchif.proto='static' 2>/dev/null
    uci set network.catchif.ipaddr="$CATCH_IP" 2>/dev/null
    uci set network.catchif.netmask='255.255.255.0' 2>/dev/null

    # Dummy DHCP: Hands out IPs + hostname exchange, NO router/DNS option.
    uci set dhcp.catch=dhcp 2>/dev/null
    uci set dhcp.catch.interface='catchif' 2>/dev/null
    uci set dhcp.catch.start='50' 2>/dev/null
    uci set dhcp.catch.limit='100' 2>/dev/null
    uci set dhcp.catch.leasetime='10m' 2>/dev/null
    uci set dhcp.catch.dhcpv4='server' 2>/dev/null

    uci set firewall.catch=zone 2>/dev/null
    uci set firewall.catch.name='catch' 2>/dev/null
    uci set firewall.catch.network='catchif' 2>/dev/null
    uci set firewall.catch.input='ACCEPT' 2>/dev/null
    uci set firewall.catch.output='ACCEPT' 2>/dev/null
    uci set firewall.catch.forward='REJECT' 2>/dev/null
    # No forwarding rules touch 'catch' -> nothing leaves the lure net.
    uci commit network 2>/dev/null
    uci commit dhcp 2>/dev/null
    uci commit firewall 2>/dev/null
    /etc/init.d/network reload >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    sleep 2
    emit green "[$(ts)] Isolation active. FORWARD chain:"
    iptables -L FORWARD -v -n 2>/dev/null | head -n 8 | while read -r l; do emit "  $l"; done
}

open_setup() {
    emit yellow "[$(ts)] Bringing up open lure AP ($OPEN_SSID) + pool + mimic..."
    WIFI_OPEN_AP "$OPEN_IFACE" "$OPEN_SSID" >/dev/null 2>&1
    sleep 2
    PINEAPPLE_SSID_POOL_CLEAR >/dev/null 2>&1
    clean_list "$OPEN_LIST" | while IFS= read -r ssid; do
        [ -n "$ssid" ] && PINEAPPLE_SSID_POOL_ADD "$ssid" >/dev/null 2>&1
    done
    PINEAPPLE_SSID_POOL_START >/dev/null 2>&1
    PINEAPPLE_MIMIC_ENABLE >/dev/null 2>&1
    PINEAPPLE_NETWORK_FILTER_MODE allow >/dev/null 2>&1
    PINEAPPLE_NETWORK_FILTER_CLEAR allow >/dev/null 2>&1
    clean_list "$OPEN_LIST" | while IFS= read -r ssid; do
        [ -n "$ssid" ] && PINEAPPLE_NETWORK_FILTER_ADD allow "$ssid" >/dev/null 2>&1
    done
    PINEAPPLE_DEVICE_FILTER_MODE deny >/dev/null 2>&1
    PINEAPPLE_DEVICE_FILTER_CLEAR deny >/dev/null 2>&1
    OPEN_SSID_LIVE="$(iw dev "$OPEN_IFACE" info 2>/dev/null | awk '/ssid/{print $2; exit}')"
    OPEN_BSSID="$(hostapd_cli -p /var/run/hostapd -i "$OPEN_IFACE" status 2>/dev/null | awk -F= '/^bssid\[/{print $2; exit}')"
    emit green "[$(ts)] Open AP live: ssid='$OPEN_SSID_LIVE' bssid='$OPEN_BSSID'"
}

# ------------------------------ WPA lure ------------------------------

# Native WPA2 AP on wlan0wpa. Looks WPA2 to clients, but we hold a PSK they
# don't have, so the 4-way handshake can never complete. SSIDs from wpa.txt
# rotate on the live BSS so multiple lures get airtime.
wpa_apply() { # $1=ssid
    [ -n "$1" ] || return
    WPA_SSID_LIVE="$1"
    WIFI_WPA_AP "$WPA_IFACE" "$1" psk2 "$WPA_KEY" >/dev/null 2>&1
    cr_log "WPA-BEACON" "" "$1" "" "" "wpa"
}

# Cycle the SSID list through the active slots via live hostapd_cli set ssid
# (no wifi reload, so no disruption to the other lures). Slot j shows
# ssids[(offset+j) mod n]; over n ticks every SSID visits every slot.
wpa_rotate_loop() {
    local ssids n k offset j slot ssid
    ssids="$(clean_list "$WPA_LIST")"
    n="$(printf '%s\n' "$ssids" | grep -c .)"
    k="$(printf '%s\n' $WPA_SLOTS | grep -c .)"
    [ "$n" -gt 0 ] && [ "$k" -gt 0 ] || return
    offset=0
    while true; do
        sleep "$WPA_ROTATE_SECS"
        offset=$(( (offset + 1) % n ))
        j=0
        for slot in $WPA_SLOTS; do
            ssid="$(printf '%s\n' "$ssids" | sed -n "$(( (offset + j) % n + 1 ))p")"
            hostapd_cli -p /var/run/hostapd -i "$slot" set ssid "$ssid" >/dev/null 2>&1
            cr_log "WPA-ROTATE" "" "$ssid" "" "" "slot:$slot"
            j=$((j + 1))
        done
        emit yellow "[$(ts)] WPA rotate (offset $offset/$n): $WPA_SLOTS"
    done
}

wpa_setup() {
    emit yellow "[$(ts)] Enabling native WPA2 lure AP on $WPA_IFACE..."
    local first bssid
    first="$(clean_list "$WPA_LIST" | head -n 1)"
    if [ -z "$first" ]; then
        emit yellow "[$(ts)] No WPA SSIDs in $WPA_LIST; skipping WPA lure."
        return
    fi
    wpa_apply "$first"
    sleep 2
    bssid="$(hostapd_cli -p /var/run/hostapd -i "$WPA_IFACE" status 2>/dev/null | awk -F= '/^bssid\[/{print $2; exit}')"
    emit green "[$(ts)] WPA2 lure live: ssid='$WPA_SSID_LIVE' bssid='${bssid:-?}'"
    if [ "$WPA_ROTATE_SECS" -gt 0 ] 2>/dev/null && [ "$(clean_list "$WPA_LIST" | grep -c .)" -gt 1 ]; then
        wpa_rotate_loop &
        WPA_PID=$!
        emit green "[$(ts)] WPA SSID rotation every ${WPA_ROTATE_SECS}s (pid $WPA_PID)."
    fi
}

# Airbase-ng multi-SSID WPA2 lure on the inject radio (wlan1mon). One BSSID
# per SSID, all WPA2-CCMP; clients can never finish the 4-way handshake.
# Frees nothing on radio0, so no hostapd vif pressure.
wpa_airbase_start() {
    emit yellow "[$(ts)] Starting airbase-ng multi-SSID WPA2 lure on $WPA_MON_IFACE..."
    PINEAPPLE_MIMIC_DISABLE >/dev/null 2>&1
    PINEAPPLE_SSID_POOL_STOP >/dev/null 2>&1
    "$SPOOFER" "$WPA_LIST" "$CHANNEL" "$WPA_MON_IFACE" &
    SPOOF_PID=$!
    sleep 3
    if ! kill -0 "$SPOOF_PID" 2>/dev/null; then
        emit red "[$(ts)] FATAL: beacon spoofer died. Check /tmp/catch-release-airbase.log"
        shutdown
    fi
    emit green "[$(ts)] WPA airbase lure running (pid $SPOOF_PID) on $WPA_MON_IFACE."
}

# Write one AP slot into UCI. $1=section $2=radio $3=ifname $4=ssid
wpa_slot_set() {
    uci set wireless.$1=wifi-iface
    uci set wireless.$1.device="$2"
    uci set wireless.$1.ifname="$3"
    uci set wireless.$1.mode='ap'
    uci set wireless.$1.ssid="$4"
    uci set wireless.$1.encryption='psk2'
    uci set wireless.$1.key="$WPA_KEY"
    uci set wireless.$1.disabled='0'
    uci set wireless.$1.hidden='0'
}

# Native multi-SSID WPA2 lure: WPA_R0_MAX hostapd AP BSSes on radio0 plus
# WPA_R1_MAX on the USB radio, each a distinct WPA2 SSID/BSSID. radio0 caps
# at 4 managed/AP vifs, so the two sta vifs are parked (mgmt + N APs + mon).
# Extra SSIDs beyond the slot count cycle through the slots via rotation.
wpa_multi_setup() {
    emit yellow "[$(ts)] Configuring multi-SSID WPA2 lure (radio0<=$WPA_R0_MAX, usb<=$WPA_R1_MAX)..."
    uci set wireless.dummy_radio0.disabled='1' 2>/dev/null
    uci set wireless.wlan0cli.disabled='1' 2>/dev/null
    # Drop stale WPA AP sections from prior runs (named or anonymous).
    local sec s ifn i ssid
    while :; do
        sec=""
        for s in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
            case "$(uci get wireless.$s.ifname 2>/dev/null)" in
                wlan0wpa[2-9]|wlan0wpa[1-9][0-9]|wlan1ap) sec="$s"; break ;;
            esac
        done
        [ -n "$sec" ] || break
        uci -q delete wireless.$sec
    done
    # radio0 slots
    i=0; WPA_SLOTS=""
    while IFS= read -r ssid; do
        [ -n "$ssid" ] || continue
        [ "$i" -ge "$WPA_R0_MAX" ] && break
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then sec="wlan0wpa"; ifn="wlan0wpa"; else sec="wpa$i"; ifn="wlan0wpa$i"; fi
        wpa_slot_set "$sec" radio0 "$ifn" "$ssid"
        WPA_SLOTS="$WPA_SLOTS $ifn"
        cr_log "WPA-BEACON" "" "$ssid" "" "" "hostapd:$ifn"
    done < <(clean_list "$WPA_LIST")
    local r0="$i"
    # USB radio slot (next SSID), fixed channel
    if [ "$WPA_R1_MAX" -gt 0 ]; then
        ssid="$(clean_list "$WPA_LIST" | sed -n "$((r0 + 1))p")"
        if [ -n "$ssid" ]; then
            uci set wireless.radio1.channel="$WPA5_CHANNEL" 2>/dev/null
            uci set wireless.radio1.disabled='0' 2>/dev/null
            wpa_slot_set wlan1ap radio1 wlan1ap "$ssid"
            WPA_SLOTS="$WPA_SLOTS wlan1ap"
            cr_log "WPA-BEACON" "" "$ssid" "" "" "hostapd:wlan1ap"
        fi
    fi
    if [ -z "$WPA_SLOTS" ]; then
        emit yellow "[$(ts)] No WPA SSIDs in $WPA_LIST; skipping WPA lure."
        return
    fi
    uci commit wireless
    local k t up
    k="$(printf '%s\n' $WPA_SLOTS | grep -c .)"
    emit yellow "[$(ts)] Reloading WiFi with $k WPA2 AP(s)..."
    wifi reload >/dev/null 2>&1
    t=0
    while [ "$t" -lt 40 ]; do
        up=0
        for ifn in $WPA_SLOTS; do [ -d "/sys/class/net/$ifn" ] && up=$((up + 1)); done
        [ "$up" -ge "$k" ] && break
        sleep 2; t=$((t + 2))
    done
    for ifn in $WPA_SLOTS; do
        if [ -d "/sys/class/net/$ifn" ]; then
            emit green "[$(ts)] WPA2 AP up: $ifn"
        else
            emit red "[$(ts)] WARN: $ifn did not come up"
        fi
    done
    local n
    n="$(clean_list "$WPA_LIST" | grep -c .)"
    if [ "$WPA_ROTATE_SECS" != "0" ] && [ "$n" -gt "$k" ]; then
        wpa_rotate_loop &
        WPA_PID=$!
        emit green "[$(ts)] Rotating $n WPA SSIDs through $k slots every ${WPA_ROTATE_SECS}s (pid $WPA_PID)."
    fi
}

# Beacon-flood WPA2 lure: inject WPA2-CCMP beacons for the WHOLE list on the
# inject radio (wlan1mon) at once — bypasses the 4-AP hostapd hardware cap.
# Frames carry a real RSN IE; nothing answers association.
# Everything we advertise (psk + common + open + ent) — the sniffer flags a
# PROBE as a HIT when the probed SSID is in this set.
build_broadcast_set() {
    { [ "$ENABLE_WPA" = "1" ] && clean_list "$WPA_LIST"
      [ "$ENABLE_COMMON" = "1" ] && clean_list "$COMMON_LIST"
      [ "$ENABLE_OPEN" = "1" ] && clean_list "$OPEN_LIST"
      [ "$ENABLE_STORES" = "1" ] && clean_list "$STORES_LIST"
      [ "$ENABLE_APPLE" = "1" ] && clean_list "$APPLE_LIST"
      [ "$ENABLE_WPA" = "1" ] && clean_list "$ENT_LIST"; } 2>/dev/null | sort -u > /tmp/catch-release-broadcast.txt
    emit green "[$(ts)] Broadcast set: $(grep -c . /tmp/catch-release-broadcast.txt) SSIDs -> /tmp/catch-release-broadcast.txt"
}

# PineAP (pineapd) hops the inject radio and will override our channel. Lock it
# for the run: stop hopping, try to pin recon to the channel, and verify it
# stays. Returns 0 on success.
lock_inject_channel() {
    local i ch1 ch2
    for i in 1 2 3 4 5; do
        PINEAPPLE_HOPPING_STOP >/dev/null 2>&1
        PINEAPPLE_EXAMINE_CHANNEL "$CHANNEL" >/dev/null 2>&1
        iw dev "$WPA_MON_IFACE" set channel "$CHANNEL" HT20 2>/dev/null \
            || iw dev "$WPA_MON_IFACE" set channel "$CHANNEL" 2>/dev/null
        sleep 2
        ch1="$(iw dev "$WPA_MON_IFACE" info 2>/dev/null | awk '/channel/{print $2}')"
        sleep 1
        ch2="$(iw dev "$WPA_MON_IFACE" info 2>/dev/null | awk '/channel/{print $2}')"
        if [ "$ch1" = "$CHANNEL" ] && [ "$ch2" = "$CHANNEL" ]; then
            emit green "[$(ts)] Inject radio $WPA_MON_IFACE locked on ch$CHANNEL"
            return 0
        fi
        emit yellow "[$(ts)] $WPA_MON_IFACE not stable (got $ch1/$ch2, want $CHANNEL); retrying..."
    done
    emit red "[$(ts)] WARN: could not lock $WPA_MON_IFACE to ch$CHANNEL (hopper still active?)"
    return 1
}

# Keep the inject radio pinned during the run (in case PineAP resumes hopping).
channel_keeper() {
    local ch
    while true; do
        sleep 5
        ch="$(iw dev "$WPA_MON_IFACE" info 2>/dev/null | awk '/channel/{print $2}')"
        if [ "$ch" != "$CHANNEL" ]; then
            PINEAPPLE_HOPPING_STOP >/dev/null 2>&1
            iw dev "$WPA_MON_IFACE" set channel "$CHANNEL" HT20 2>/dev/null \
                || iw dev "$WPA_MON_IFACE" set channel "$CHANNEL" 2>/dev/null
        fi
    done
}

wpa_flood_start() {
    local nwpa nopen nent nstore open_arg ent_arg pskfile openfile ncommon rt_arg rt_secs
    rt_arg=""; rt_secs="15"
    [ "$ENABLE_RETARGET" = "1" ] && rt_arg="$RETARGET_FILE"
    pskfile="/tmp/catch-release-psk.txt"
    openfile="/tmp/catch-release-open.txt"
    # psk = targeted WPA + common defaults + stores (beaconed as WPA2 too)
    { [ "$ENABLE_WPA" = "1" ] && clean_list "$WPA_LIST"
      [ "$ENABLE_COMMON" = "1" ] && clean_list "$COMMON_LIST"
      [ "$ENABLE_STORES" = "1" ] && clean_list "$STORES_LIST"
      [ "$ENABLE_APPLE" = "1" ] && clean_list "$APPLE_LIST"; } 2>/dev/null | sort -u > "$pskfile"
    [ -s "$pskfile" ] || : > "$pskfile"
    # open = open list + stores + apple (stores/apple are beaconed as open too)
    { [ "$ENABLE_OPEN" = "1" ] && clean_list "$OPEN_LIST"
      [ "$ENABLE_STORES" = "1" ] && clean_list "$STORES_LIST"
      [ "$ENABLE_APPLE" = "1" ] && clean_list "$APPLE_LIST"; } 2>/dev/null | sort -u > "$openfile"
    nwpa="$(grep -c . "$pskfile" 2>/dev/null)"
    ncommon=0
    [ "$ENABLE_COMMON" = "1" ] && ncommon="$(clean_list "$COMMON_LIST" 2>/dev/null | grep -c .)"
    nstore=0
    [ "$ENABLE_STORES" = "1" ] && nstore="$(clean_list "$STORES_LIST" 2>/dev/null | grep -c .)"
    nopen=0; nent=0; open_arg=""; ent_arg=""
    if [ -s "$openfile" ]; then nopen="$(grep -c . "$openfile")"; open_arg="$openfile"; fi
    if [ "$ENABLE_WPA" = "1" ] && [ "$ENT_FLOOD" = "1" ] && [ -f "$ENT_LIST" ]; then
        nent="$(clean_list "$ENT_LIST" | grep -c .)"
        ent_arg="$ENT_LIST"
    fi
    emit yellow "[$(ts)] Starting beacon flood: $nwpa psk (incl $ncommon common, $nstore stores) + $nopen open + $nent ent on $WPA_MON_IFACE (retarget=$ENABLE_RETARGET)..."
    # a monitor vif can't share the radio with an AP; drop any stale wlan1ap
    local s
    for s in $(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
        [ "$(uci get wireless.$s.ifname 2>/dev/null)" = "wlan1ap" ] && { uci -q delete wireless.$s; uci commit wireless; }
    done
    lock_inject_channel
    channel_keeper &
    CHAN_PID=$!
    python3 "$SCRIPT_DIR/bin/beacon-flood.py" "$WPA_MON_IFACE" "$CHANNEL" "$pskfile" "$WPA_FLOOD_CYCLE_MS" "$open_arg" "$ent_arg" "$rt_arg" "$rt_secs" \
        >/tmp/catch-release-flood.log 2>&1 &
    FLOOD_PID=$!
    sleep 2
    if ! kill -0 "$FLOOD_PID" 2>/dev/null; then
        emit red "[$(ts)] FATAL: beacon flood died. See /tmp/catch-release-flood.log"
        shutdown
    fi
    emit green "[$(ts)] Beacon flood running (pid $FLOOD_PID)."
}

# netifd does not always attach the AP vifs to br-catch on a wifi reload
# (the iface may not exist yet when the network reload runs). Force it.
ensure_bridge() {
    local ifc
    for ifc in "$OPEN_IFACE" "$WPA_IFACE"; do
        [ -d "/sys/class/net/$ifc" ] || continue
        if brctl show br-catch 2>/dev/null | grep -qw "$ifc"; then
            emit "[$(ts)] $ifc already on br-catch"
        else
            brctl addif br-catch "$ifc" 2>/dev/null \
                && emit green "[$(ts)] Bridged $ifc -> br-catch" \
                || emit red "[$(ts)] WARN: could not bridge $ifc"
        fi
    done
}

# ------------------------------ loops ---------------------------------
# Polls open-AP station table: new assoc -> log CONNECT + deauth at once;
# vanished stations -> log DISCONNECT; leases -> HOSTNAME enrichment.
kick_loop() {
    local dump mac sig known disappeared nm hn now
    : > "$SEEN_NONAME" 2>/dev/null
    known=""
    declare -A first_seen=() kicked=()
    while true; do
        now="$(date +%s)"
        dump="$(iw dev "$OPEN_IFACE" station dump 2>/dev/null)"
        # New associations -> log CONNECT (kick happens after DWELL_SECS)
        for mac in $(echo "$dump" | awk '/^Station/{print $2}'); do
            case " $known " in
                *" $mac "*) ;;
                *)
                    known="$known $mac"
                    first_seen[$mac]="$now"
                    sig="$(echo "$dump" | awk -v t="$mac" '$0 ~ "Station "t{found=1; next} found && /signal:/{gsub(/[^0-9-]/,"",$2); print $2; exit}')"
                    [ -z "$sig" ] && sig="?"
                    nm="$(cr_name_for "$mac")"
                    [ "$nm" = "unknown" ] && echo "$mac" >> "$SEEN_NONAME" 2>/dev/null
                    cr_log "CONNECT" "$mac" "${OPEN_SSID_LIVE:-$OPEN_SSID}" "$nm" "$sig" "open:assoc"
                    ;;
            esac
        done
        # Kick after a short dwell so the dummy DHCP (hostname) can complete.
        for mac in $known; do
            [ -n "${kicked[$mac]:-}" ] && continue
            if [ $((now - ${first_seen[$mac]:-$now})) -ge "$DWELL_SECS" ]; then
                hostapd_cli -p /var/run/hostapd -i "$OPEN_IFACE" deauthenticate "$mac" >/dev/null 2>&1
                kicked[$mac]=1
                cr_log "KICK" "$mac" "${OPEN_SSID_LIVE:-$OPEN_SSID}" "" "" "dwell=${DWELL_SECS}s"
            fi
        done
        # Disassociations
        disappeared=""
        for mac in $known; do
            echo "$dump" | grep -qi "Station $mac" || disappeared="$disappeared $mac"
        done
        for mac in $disappeared; do
            known="$(echo "$known" | sed "s/ $mac//")"
            unset "first_seen[$mac]" "kicked[$mac]"
            cr_log "DISCONNECT" "$mac" "${OPEN_SSID_LIVE:-$OPEN_SSID}" "" "" "open:kick"
        done
        # Hostname enrichment for previously-unknown MACs
        if [ -s "$SEEN_NONAME" ]; then
            for mac in $(sort -u "$SEEN_NONAME" 2>/dev/null); do
                hn="$(cr_hostname "$mac")"
                if [ -n "$hn" ] && [ "$hn" != "*" ]; then
                    cr_log "HOSTNAME" "$mac" "" "$hn" "" "dhcp:enrich"
                    sed "/^$mac\$/d" "$SEEN_NONAME" > "$SEEN_NONAME.tmp" 2>/dev/null && mv "$SEEN_NONAME.tmp" "$SEEN_NONAME"
                fi
            done
        fi
        sleep 1
    done
}

# Foreground viewer: streams new log lines to LOG, and raises ONE summary
# ALERT per SUMMARY_SECS window — only when that window had activity.
viewer() {
    local curdate curfile offset total newlines lim summary_at now
    local slice summ
    curdate=""; curfile=""; offset=0
    summary_at="$(date +%s)"
    curdate="$(date +%Y%m%d)"
    curfile="$(cr_logfile)"
    total="$(wc -l < "$curfile" 2>/dev/null || echo 0)"
    offset="$total"
    emit green "[$(ts)] Watching for hits (Ctrl-C to stop). Loot: $LOOTDIR/${curdate}-Catch-and-release.log"
    while true; do
        sleep 5
        # Midnight rollover: filename embeds the date, recompute every tick.
        if [ "$(date +%Y%m%d)" != "$curdate" ]; then
            curdate="$(date +%Y%m%d)"
            curfile="$(cr_logfile)"
            offset=0
            emit yellow "[$(ts)] New daily log: $curfile"
            cr_log "ROLLOVER" "" "" "" "" "new-day"
        fi
        total="$(wc -l < "$curfile" 2>/dev/null || echo 0)"
        if [ "$total" -gt "$offset" ]; then
            newlines=$((total - offset))
            lim="$newlines"; [ "$lim" -gt 12 ] && lim=12
            # Compact: only show hits as  HH:MM:SS  EV  SSID  RSI  MAC
            tail -n +$((offset + 1)) "$curfile" 2>/dev/null | head -n "$lim" \
                | while IFS=$'\t' read -r ts ev mac ssid name rssi note; do
                    case "$ev" in
                        PROBE|AUTH|ASSOC) emit "  ${ts#* }  $ev  $ssid  ${rssi}  $mac" ;;
                    esac
                done
            [ "$newlines" -gt "$lim" ] && emit yellow "  (+$((newlines - lim)) more)"
            offset="$total"
        fi
        now="$(date +%s)"
        if [ $((now - summary_at)) -ge "$SUMMARY_SECS" ]; then
            summary_at="$now"
            slice="$(tail -n 500 "$curfile" 2>/dev/null | awk -v since="$(date -d @$((now - SUMMARY_SECS)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')" '$1" "$2 >= since')"
            if [ -n "$slice" ]; then
                summ="$(echo "$slice" | awk -F'\t' '{h++; if(!seen[$3]++){m++} ss[$4]++} END{top=""; tc=0; for(s in ss){if(ss[s]>tc){tc=ss[s]; top=s}} printf "%d hits / %d devices | top: %s", h, m, top}')"
                emit yellow "[$(ts)] $summ"
                ALERT "Catch-Release: $summ" 2>/dev/null
                LED Y DOUBLE 2>/dev/null
                cr_log "SUMMARY" "" "" "" "" "$summ"
            fi
        fi
    done
}

# ------------------------------ teardown -------------------------------

shutdown() {
    emit yellow ""
    emit yellow "[$(ts)] Stopping Catch-and-Release, restoring Pager state..."
    for p in "$KICK_PID" "$WPA_PID" "$SPOOF_PID" "$FLOOD_PID" "$SNIFF_PID" "$SNIFF2_PID" "$CHAN_PID"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    sleep 1
    for p in "$KICK_PID" "$WPA_PID" "$SPOOF_PID" "$FLOOD_PID" "$SNIFF_PID" "$SNIFF2_PID" "$CHAN_PID"; do
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
    done
    pkill -f 'airbase-ng' 2>/dev/null
    pkill -f 'beacon-flood.py' 2>/dev/null
    pkill -f "bin/sniffer.sh" 2>/dev/null
    pkill -f "tcpdump.*$MON_IFACE" 2>/dev/null
    pkill -f "tcpdump.*$WPA_MON_IFACE" 2>/dev/null
    # Restore PineAP pool/filter/mimic state
    PINEAPPLE_SSID_POOL_STOP >/dev/null 2>&1
    PINEAPPLE_SSID_POOL_CLEAR >/dev/null 2>&1
    if [ -n "$PRIOR_POOL" ]; then
        echo "$PRIOR_POOL" | while IFS= read -r ssid; do
            [ -n "$ssid" ] && PINEAPPLE_SSID_POOL_ADD "$ssid" >/dev/null 2>&1
        done
    fi
    PINEAPPLE_MIMIC_DISABLE >/dev/null 2>&1
    WIFI_OPEN_AP_DISABLE "$OPEN_IFACE" >/dev/null 2>&1
    WIFI_WPA_AP_DISABLE "$WPA_IFACE" >/dev/null 2>&1
    # Restore UCI configs verbatim
    for f in wireless network dhcp firewall pineapd; do
        [ -f "$BAKDIR/$f" ] && cp "$BAKDIR/$f" "/etc/config/$f" 2>/dev/null
    done
    wifi reload >/dev/null 2>&1
    /etc/init.d/network reload >/dev/null 2>&1
    /etc/init.d/firewall reload >/dev/null 2>&1
    sleep 3
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1
    PINEAPPLE_HOPPING_START >/dev/null 2>&1
    if [ -n "$EVIL_SVC" ] && [ "$EVIL_WAS_ON" = "1" ]; then
        "$EVIL_SVC" enable >/dev/null 2>&1
        "$EVIL_SVC" start >/dev/null 2>&1
    fi
    LED OFF 2>/dev/null
    rm -f "$SEEN_NONAME" /tmp/catch-release-essids 2>/dev/null
    emit green "[$(ts)] Restored. Loot kept at $LOOTDIR. Pager radios back to pre-run state."
    exit 0
}

# ------------------------------ main -----------------------------------

emit yellow "[$(ts)] === CATCH-AND-RELEASE (TSCM lure) ==="
emit yellow "  Started: $(ts)"

for bin in tcpdump iw; do
    command -v "$bin" >/dev/null 2>&1 || { emit red "FATAL: $bin not found"; exit 1; }
done
if [ "$WPA_TRANSPORT" = "airbase" ]; then
    command -v airbase-ng >/dev/null 2>&1 || { emit red "FATAL: airbase-ng not found"; exit 1; }
    [ -x "$SPOOFER" ] || chmod +x "$SPOOFER" 2>/dev/null
elif [ "$WPA_TRANSPORT" = "flood" ]; then
    command -v python3 >/dev/null 2>&1 || { emit red "FATAL: python3 not found"; exit 1; }
    [ -f "$SCRIPT_DIR/bin/beacon-flood.py" ] || { emit red "FATAL: beacon-flood.py missing"; exit 1; }
else
    command -v hostapd_cli >/dev/null 2>&1 || { emit red "FATAL: hostapd_cli not found"; exit 1; }
fi
[ -f "$WPA_LIST" ] || { emit red "FATAL: missing $WPA_LIST"; exit 1; }
[ -f "$OPEN_LIST" ] || { emit red "FATAL: missing $OPEN_LIST"; exit 1; }
[ -x "$SNIFFER" ] || chmod +x "$SNIFFER" 2>/dev/null
mkdir -p "$LOOTDIR" 2>/dev/null
cr_log "START" "" "" "" "" "payload launched"
emit green "[$(ts)] bins OK, lists OK, dir=$SCRIPT_DIR, loot=$LOOTDIR"

trap shutdown INT TERM

choose_lures

snapshot
evilportal_off

if [ "$OPEN_ENABLE" = "1" ]; then
    isolate_net
    open_setup
else
    emit "[$(ts)] open lures off"
    PINEAPPLE_MIMIC_DISABLE >/dev/null 2>&1
    PINEAPPLE_SSID_POOL_STOP >/dev/null 2>&1
fi

emit "[$(ts)] stopping channel hop ($MON_IFACE)"
PINEAPPLE_HOPPING_STOP >/dev/null 2>&1
sleep 1

case "$WPA_TRANSPORT" in
    hostapd_multi) wpa_multi_setup ;;
    flood)         wpa_flood_start ;;
    airbase)       wpa_airbase_start ;;
    native)        wpa_setup; ensure_bridge ;;
    *)             emit red "[$(ts)] FATAL: unknown WPA_TRANSPORT=$WPA_TRANSPORT"; shutdown ;;
esac

build_broadcast_set

RETARGET_ARG=""
[ "$ENABLE_RETARGET" = "1" ] && RETARGET_ARG="$RETARGET_FILE"

emit yellow "[$(ts)] Starting probe sniffer on $MON_IFACE..."
"$SNIFFER" "$MON_IFACE" /tmp/catch-release-broadcast.txt /tmp/catch-release-bssid-map.txt "$LOOTDIR" "$RETARGET_ARG" &
SNIFF_PID=$!
emit green "[$(ts)] Sniffer (pid $SNIFF_PID) running (retarget=$ENABLE_RETARGET)."

if printf '%s\n' $WPA_SLOTS | grep -qw wlan1ap && [ "$WPA_TRANSPORT" != "airbase" ]; then
    "$SNIFFER" "$WPA_MON_IFACE" /tmp/catch-release-broadcast.txt /tmp/catch-release-bssid-map.txt "$LOOTDIR" "$RETARGET_ARG" &
    SNIFF2_PID=$!
    emit green "[$(ts)] 5GHz sniffer (pid $SNIFF2_PID) on $WPA_MON_IFACE."
fi

if [ "$OPEN_ENABLE" = "1" ]; then
    kick_loop &
    KICK_PID=$!
    emit green "[$(ts)] Kick loop running (pid $KICK_PID). Lure net is DHCP-only, no gateway."
fi

viewer
