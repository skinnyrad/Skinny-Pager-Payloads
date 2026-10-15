#!/bin/sh
# awdl_alert.sh - raise a Pager ALERT for EVERY new line the Stim logger writes
# (i.e. each time traffic is seen; the logger re-logs an active device every
# COOLDOWN seconds). Only lines appended after this watcher starts are used.
# No PineAP.
#
#   Stim writes : /root/loot/awdl/YYYYMMDD-awdl.log
#   This writes : /root/loot/awdl-alerts/YYYYMMDD-awdl-alerts.log
#   Popup       : ALERT "..."  (hak5cmd -> /tmp/api.sock)
DELAY="${1:-1}"
STIM_LOOT=/root/loot/awdl
ALOOT=/root/loot/awdl-alerts
OFF=/tmp/awdl_alert_off

mkdir -p "$ALOOT"
rm -rf "$OFF"; mkdir -p "$OFF"
# baseline line counts so pre-existing history is ignored
for f in "$STIM_LOOT"/*-awdl.log; do
  [ -f "$f" ] && wc -l < "$f" > "$OFF/$(basename "$f")"
done

while :; do
  LOG="$ALOOT/$(date +%Y%m%d)-awdl-alerts.log"
  for f in "$STIM_LOOT"/*-awdl.log; do
    [ -f "$f" ] || continue
    base=$(cat "$OFF/$(basename "$f")" 2>/dev/null || echo 0)
    cur=$(wc -l < "$f")
    if [ "$cur" -gt "$base" ]; then
      sed -n "$((base + 1)),${cur}p" "$f" | while IFS= read -r line; do
        macf=$(printf '%s' "$line" | awk -F' \\| ' '{print $3}')
        [ -z "$macf" ] && continue
        name=$(printf '%s' "$line" | awk -F' \\| ' '{print $2}')
        ipv6=$(printf '%s' "$line" | awk -F' \\| ' '{print $4}')
        rssi=$(printf '%s' "$line" | awk -F' \\| ' '{print $5}')
        svc=$(printf '%s' "$line" | awk -F' \\| ' '{print $6}')
        txt=$(printf '%s' "$line" | awk -F' \\| ' '{print $7}')
        ts=$(printf '%s' "$line" | awk -F' \\| ' '{print $1}')
        printf '%s | %s | %s | %s | %s | %s | %s\n' \
          "$ts" "$name" "$macf" "$ipv6" "$rssi" "$svc" "$txt" >> "$LOG"
        # include a hostname line only when the logger resolved a real name
        case "$name" in
          ""|"-"|"unknown"|"random MAC") host="";;
          *) host="
 Host: $name";;
        esac
        ALERT "AWDL - Apple Device
 $ts

 MAC: $macf
 IPv6: $ipv6
 RSSI: $rssi dBm$host"
        sleep "$DELAY"
      done
    fi
    echo "$cur" > "$OFF/$(basename "$f")"
  done
  sleep 2
done
