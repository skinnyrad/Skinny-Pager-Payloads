#!/bin/bash
## Title: CatchAndRelease
## Description: Alert when a device connects to the Pager's PineAP/OpenAP.
##              Resolves the device's real name (mDNS display name ->
##              DHCP hostname -> OUI vendor -> random/unknown) and manufacturer,
##              plus MAC and the bait SSID it connected to; appends a line to
##              loot. Shows a simple on-screen ALERT.
## Author: Skinny Research & Development
## Version: 2.7
##
## Trigger: this is an ALERT payload. The Pager's pineapd launches it when a
##          client associates to the PineAP/OpenAP (pineapple_client_connected
##          event). Discovered under
##          /root/payloads/alerts/pineapple_client_connected/.
##
## Alert environment (provided by pineapd):
##   $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS  client mac
##   $_ALERT_CLIENT_CONNECTED_SSID                bait ssid it connected to
##   $_ALERT_CLIENT_CONNECTED_SSID_LENGTH         ssid length
##   $_ALERT_CLIENT_CONNECTED_SUMMARY             human-readable summary
##
## On-screen alert:
##   Dev Name: <real name, best effort>
##   MAC(R):   <mac, (R) when the MAC is randomized/locally administered>
##   SSID:     <bait ssid>
##   man:      <manufacturer>
##
## Loot:
##   /root/loot/catch-and-release/YYYYMMDD-catch-and-release.log
##     TS | NAME | MAC | SSID | IP
##
## Name resolution order:
##   1. mDNS (umdns) by client IP/MAC - the real advertised device name.
##   2. dnsmasq lease hostname.  3. OUI vendor.  4. random/unknown.
## Manufacturer: OUI vendor; for randomized MACs where that fails, Apple via
## mDNS, then a lockdownd (TCP 62078) probe as an "iPhone" hint.
## Requires the optional `umdns` package for mDNS; without it the payload still
## works via the DHCP/vendor fallbacks.
##
## The mDNS JSON parser is embedded (no external file) because pineapd launches
## alert payloads from a temp wrapper, so $0/dirname is unreliable.
##
## The Pager's own interface MACs are read at runtime; if one shows up as a
## client it is logged as "Pager(self)" and no alert is raised.
##
## This payload is a PURE LISTENER. It never starts/stops radios, the SSID
## pool, or PineAP - OpenAP/PineAP is controlled by the operator through the
## Pager UI as intended. Enable/disable it in the Pager's Alerts UI (the native
## mechanism renames the dir to DISABLED.CatchAndRelease).

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Alert env can be unset if invoked manually; default to safe placeholders.
MAC="${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-unknown}"
SSID="${_ALERT_CLIENT_CONNECTED_SSID:-<none>}"

LOOTDIR="/root/loot/catch-and-release"

# Strip pipe/tab/CR/LF so the single log line cannot be broken by odd input.
san() { printf '%s' "$1" | tr -d '|\t\r\n'; }

# lease_field <mac> <n>: nth field of the dnsmasq lease row for <mac>
# (3 = IP, 4 = hostname). Empty when there is no lease yet.
lease_field() {
    awk -v m="$1" -v n="$2" 'tolower($2)==tolower(m){print $n; exit}' /tmp/dhcp.leases 2>/dev/null
}

# lease_ip <mac>: poll up to ~10s for the DHCP lease, print its IP.
lease_ip() {
    local mac="$1" ip i=0
    while [ "$i" -lt 10 ]; do
        ip="$(lease_field "$mac" 3)"
        [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
        sleep 1
        i=$((i+1))
    done
}

# vendor_for <mac>: OUI vendor. The bundled oui.txt mislabels Hak5's own OUI
# (00:13:37) as "Orient Power Home Network Ltd.", so special-case it.
vendor_for() {
    local oui
    oui="$(printf '%s' "$1" | tr 'A-F' 'a-f' | cut -d: -f1-3)"
    [ "$oui" = "00:13:37" ] && { printf 'Hak5'; return 0; }
    [ -r /lib/hak5/oui.txt ] || return 0
    awk -F'\t' -v o="$oui" 'tolower($1)==o {print $2; exit}' /lib/hak5/oui.txt 2>/dev/null
}

# is_random_mac <mac>: true when the locally-administered bit is set.
is_random_mac() {
    local b
    b="$(printf '%s' "$1" | cut -d: -f1)"
    case "$b" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *) return 1 ;;
    esac
    b=$((0x$b))
    [ $((b & 2)) -ne 0 ]
}

