#!/bin/sh
# Title: AWDL Stim
# Description: Wake nearby Apple AWDL (owl + avahi AirPlay beacon + observer).
#   Detects external USB Wi-Fi radios and, if present, uses one (keeps the Pager's
#   own phy0 Wi-Fi untouched). Internal radio only if you explicitly choose it.
#   Run again to STOP.
# Author: Skinny
# Version: 2.3
# NOTE: when launched from the Pager UI, payload.sh is staged as
# /tmp/payload-<rand>.sh, so $0/dirname $0 point at /tmp -- NOT this payload.
# The framework passes the real folder in _PAYLOAD_HOME (and PAYLOAD_HOME);
# fall back to $0 only for direct CLI runs.
DIR="${_PAYLOAD_HOME:-${PAYLOAD_HOME:-$(cd "$(dirname "$0")" && pwd)}}"
DIR="${DIR%/}"
STATE=/tmp/awdl_stim.state

# ---------------- STOP ----------------
# Toggle is based on the rig actually running (not a stale state file).
if ps w | grep -q '[o]wl -i'; then
  echo "Stopping AWDL Stim..."
  sh "$DIR/awdl_wake.sh" stop >/dev/null 2>&1
  MODE=""; CREATED_IFACE=""; PINAPD_DISABLED=""
  [ -f "$STATE" ] && . "$STATE"
  [ -n "$CREATED_IFACE" ] && iw dev "$CREATED_IFACE" del 2>/dev/null
  if [ -n "$PINAPD_DISABLED" ]; then
    uci set pineapd.$PINAPD_DISABLED.disable='0' 2>/dev/null
    uci commit pineapd 2>/dev/null
    /etc/init.d/pineapd restart >/dev/null 2>&1
  fi
  rm -f "$STATE"
  echo "AWDL Stim: STOPPED."
  exit 0
fi

# ---------------- START ----------------
rm -f "$STATE" 2>/dev/null   # clear any stale state so START always starts
# USB scan: external Wi-Fi radios = USB phys other than the built-in phy0
EXTS=""
for p in /sys/class/ieee80211/*; do
  phy=$(basename "$p"); [ "$phy" = "phy0" ] && continue
  case "$(readlink -f "$p/device" 2>/dev/null)" in *usb*) EXTS="$EXTS $phy";; esac
done
EXT_PHY=$(echo $EXTS | awk '{print $1}')

dialog() { command -v CONFIRMATION_DIALOG >/dev/null 2>&1; }
denied() { [ -n "${DUCKYSCRIPT_USER_DENIED:-}" ] && [ "$1" = "$DUCKYSCRIPT_USER_DENIED" ]; }

CHOICE=""
if [ -n "$EXT_PHY" ]; then
  # default = external; only switch if the user actually answers "No"
  CHOICE="external"
  if dialog; then
    r=$(CONFIRMATION_DIALOG "External Wi-Fi radio detected ($EXT_PHY).

Use the external radio?

Yes = external
No = internal")
    denied "$r" && CHOICE="internal"
  fi
else
  # no external: internal is the only option; confirm (default yes)
  CHOICE="internal"
  if dialog; then
    r=$(CONFIRMATION_DIALOG "No external radio found.

Use the internal radio?

Yes = internal
No = cancel")
    denied "$r" && { echo "Cancelled."; exit 0; }
  fi
fi

# Ask whether to raise a UI alert for each new device (log-only otherwise).
ALERTS="yes"
if dialog; then
  r=$(CONFIRMATION_DIALOG "Do you want alerts?

Yes = pop an alert for each new AWDL device
No = log only (no pop-ups)")
  denied "$r" && ALERTS="no"
fi

CREATED_IFACE=""; PINAPD_DISABLED=""
if [ "$CHOICE" = "external" ]; then
  echo "Using external radio $EXT_PHY (Pager Wi-Fi untouched)..."
  iw dev awdlmon del 2>/dev/null
  iw phy "$EXT_PHY" interface add awdlmon type monitor 2>/dev/null
  ip link set awdlmon up 2>/dev/null
  IFACE="awdlmon"; CREATED_IFACE="awdlmon"; MODE="external"
  # if pineapd owns this phy's stock monitor vif, pause it (restored on stop)
  for m in wlan1mon wlan2mon; do
    mp=$(readlink -f /sys/class/net/$m/phy80211 2>/dev/null | xargs basename 2>/dev/null)
    [ "$mp" = "$EXT_PHY" ] || continue
    if uci get pineapd.$m.device >/dev/null 2>&1; then
      uci set pineapd.$m.disable='1' 2>/dev/null; uci commit pineapd 2>/dev/null
      PINAPD_DISABLED="$m"; /etc/init.d/pineapd restart >/dev/null 2>&1; sleep 1
    fi
  done
else
  echo "Using internal radio (wlan0mon=phy0); not touching Pager Wi-Fi..."
  [ -e /sys/class/net/wlan0mon ] || iw phy phy0 interface add wlan0mon type monitor 2>/dev/null
  ip link set wlan0mon up 2>/dev/null
  IFACE="wlan0mon"; MODE="internal"
fi

echo "Starting AWDL Stim on $IFACE ($MODE)..."
sh "$DIR/awdl_wake.sh" "$IFACE" 6 "$ALERTS"

cat > "$STATE" <<EOF
MODE=$MODE
IFACE=$IFACE
ALERTS=$ALERTS
CREATED_IFACE=$CREATED_IFACE
PINAPD_DISABLED=$PINAPD_DISABLED
EOF
echo "AWDL Stim: RUNNING on $IFACE ($MODE, alerts=$ALERTS)."
