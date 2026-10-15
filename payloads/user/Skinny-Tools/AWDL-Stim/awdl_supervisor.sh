#!/bin/sh
# awdl_supervisor.sh - keep the AWDL-Stim components alive and log restarts.
#   usage: awdl_supervisor.sh <owl_iface> <channel> [alerts yes|no]
# Started (detached) by awdl_wake.sh. Killed by awdl_wake.sh stop.
DIR="$(cd "$(dirname "$0")" && pwd)"
IFACE="$1"; CH="${2:-6}"; ALERTS="${3:-yes}"
LOG=/tmp/awdl_supervisor.log
PYLIB=/mmc/scapy/usr/lib/python3.11/site-packages
say() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

echo "[*] supervisor started ($(date +%H:%M:%S)) iface=$IFACE ch=$CH alerts=$ALERTS" >> "$LOG"
while :; do
  if ! ps w | grep -q '[o]wl -i'; then
    say "owl DOWN -> restart on $IFACE"
    ip link delete awdl0 2>/dev/null
    setsid "$DIR/owl" -i "$IFACE" -c "$CH" -N -v -v -v > /tmp/owl.log 2>&1 &
    sleep 3
  fi
  if ! ps w | grep -q '[a]vahi-daemon'; then
    say "avahi DOWN -> restart"
    LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib /mmc/usr/sbin/avahi-daemon -D 2>/dev/null
  fi
  if ! ps w | grep -q '[a]wdl_log.py'; then
    say "logger DOWN -> restart"
    PYTHONPATH="$PYLIB" setsid python3 "$DIR/awdl_log.py" awdl0 /tmp/owl.log > /tmp/awdl_log.out 2>&1 &
  fi
  if [ "$ALERTS" = "yes" ]; then
    if ! ps w | grep -q '[a]wdl_alert.sh'; then
      say "alerts DOWN -> restart"
      setsid sh "$DIR/awdl_alert.sh" > /tmp/awdl_alert.out 2>&1 &
    fi
  fi
  sleep 4
done