# port_open <ip> <port>: true when a TCP connect succeeds.
port_open() {
    local ip="$1" p="$2"
    [ -n "$ip" ] && [ "$ip" != "-" ] || return 1
    [ -n "$p" ] || return 1
    command -v nc >/dev/null 2>&1 || return 1
    timeout 4 nc -w 2 "$ip" "$p" </dev/null >/dev/null 2>&1
}

# mdns_try <ip> <mac-lowercase>: one umdns browse + resolve pass. The embedded
# awk picks the best name for the client: _companion-link instance (real display
# name, e.g. "Jeff’s MacBook Pro"), then _airplay/_raop instance, then the
# _apple-mobdev2 host (e.g. "Android-2"), then any host. It also matches by the
# client MAC embedded in _apple-mobdev2 instances (iPhones/iPads).
mdns_try() {
    timeout 4 ubus call umdns browse 2>/dev/null | awk -v target="$1" -v targetmac="$2" '
    BEGIN { best = ""; bestscore = 99; macmatch = 0; macname = "" }
    /\._(tcp|udp)": \{$/ {
        svc = $0; sub(/^[ \t]*"/, "", svc); sub(/": \{ *$/, "", svc)
        inst = ""; host = ""; macmatch = 0; next
    }
    /": \{$/ {
        inst = $0; sub(/^[ \t]*"/, "", inst); sub(/": \{ *$/, "", inst)
        host = ""; macmatch = 0
        if (svc == "_apple-mobdev2._tcp" && targetmac != "" \
            && index(tolower(inst), targetmac) == 1) macmatch = 1
        next
    }
    /"host":[ \t]*"/ {
        host = $0; sub(/^.*"host":[ \t]*"/, "", host); sub(/".*$/, "", host)
        sub(/\.local\.?$/, "", host)
        if (macmatch && macname == "" && host != "") macname = host
        next
    }
    /"ipv4":[ \t]*"/ {
        ip = $0; sub(/^.*"ipv4":[ \t]*"/, "", ip); sub(/".*$/, "", ip)
        if (target == "" || ip != target) next
        if (svc == "_companion-link._tcp") { name = inst; score = 1 }
        else if (svc == "_airplay._tcp" || svc == "_raop._tcp") {
            name = inst; sub(/^[0-9A-Fa-f]+@/, "", name); score = 2
        }
        else if (svc == "_apple-mobdev2._tcp") { name = host; score = 3 }
        else { name = host; score = 4 }
        if (name == "") { name = host; score = 4 }
        if (name == "") { name = inst; score = 4 }
        if (score < bestscore && name != "") { bestscore = score; best = name }
    }
    END { if (best != "") print best; else print macname }
    '
}

# mdns_best <ip> <mac-lowercase> <tries>: best mDNS name, or "". Checks the warm
# umdns cache first, then forces up to <tries> queries (0 = cache only, used as
# an instant check). Requires the optional umdns package.
mdns_best() {
    local ip="$1" maclc="$2" tries="${3:-0}" out i=0
    [ -n "$ip" ] || [ -n "$maclc" ] || return 0
    [ -x /usr/sbin/umdns ] || return 0
    command -v ubus >/dev/null 2>&1 || return 0
    ubus list 2>/dev/null | grep -q '^umdns$' || /etc/init.d/umdns start >/dev/null 2>&1

    out="$(mdns_try "$ip" "$maclc")"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }

    while [ "$i" -lt "$tries" ]; do
        timeout 3 ubus call umdns update >/dev/null 2>&1
        sleep 1
        out="$(mdns_try "$ip" "$maclc")"
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        i=$((i+1))
    done
}

