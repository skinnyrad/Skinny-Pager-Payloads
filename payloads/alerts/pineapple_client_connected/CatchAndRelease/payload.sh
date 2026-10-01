#!/bin/bash
## Title: CatchAndRelease
## Description: Alert + log fired when a device connects to the Pager's
##              PineAP karma/mimicry AP (pineapple_client_connected event).
##              Records WHICH bait SSID enticed the device to connect, plus
##              the client MAC and resolved hostname, and shows a simple
##              on-screen alert. Connect-only (no disconnect handling).
## Author: Skinny Research & Development
## Version: 1.0
##
## Trigger: this is an ALERT payload. The Pager's pineapd launches it when a
##          client associates to the PineAP/karma AP. It is discovered under
##          /root/payloads/alerts/pineapple_client_connected/. Alert payloads
##          interrupt the user, so this stays minimal and uses ONLY the ALERT
##          helper (dialogs/pickers are not available in the alert context).
##
## Alert environment (provided by pineapd):
##   $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS  client mac
##   $_ALERT_CLIENT_CONNECTED_SSID                utf-8 sanitized bait ssid
##   $_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS      ap/bssid (optional)
##   $_ALERT_CLIENT_CONNECTED_SUMMARY             human-readable summary
##
## Loot:
##   /root/loot/catch-and-release/YYYYMMDD-catch-and-release.log
##     TSV: TS  CONNECT  MAC  SSID  NAME  RSSI  NOTE
##     (RSSI is blank - not provided by the client-connected event)
##
## This payload is a PURE LISTENER. It never starts/stops radios, the SSID
## pool, or PineAP mimic - OpenAP/PineAP is controlled by the operator through
## the Pager UI as intended. This alert only observes and records the
## pineapple_client_connected event. Enable/disable it in the Pager's Alerts
## UI (the native mechanism renames the dir to DISABLED.CatchAndRelease).

# Native alert launch context is minimal; make sure the standard bins we use
# (date/awk/mkdir/flock/cut/sed/tr/whoismac/ALERT) resolve regardless.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Alert env can be unset if invoked manually; default to safe placeholders.
MAC="${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-unknown}"
SSID="${_ALERT_CLIENT_CONNECTED_SSID:-<none>}"
AP="${_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS:-}"

LOOTDIR="/root/loot/catch-and-release"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# logfile: date-stamped so it rolls over at midnight; recomputed per event.
logfile() { date +"$LOOTDIR/%Y%m%d-catch-and-release.log"; }

# hostname_for <mac>: MAC -> hostname from dnsmasq leases, else OUI vendor,
# else empty. Mirrors the PNL-Beacon-Lure enrichment: hostname first, then a
# whoismac vendor lookup. Returns "" when nothing is known.
hostname_for() {
    local mac hn vn oui
    mac="$1"
    [ -n "$mac" ] || return 0
    hn="$(awk -v m="$mac" 'tolower($2)==tolower(m){print $4; exit}' /tmp/dhcp.leases 2>/dev/null)"
    if [ -n "$hn" ] && [ "$hn" != "*" ]; then
        printf '%s' "$hn"
        return 0
    fi
    # OUI vendor lookup: prefer the Pager's bundled /lib/hak5/oui.txt, then
    # fall back to whoismac (which needs a downloaded oui.txt).
    oui="$(printf '%s' "$mac" | tr 'A-F' 'a-f' | cut -d: -f1-3)"
    if [ -r /lib/hak5/oui.txt ]; then
        vn="$(awk -F'\t' -v o="$oui" 'tolower($1)==o {print $2; exit}' /lib/hak5/oui.txt 2>/dev/null)"
        [ -n "$vn" ] && { printf '%s' "$vn"; return 0; }
    fi
    if command -v whoismac >/dev/null 2>&1; then
        vn="$(whoismac -m "$mac" 2>/dev/null \
            | grep -viE 'failed|download|oui\.txt|^[[:space:]]*$|^use ' \
            | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$vn" ] && { printf '%s' "$vn"; return 0; }
    fi
    return 0
}

# record <mac> <ssid> <name> <ap>: append one guarded TSV row. Uses flock when
# available so concurrent alert invocations cannot interleave partial lines,
# with an unguarded append as the fallback.
record() {
    local mac ssid name ap f
    mac="$1"; ssid="$2"; name="$3"; ap="$4"
    f="$(logfile)"
    mkdir -p "$LOOTDIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        flock -x "$LOOTDIR/.lock" -c "printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \"$(ts)\" CONNECT \"$mac\" \"$ssid\" \"$name\" \"\" \"ap=$ap\" >> \"$f\"" 2>/dev/null \
        || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" CONNECT "$mac" "$ssid" "$name" "" "ap=$ap" >> "$f" 2>/dev/null
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" CONNECT "$mac" "$ssid" "$name" "" "ap=$ap" >> "$f" 2>/dev/null
    fi
}

NAME="$(hostname_for "$MAC")"
[ -n "$NAME" ] || NAME="unknown"

record "$MAC" "$SSID" "$NAME" "$AP"

# Simple on-screen alert: which bait enticed this device. ALERT is the only
# UI helper safe in the alert context (no dialogs/pickers).
ALERT "Catch-and-Release\n\n Host: $NAME\n MAC:  $MAC\n SSID: $SSID"

exit 0
