#!/bin/sh
# awdl_wake.sh - AWDL wake rig (start/stop), supervised.
#   owl=AWDL peer | avahi=AirPlay2 advert | awdl_log=observer | awdl_alert=alerts
#   awdl_supervisor.sh keeps all four alive (restarts any that die).
#   sh awdl_wake.sh [wifi_iface] [channel] [alerts yes|no]
#   sh awdl_wake.sh stop
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SUP="$DIR/awdl_supervisor.sh"
WIFI_DEFAULT=wlan0mon
CH_DEFAULT=6

stop_all() {
  for p in $(ps w | grep -E '[a]wdl_supervisor.sh|[o]wl -i|[a]wdl_log.py|[a]wdl_alert.sh' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
  killall avahi-daemon 2>/dev/null
  ip link delete awdl0 2>/dev/null
  echo "[*] stopped owl + avahi + logger + alerts + supervisor, removed awdl0"
}

if [ "${1:-}" = "stop" ]; then stop_all; exit 0; fi

WIFI="${1:-$WIFI_DEFAULT}"
CH="${2:-$CH_DEFAULT}"
ALERTS="${3:-yes}"

stop_all; sleep 1
[ -e /etc/avahi ] || ln -sfn /mmc/etc/avahi /etc/avahi

echo "[*] starting supervisor (owl + avahi + observer + alerts=$ALERTS) on $WIFI ch$CH"
: > /tmp/awdl_supervisor.log
setsid sh "$SUP" "$WIFI" "$CH" "$ALERTS" > /tmp/awdl_supervisor.out 2>&1 &
for i in $(seq 1 15); do ip -6 addr show dev awdl0 >/dev/null 2>&1 && break; sleep 1; done
echo "    awdl0: $(ip -6 addr show dev awdl0 2>/dev/null | grep inet6 | awk '{print $2}')"
sleep 2
echo "[*] running: owl=$(ps w | grep -c '[o]wl -i') avahi=$(ps w | grep -c '[a]vahi-daemon') logger=$(ps w | grep -c '[a]wdl_log.py') alerts=$(ps w | grep -c '[a]wdl_alert.sh') sup=$(ps w | grep -c '[a]wdl_supervisor.sh')"
echo "    watch : tail -f /tmp/owl.log | grep -E 'add peer|receive (PSF|MIF)'"
echo "    loot  : tail -f /root/loot/awdl/*-awdl.log"
echo "    sup   : tail -f /tmp/awdl_supervisor.log"
echo "    stop  : sh $DIR/awdl_wake.sh stop"
