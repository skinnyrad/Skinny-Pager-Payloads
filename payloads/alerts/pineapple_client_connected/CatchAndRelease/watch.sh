#!/bin/bash
# watch.sh - CatchAndRelease reconnect watcher.
#
# The Pager only raises the "new client" alert the FIRST time a MAC connects,
# so the alert payload can't kick a client that reconnects. This watcher polls
# the OpenAP for newly-appeared stations and, when Auto-Kick is enabled, re-
# "releases" (block + deauth) any MAC that is already in today's catch log.
#
# Started on demand by the CatchAndRelease alert payload; safe to leave running
# (it idles when Auto-Kick is disabled). Stop with: pkill -f CatchAndRelease/watch.sh

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

DIR="/root/payloads/alerts/pineapple_client_connected/CatchAndRelease"
AUTOKICK="/root/payloads/alerts/pineapple_client_connected/Auto-Kick"
LOGDIR="/root/loot/catch-and-release"

prev=""
while :; do
    if [ -d "$AUTOKICK" ]; then
        cur="$(timeout 3 iw dev wlan0open station dump 2>/dev/null | awk '/^Station/{print $2}')"
        for m in $cur; do
            case " $prev " in
                *" $m "*) continue ;;   # already known
            esac
            log="$LOGDIR/$(date +%Y%m%d)-catch-and-release.log"
            if grep -qi "$m" "$log" 2>/dev/null; then
                # Already caught today -> re-release it.
                "$DIR/release.sh" "$m" 15 >/dev/null 2>&1
                printf '%s | %s | %s | %s | %s\n' \
                    "$(date '+%Y-%m-%d %H:%M:%S')" "KICKED" "$m" "(reconnect)" "-" \
                    >> "$log" 2>/dev/null
            fi
        done
        prev="$cur"
    else
        prev=""
    fi
    sleep 1
done