# This Pager's own interface MACs (lowercase), used to skip self-catches.
SELF_MACS=""
for _f in /sys/class/net/*/address; do
    _a="$(cat "$_f" 2>/dev/null | tr 'A-F' 'a-f')"
    [ -n "$_a" ] && [ "$_a" != "00:00:00:00:00:00" ] && SELF_MACS="$SELF_MACS $_a"
done
is_self_mac() {
    local m
    m="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    case " $SELF_MACS " in *" $m "*) return 0 ;; esac
    return 1
}

MAC="$(san "$MAC")"
SSID="$(san "$SSID")"

# The Pager's own interfaces must never be reported as a caught client: log a
# self entry and do not raise an alert.
if is_self_mac "$MAC"; then
    IP="$(san "$(lease_field "$MAC" 3)")"; [ -n "$IP" ] || IP="-"
    mkdir -p "$LOOTDIR" 2>/dev/null
    printf '%s | %s | %s | %s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "Pager(self)" "$MAC" "$SSID" "$IP" \
        >> "$(date +"$LOOTDIR/%Y%m%d-catch-and-release.log")" 2>/dev/null
    exit 0
fi

MACLC="$(printf '%s' "$MAC" | tr 'A-F' 'a-f')"
IP="$(san "$(lease_ip "$MAC")")"
[ -n "$IP" ] || IP="-"

# --- Name (best effort) ---
# Instant mDNS cache check always; if that misses and there is no DHCP hostname
# (typical for iPhones with a randomized MAC), wait up to ~20s for the device to
# advertise. Devices that already have a DHCP name skip the long wait.
DH="$(lease_field "$MAC" 4)"
[ "$DH" = "*" ] && DH=""

NAME_SRC=""
NAME="$(mdns_best "$IP" "$MACLC" 0)"
[ -n "$NAME" ] && NAME_SRC="mdns"
if [ -z "$NAME" ] && [ -z "$DH" ]; then
    NAME="$(mdns_best "$IP" "$MACLC" 20)"
    [ -n "$NAME" ] && NAME_SRC="mdns"
fi
if [ -z "$NAME" ] && [ -n "$DH" ]; then
    NAME="$DH"; NAME_SRC="dhcp"
fi
[ -n "$NAME" ] || NAME="$(vendor_for "$MAC")"
if [ -z "$NAME" ]; then
    if is_random_mac "$MAC"; then NAME="random MAC"; else NAME="unknown"; fi
fi
NAME="$(san "$NAME")"
[ -n "$NAME" ] || NAME="unknown"

# --- Manufacturer (best effort) ---
MAN="$(vendor_for "$MAC")"
if [ -z "$MAN" ] && [ "$NAME_SRC" = "mdns" ]; then MAN="Apple"; fi
if [ -z "$MAN" ] && port_open "$IP" 62078; then MAN="iPhone"; fi
MAN="$(san "$MAN")"
[ -n "$MAN" ] || MAN="Unknown"

# --- MAC label: flag randomized (locally-administered) MACs ---
if is_random_mac "$MAC"; then MACLABEL="MAC(R)"; else MACLABEL="MAC"; fi

mkdir -p "$LOOTDIR" 2>/dev/null
printf '%s | %s | %s | %s | %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$NAME" "$MAC" "$SSID" "$IP" \
    >> "$(date +"$LOOTDIR/%Y%m%d-catch-and-release.log")" 2>/dev/null

# Simple on-screen alert: name, MAC (flagged if randomized), bait SSID, vendor.
ALERT "New device\n\n Dev Name: $NAME\n $MACLABEL: $MAC\n SSID: $SSID\n man: $MAN"

exit 0
