#!/usr/bin/env bash
# =============================================================================
# provision-pagers.sh
#
# Batch-provision WiFi Pineapple Pagers over USB-C Ethernet from a macOS host.
#
# For each Pager:
#   1. SSH to root@172.16.52.1 (USB-C br-lan, DHCP from the Pager).
#   2. Push this repository to /mmc/root/Skinny-Pager-Payloads/ (merge, never
#      wipe an existing tree).
#   3. Configure the Pager's 2.4 GHz WiFi client mode (wlan0cli) for the SSID
#      and password supplied at startup.
#   4. Wait for a DHCP lease, a default route, and the same ICMP WAN check
#      online-install.sh performs (ping 8.8.8.8).
#   5. Launch online-install.sh with --select <S|H|B|C> detached via
#      setsid, with stdin from /dev/null and stdout/stderr to a
#      persistent log under /mmc/root/skinny-install-logs/.
#   6. Verify the installer is alive, detached, writing to the log, and past
#      its WAN check. Only then tell you it is safe to unplug the Pager.
#
# The Pager is never powered off, rebooted, or factory reset by this script.
# /mmc/root/payloads is never touched directly; online-install.sh's own
# no-clobber/no-delete merge handles pre-existing payloads.
#
# The very first question is "Completion check? [y/N]" (default NO). Yes
# enters a verification mode that checks the 9 Pager Class payloads, the
# class dependencies, PAGERCTL, and the installer log's success marker on
# each plugged-in Pager. A PASS issues the Pager's safe shutdown
# (/sbin/halt-power) so it is visibly ready to box; a FAIL leaves it on.
# It pauses after every report so you can swap units. No/blank proceeds to
# batch provisioning.
#
# Firmware updates are CHECK-ONLY. When (and only when) you explicitly answer
# "yes" to the firmware question, the Mac fetches the latest stable version
# from Hak5 once and compares it to /etc/pineapplepager/version on each Pager.
# Nothing is downloaded, pushed, or installed. Blank/no means no Hak5
# firmware endpoint is contacted at all.
#
# Author: Skinny Research & Development
# =============================================================================

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Defaults / paths
# ---------------------------------------------------------------------------
PAGER_HOST="${PAGER_HOST:-172.16.52.1}"
PAGER_USER="${PAGER_USER:-root}"
PAGER_PASSWORD="${PAGER_PASSWORD:-password}"
PAGER_SSH_PORT="${PAGER_SSH_PORT:-22}"
WIFI_SECURITY="${WIFI_SECURITY:-psk2}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DEST="/mmc/root/Skinny-Pager-Payloads"
FW_API="https://downloads.hak5.org/api/latest/firmwares"

STATE_DIR="${SKINNY_PAGER_STATE_DIR:-$HOME/.skinny-pager-provision}"
STATE_FILE="$STATE_DIR/state.tsv"
COMPLETION_STATE_FILE="$STATE_DIR/completion.tsv"
LATEST_FW_FILE="$STATE_DIR/latest-firmware.txt"

MODE="provision"
STATUS_CHECK_FW=0
DRY_RUN=0
FORCE=0
LAST_MAC=""
COMPLETION_MODE=0
LAST_CHECK_MAC=""

SSID=""
PSK=""
SELECTION=""
CHECK_FW=0
LATEST_FW=""
LATEST_FW_RAW=""

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skinny-pager-provision.XXXXXX")" || {
  echo "[-] Could not create a temporary directory." >&2
  exit 1
}

cleanup() {
  stty echo 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Discard extra Enter presses buffered while the previous Pager was being
# provisioned, so the next prompt cannot be skipped accidentally.
drain_stdin() {
  while IFS= read -r -t 1 _junk; do :; done 2>/dev/null || true
}

now_id() { date '+%Y%m%d-%H%M%S'; }

# Normalize a version string to its numeric dot components.
ver_norm() {
  printf '%s' "$1" | sed 's/[^0-9.].*$//'
}

# ver_gt A B -> true when A is strictly newer than B.
ver_gt() {
  local a b c x y z
  IFS=. read -r a b c <<< "$(ver_norm "$1")"
  IFS=. read -r x y z <<< "$(ver_norm "$2")"
  a=${a:-0}; b=${b:-0}; c=${c:-0}
  x=${x:-0}; y=${y:-0}; z=${z:-0}
  if [ "$a" -ne "$x" ]; then [ "$a" -gt "$x" ]; return; fi
  if [ "$b" -ne "$y" ]; then [ "$b" -gt "$y" ]; return; fi
  [ "$c" -gt "$z" ]
}

# shq: single-quote a value for POSIX sh (used only for safe identifiers;
# SSID/PSK travel base64-encoded).
shq() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# ---------------------------------------------------------------------------
# SSH plumbing
# ---------------------------------------------------------------------------
ssh_to() {
  local host="$1"
  shift
  sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -p "$PAGER_SSH_PORT" \
    "$PAGER_USER@$host" "$@"
}

ssh_pager() {
  ssh_to "$PAGER_HOST" "$@"
}

pager_reachable() {
  nc -z -G 2 -w 2 "$PAGER_HOST" "$PAGER_SSH_PORT" >/dev/null 2>&1
}

wait_for_pager() {
  local limit="${1:-60}" i=0
  while [ "$i" -lt "$limit" ]; do
    if pager_reachable; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

ask_retry_skip_quit() {
  local a
  while true; do
    printf '  [r]etry this Pager / [s]kip / [q]uit: '
    IFS= read -r a || return 2
    case "$a" in
      r|R) return 0 ;;
      s|S) return 1 ;;
      q|Q) return 2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Repository push (merge; never delete the destination)
# ---------------------------------------------------------------------------
tar_create_repo() {
  local out="$1"
  COPYFILE_DISABLE=1 tar -czf "$out" -C "$REPO_DIR" \
    --exclude='.DS_Store' \
    --exclude='._*' \
    --exclude='payloads/user/Skinny-Tools/att/knowledge' \
    --exclude='payloads/user/Skinny-Tools/ATT/knowledge' \
    online-install.sh payloads cross-compiled-pager-tools \
    pagerctl.py libpagerctl.so README.md
}

push_repo() {
  local tarfile="$1"
  tar_create_repo "$tarfile" || return 1
  ssh_pager "
    stage='$REPO_DEST.stage'
    rm -rf \"\$stage\"
    mkdir -p \"\$stage\" || exit 1
    tar -xzf - -C \"\$stage\" || { rm -rf \"\$stage\"; exit 1; }
    mkdir -p '$REPO_DEST' || { rm -rf \"\$stage\"; exit 1; }
    cp -a \"\$stage\"/. '$REPO_DEST'/ || { rm -rf \"\$stage\"; exit 1; }
    rm -rf \"\$stage\"
    test -f '$REPO_DEST/online-install.sh' && test -d '$REPO_DEST/payloads'
  " < "$tarfile"
}

# ---------------------------------------------------------------------------
# Remote bootstrap
# ---------------------------------------------------------------------------
make_bootstrap() {
  local out="$1"
  {
    printf '#!/bin/sh\n'
    printf '# Generated by provision-pagers.sh on %s\n' "$(date)"
    printf 'SSID_B64=%s\n' "$(printf '%s' "$SSID" | base64 | tr -d '\n')"
    printf 'PSK_B64=%s\n'  "$(printf '%s' "$PSK"  | base64 | tr -d '\n')"
    printf 'SELECTION=%s\n' "$(shq "$SELECTION")"
    printf 'RUN_ID=%s\n'    "$(shq "$RUN_ID")"
    printf 'REPO_DEST=%s\n' "$(shq "$REPO_DEST")"
    printf 'WIFI_SECURITY=%s\n' "$(shq "$WIFI_SECURITY")"
    cat <<'BOOTSTRAP_EOF'

set -u

SSID="$(printf '%s' "$SSID_B64" | base64 -d 2>/dev/null)"
PSK="$(printf '%s' "$PSK_B64" | base64 -d 2>/dev/null)"

log() { echo "[provision] $*"; }
fail() {
  echo "PROVISION_RESULT=failed"
  echo "PROVISION_ERROR=$*"
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "not running as root"
[ -d /mmc/root ] || fail "/mmc/root is missing"
[ -d "$REPO_DEST" ] || fail "repo not found at $REPO_DEST"
[ -f "$REPO_DEST/online-install.sh" ] || fail "online-install.sh missing at $REPO_DEST"
[ -n "$SSID" ] || fail "empty SSID after decode"

DEVICE_MAC="$(cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo unknown)"
FW_VERSION=""
FW_CHANNEL=""
if [ -f /etc/pineapplepager/version ]; then
  FW_VERSION="$(sed -n '1p' /etc/pineapplepager/version 2>/dev/null | tr -d '\r')"
  FW_CHANNEL="$(sed -n '2p' /etc/pineapplepager/version 2>/dev/null | tr -d '\r')"
fi

echo "DEVICE_MAC=$DEVICE_MAC"
echo "FW_VERSION=$FW_VERSION"
echo "FW_CHANNEL=$FW_CHANNEL"

# If an installer is already running, do not start a second copy.
RUNNING_PID="$(pgrep -f 'online-install.sh' 2>/dev/null | sort -n | head -n1)"
if [ -n "$RUNNING_PID" ]; then
  RUNNING_LOG="$(readlink "/proc/$RUNNING_PID/fd/1" 2>/dev/null)"
  echo "PROVISION_RESULT=already_running"
  echo "INSTALLER_PID=$RUNNING_PID"
  echo "LOG_PATH=$RUNNING_LOG"
  exit 0
fi

FREE_KB="$(df -k /mmc 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 102400 ] 2>/dev/null; then
  log "WARNING: /mmc has less than 100 MB free (${FREE_KB} KB)"
fi

configure_uci() {
  log "configuring client mode via uci"
  uci set wireless.wlan0cli=wifi-iface
  uci set wireless.wlan0cli.device='radio0'
  uci set wireless.wlan0cli.ifname='wlan0cli'
  uci set wireless.wlan0cli.network='cli'
  uci set wireless.wlan0cli.mode='sta'
  uci set wireless.wlan0cli.disabled='0'
  uci set wireless.wlan0cli.ssid="$SSID"
  if [ -n "$PSK" ]; then
    uci set wireless.wlan0cli.encryption="$WIFI_SECURITY"
    uci set wireless.wlan0cli.key="$PSK"
  else
    uci set wireless.wlan0cli.encryption='none'
    uci -q delete wireless.wlan0cli.key
  fi
  uci set network.cli=interface
  uci set network.cli.device='wlan0cli'
  uci set network.cli.proto='dhcp'
  uci set network.cli.disabled='0'
  uci commit wireless || fail "uci commit wireless failed"
  uci commit network || fail "uci commit network failed"
  wifi reload >/dev/null 2>&1 || wifi up >/dev/null 2>&1 || true
  ifup cli >/dev/null 2>&1 || true
}

wait_for_wifi() {
  local limit="${1:-90}" i=0 stable=0
  while [ "$i" -lt "$limit" ]; do
    if ip -4 addr show dev wlan0cli 2>/dev/null | grep -q 'inet ' && \
       ip route 2>/dev/null | grep -q '^default .*wlan0cli'; then
      stable=$((stable + 1))
      [ "$stable" -ge 5 ] && return 0
    else
      stable=0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

configure_wifi_connect() {
  command -v WIFI_CONNECT >/dev/null 2>&1 || return 1
  log "trying WIFI_CONNECT fallback"
  if [ -z "$PSK" ]; then
    WIFI_CONNECT wlan0cli "$SSID" open NONE ANY >/tmp/provision-wifi.log 2>&1
  else
    WIFI_CONNECT wlan0cli "$SSID" "$WIFI_SECURITY" "$PSK" ANY >/tmp/provision-wifi.log 2>&1
  fi
}

WIFI_METHOD="uci"
configure_uci
sleep 3
if ! wait_for_wifi 60; then
  log "uci client mode did not associate within 60s"
  if configure_wifi_connect; then
    WIFI_METHOD="WIFI_CONNECT"
    wait_for_wifi 60 || true
  else
    log "WIFI_CONNECT fallback unavailable or failed"
  fi
fi

wait_for_wifi 30 || {
  log "client mode did not get an IPv4 address and default route"
  tail -n 20 /tmp/provision-wifi.log 2>/dev/null
  fail "Wi-Fi client mode failed (SSID=$SSID). If the AP is WPA3-only, retry with WIFI_SECURITY=sae."
}

# Go easy on the radio: power save can make the first pings after an idle
# gap fail, which is exactly when the installer performs its WAN check.
if command -v iw >/dev/null 2>&1; then
  iw dev wlan0cli set power_save off >/dev/null 2>&1 || true
elif command -v iwconfig >/dev/null 2>&1; then
  iwconfig wlan0cli power off >/dev/null 2>&1 || true
fi

wait_for_wan() {
  local limit=30 i=0 streak=0
  while [ "$i" -lt "$limit" ]; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      streak=$((streak + 1))
      if [ "$streak" -ge 4 ]; then
        # Confirm with the exact command the installer uses.
        if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
          return 0
        fi
        streak=0
      fi
    else
      streak=0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

log "waiting for a stable WAN link (4 consecutive checks + installer check)..."
if ! wait_for_wan; then
  log "WAN check failed; diagnostics:"
  echo "--- ip addr wlan0cli ---"
  ip -4 addr show dev wlan0cli 2>&1
  echo "--- ip route ---"
  ip route 2>&1
  if command -v iw >/dev/null 2>&1; then
    echo "--- iw dev wlan0cli link ---"
    iw dev wlan0cli link 2>&1
  fi
  echo "--- ping -c 2 -W 3 8.8.8.8 ---"
  ping -c 2 -W 3 8.8.8.8 2>&1
  fail "Wi-Fi associated but 8.8.8.8 is unreachable; the installer WAN check would fail"
fi

CLOCK_YEAR="$(date +%Y 2>/dev/null)"
if [ -n "$CLOCK_YEAR" ] && [ "$CLOCK_YEAR" -lt 2024 ] 2>/dev/null; then
  log "clock appears unsynchronized ($(date)); trying NTP before HTTPS"
  ntpd -q -p 1.openwrt.pool.ntp.org >/dev/null 2>&1 || true
fi

if command -v wget >/dev/null 2>&1; then
  log "waiting for DNS/HTTPS to github.com..."
  HTTPS_OK=0
  i=0
  while [ "$i" -lt 10 ]; do
    if wget -q -T 5 -O /dev/null https://github.com 2>/dev/null; then
      HTTPS_OK=1
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ "$HTTPS_OK" != 1 ]; then
    log "WARNING: HTTPS/DNS to github.com is not working; the installer may fall back to the local repo"
  fi
fi

# Final confirmation immediately before launch. The installer's own WAN
# check happens less than a second after this.
log "final WAN confirmation..."
FINAL_OK=0
i=0
while [ "$i" -lt 3 ]; do
  if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    FINAL_OK=1
    break
  fi
  i=$((i + 1))
  sleep 3
done
[ "$FINAL_OK" = 1 ] || fail "WAN link dropped again before launch; refusing to start the installer"

WLAN_IP="$(ip -4 addr show dev wlan0cli 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

LOG_DIR=/mmc/root/skinny-install-logs
mkdir -p "$LOG_DIR" || fail "could not create $LOG_DIR"
LOG="$LOG_DIR/$RUN_ID.log"
PIDFILE="$LOG_DIR/$RUN_ID.pid"
RUNNER="/tmp/.skinny-install-runner-$RUN_ID.sh"

cat > "$RUNNER" <<RUNNER_EOF
#!/bin/sh
cd "$REPO_DEST" || exit 1
echo \$\$ > "$PIDFILE"

attempt=0
while [ "\$attempt" -lt 2 ]; do
  sh ./online-install.sh --select "$SELECTION" >> "$LOG" 2>&1 < /dev/null
  rc=\$?
  [ "\$rc" -eq 0 ] && exit 0
  attempt=\$((attempt + 1))
  if [ "\$attempt" -lt 2 ] && grep -q 'No internet connectivity detected' "$LOG" 2>/dev/null; then
    printf '\n[provision] installer WAN check failed; waiting 20s, then retrying once\n' >> "$LOG"
    sleep 20
    continue
  fi
  exit "\$rc"
done
exit 1
RUNNER_EOF
chmod 700 "$RUNNER"

DETACH_METHOD="unknown"
if command -v setsid >/dev/null 2>&1 && setsid true >/dev/null 2>&1; then
  setsid sh "$RUNNER" >> "$LOG" 2>&1 < /dev/null &
  DETACH_METHOD="setsid"
elif command -v start-stop-daemon >/dev/null 2>&1; then
  start-stop-daemon -S -b -x "$RUNNER" >> "$LOG" 2>&1
  DETACH_METHOD="start-stop-daemon"
else
  sh "$RUNNER" >> "$LOG" 2>&1 < /dev/null &
  DETACH_METHOD="background"
fi

i=0
while [ ! -s "$PIDFILE" ] && [ "$i" -lt 10 ]; do
  i=$((i + 1))
  sleep 1
done
PID="$(cat "$PIDFILE" 2>/dev/null)"
[ -n "$PID" ] || PID="$(pgrep -f 'online-install.sh' 2>/dev/null | sort -n | head -n1)"
if [ -z "$PID" ]; then
  log "installer did not start; diagnostics:"
  echo "--- detach method ---"
  echo "$DETACH_METHOD"
  echo "--- detach tools ---"
  for t in setsid nohup start-stop-daemon; do
    printf '%s: ' "$t"
    command -v "$t" 2>/dev/null || echo missing
  done
  echo "--- runner ---"
  cat "$RUNNER" 2>&1
  echo "--- matching processes ---"
  ps 2>&1 | grep -E 'online-install|skinny-install-runner' | grep -v grep
  echo "--- log ---"
  tail -n 20 "$LOG" 2>&1
  fail "installer failed to start"
fi

HEALTH="ok"
ONLINE=0
i=0
while [ "$i" -lt 120 ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if grep -q 'Internet Connection: ONLINE' "$LOG" 2>/dev/null; then
    ONLINE=1
    break
  fi
  # "No internet connectivity detected" is handled by the supervisor's
  # single automatic retry, so it is not fatal here.
  if grep -qE 'opkg update failed|Please run as root|no Skinny-Tools source available' "$LOG" 2>/dev/null; then
    log "installer reported a fatal error"
    tail -n 20 "$LOG" 2>/dev/null
    echo "PROVISION_RESULT=failed"
    echo "PROVISION_ERROR=installer reported a fatal error"
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done

if ! kill -0 "$PID" 2>/dev/null; then
  log "installer exited before the health check passed"
  tail -n 20 "$LOG" 2>/dev/null
  echo "PROVISION_RESULT=failed"
  echo "PROVISION_ERROR=installer exited early"
  exit 1
fi

PID_STATE="$(awk '{print $3}' "/proc/$PID/stat" 2>/dev/null)"
if [ "$PID_STATE" = "Z" ]; then
  log "installer process is a zombie"
  tail -n 20 "$LOG" 2>/dev/null
  echo "PROVISION_RESULT=failed"
  echo "PROVISION_ERROR=installer process is a zombie"
  exit 1
fi

if [ "$ONLINE" != 1 ]; then
  HEALTH="warning"
  log "WARNING: installer is alive but 'Internet Connection: ONLINE' was not seen within 120s"
fi

if [ -d "/proc/$PID" ]; then
  FD0="$(readlink "/proc/$PID/fd/0" 2>/dev/null)"
  FD1="$(readlink "/proc/$PID/fd/1" 2>/dev/null)"
  case "$FD1" in
    *"$LOG"*) ;;
    *) HEALTH="warning"; log "WARNING: installer stdout is not the expected log ($FD1)" ;;
  esac
  [ "$FD0" = "/dev/null" ] || { HEALTH="warning"; log "WARNING: installer stdin is $FD0"; }
  TTY_NR="$(awk '{print $7}' "/proc/$PID/stat" 2>/dev/null)"
  if [ "$TTY_NR" != "0" ]; then
    SIGIGN="$(awk '/^SigIgn:/{print $2}' "/proc/$PID/status" 2>/dev/null)"
    if [ -n "$SIGIGN" ] && [ $((0x$SIGIGN & 1)) -eq 0 ] 2>/dev/null; then
      HEALTH="warning"
      log "WARNING: installer has a controlling tty and SIGHUP is not ignored"
    fi
  fi
fi

rm -f "$RUNNER"

echo "PROVISION_RESULT=ok"
echo "DEVICE_MAC=$DEVICE_MAC"
echo "WLAN_IP=$WLAN_IP"
echo "FW_VERSION=$FW_VERSION"
echo "FW_CHANNEL=$FW_CHANNEL"
echo "INSTALLER_PID=$PID"
echo "LOG_PATH=$LOG"
echo "DETACH_METHOD=$DETACH_METHOD"
echo "WIFI_METHOD=$WIFI_METHOD"
echo "WAN_ONLINE=$ONLINE"
echo "HEALTH=$HEALTH"
exit 0
BOOTSTRAP_EOF
  } > "$out"
}

# ---------------------------------------------------------------------------
# Firmware check (report only)
# ---------------------------------------------------------------------------
fetch_latest_firmware() {
  local json
  have curl || return 1
  have jq   || return 1
  json="$(curl -fsSL --max-time 20 "$FW_API" 2>/dev/null)" || return 1
  LATEST_FW_RAW="$(printf '%s' "$json" | jq -r '.[] | select(.model == "wifipineapplepager") | .version' 2>/dev/null | head -n1)"
  [ -n "$LATEST_FW_RAW" ] || return 1
  LATEST_FW="$(ver_norm "$LATEST_FW_RAW")"
  [ -n "$LATEST_FW" ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$LATEST_FW_RAW" > "$LATEST_FW_FILE" 2>/dev/null || true
  return 0
}

compute_fw_status() {
  local installed channel
  installed="$(ver_norm "$1")"
  channel="${2:-}"
  if [ -z "$installed" ]; then
    echo "unknown"
    return
  fi
  if [ "$CHECK_FW" != 1 ]; then
    echo "not_checked"
    return
  fi
  if [ -z "$LATEST_FW" ]; then
    echo "check_failed"
    return
  fi
  if ver_gt "$LATEST_FW" "$installed"; then
    echo "update_available"
  else
    echo "latest"
  fi
}

print_fw_line() {
  local installed="$1" channel="$2" status="$3"
  case "$status" in
    latest)
      printf '    Firmware: %s (latest stable)\n' "$installed"
      ;;
    update_available)
      printf '    Firmware: %s -> %s available (check only; NOT installed)\n' "$installed" "$LATEST_FW_RAW"
      ;;
    unknown)
      printf '    Firmware: unknown (/etc/pineapplepager/version missing)\n'
      ;;
    check_failed)
      printf '    Firmware: %s (Hak5 feed unavailable; not checked)\n' "$installed"
      ;;
    *)
      printf '    Firmware: %s (check not requested)\n' "$installed"
      ;;
  esac
  if [ -n "$channel" ] && [ "$channel" != "Stable" ] && [ "$CHECK_FW" = 1 ]; then
    printf '      Channel: %s (compared against the stable feed)\n' "$channel"
  fi
}

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
state_init() {
  mkdir -p "$STATE_DIR" || die "could not create $STATE_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    printf 'timestamp\tdevice_mac\twlan_ip\tselection\tlog_path\tinstaller_pid\tfw_version\tfw_channel\tfw_status\tresult\n' > "$STATE_FILE"
  fi
}

state_add() {
  local mac="$1" ip="$2" sel="$3" log="$4" pid="$5" fw="$6" chan="$7" fwstat="$8" result="$9"
  [ -n "$mac" ]     || mac="-"
  [ -n "$ip" ]      || ip="-"
  [ -n "$log" ]     || log="-"
  [ -n "$pid" ]     || pid="-"
  [ -n "$fw" ]      || fw="-"
  [ -n "$chan" ]    || chan="-"
  [ -n "$fwstat" ]  || fwstat="-"
  [ -n "$result" ]  || result="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$mac" "$ip" "$sel" "$log" "$pid" "$fw" "$chan" "$fwstat" "$result" \
    >> "$STATE_FILE"
}

previous_provisioning_time() {
  local mac="$1"
  [ -f "$STATE_FILE" ] || return 1
  awk -F'\t' -v m="$mac" 'NR > 1 && $2 == m { t = $1 } END { if (t != "") print t; else exit 1 }' "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Status mode
# ---------------------------------------------------------------------------
status_remote_cmd() {
  local log="$1"
  cat <<EOF
PID=\$(pgrep -f 'online-install.sh' 2>/dev/null | sort -n | head -n1)
if [ -n "\$PID" ]; then
  echo "  Installer: RUNNING (pid \$PID)"
else
  echo "  Installer: not running"
fi
if [ -f '$log' ]; then
  echo "  Log: $log"
  echo "  --- last log lines ---"
  tail -n 5 '$log' | sed 's/^/    /'
else
  echo "  Log: $log (missing)"
fi
FW_VER=\$(sed -n '1p' /etc/pineapplepager/version 2>/dev/null)
FW_CH=\$(sed -n '2p' /etc/pineapplepager/version 2>/dev/null)
if [ -n "\$FW_VER" ]; then
  echo "  Firmware: \$FW_VER (\$FW_CH)"
else
  echo "  Firmware: unknown"
fi
echo "  WiFi IP: \$(ip -4 addr show dev wlan0cli 2>/dev/null | awk '/inet /{print \$2}' | cut -d/ -f1 | head -n1)"
EOF
}

status_mode() {
  if [ ! -f "$STATE_FILE" ]; then
    say "No provisioning state found at $STATE_FILE"
    return 0
  fi

  if [ "$STATUS_CHECK_FW" = 1 ]; then
    CHECK_FW=1
    if fetch_latest_firmware; then
      say "[+] Latest Pager firmware (stable): $LATEST_FW_RAW"
    else
      warn "Could not reach the Hak5 firmware feed; showing recorded firmware only."
      CHECK_FW=0
    fi
  elif [ -f "$LATEST_FW_FILE" ]; then
    say "[*] Latest Pager firmware (cached from last check): $(cat "$LATEST_FW_FILE" 2>/dev/null)"
  fi

  local tmp="$TMP_DIR/status"
  mkdir -p "$tmp"
  local i=0

  while IFS=$'\t' read -r ts mac ip sel log pid fwver fwchan fwstat result; do
    i=$((i + 1))
    [ -n "$mac" ] || continue
    (
      echo "=== $mac  ${ip:-?}  ($sel, $ts) ==="
      if [ -z "$ip" ] || [ "$ip" = "-" ]; then
        echo "  No Wi-Fi IP recorded; re-plug over USB to update state."
        exit 0
      fi
      cmd="$(status_remote_cmd "$log")"
      ssh_to "$ip" "$cmd" 2>&1 || echo "  Unreachable over Wi-Fi ($ip)"
      echo "  Recorded: $fwver ($fwstat)"
    ) > "$tmp/$i.out" 2>&1 &
  done < <(awk -F'\t' 'NR > 1 { last[$2] = $0 } END { for (m in last) print last[m] }' "$STATE_FILE")

  wait
  for f in "$tmp"/*.out; do
    [ -f "$f" ] || continue
    cat "$f"
  done
}

# ---------------------------------------------------------------------------
# Provisioning flow
# ---------------------------------------------------------------------------
run_one_pager() {
  local n="$1"
  local attempt=0
  local tmp_repo="$TMP_DIR/repo-$n.tar.gz"
  local bootstrap="$TMP_DIR/bootstrap-$n.sh"
  local outfile="$TMP_DIR/pager-$n.out"
  local ssh_rc=0
  local probe_mac=""
  local dup_answer=""

  while true; do
    attempt=$((attempt + 1))
    RUN_ID="$(now_id)-p$(printf '%02d' "$n")-$$-$attempt"

    say ""
    say "---------------------------------------------"
    say " Pager #$n (attempt $attempt)"
    say "---------------------------------------------"

    if ! wait_for_pager 60; then
      warn "Pager not reachable at $PAGER_HOST:$PAGER_SSH_PORT."
      say "    Check the USB-C data cable, that the Pager is booted, and that"
      say "    the Mac got a 172.16.52.x lease on the USB Ethernet interface."
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    say "[*] SSH check..."
    local ssh_out
    ssh_out="$(ssh_pager 'echo PROVISION_SSH_OK' 2>&1)"
    if ! printf '%s' "$ssh_out" | grep -q 'PROVISION_SSH_OK'; then
      warn "SSH authentication failed for $PAGER_USER@$PAGER_HOST."
      printf '%s\n' "$ssh_out" | tail -n 5 | sed 's/^/    /'
      say "    Verify PAGER_PASSWORD (default: password) and that the Pager finished booting."
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    say "[*] Identifying Pager..."
    probe_mac="$(ssh_pager "cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -n1)"

    if [ "$FORCE" != 1 ] && [ -n "$LAST_MAC" ] && [ -n "$probe_mac" ] && [ "$probe_mac" = "$LAST_MAC" ]; then
      while true; do
        say ""
        warn "This is the same Pager you just provisioned ($probe_mac)."
        say "    Unplug it, connect the next Pager, then press Enter."
        say "    (q to quit)"
        printf '  > '
        IFS= read -r dup_answer || return 2
        case "$dup_answer" in
          q|Q) return 2 ;;
        esac
        if ! wait_for_pager 60; then
          warn "No Pager reachable at $PAGER_HOST:$PAGER_SSH_PORT."
          continue
        fi
        probe_mac="$(ssh_pager "cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -n1)"
        if [ -z "$probe_mac" ] || [ "$probe_mac" != "$LAST_MAC" ]; then
          break
        fi
      done
      say "[*] New Pager detected: $probe_mac"
    fi

    say "[*] Copying repository to $REPO_DEST (merge, no deletion)..."
    if ! push_repo "$tmp_repo"; then
      warn "Failed to copy the repository to the Pager."
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    say "[*] Configuring client Wi-Fi and launching the installer..."
    make_bootstrap "$bootstrap"

    ssh_pager "cat > /tmp/.pager-provision.sh && sh /tmp/.pager-provision.sh; rc=\$?; rm -f /tmp/.pager-provision.sh; exit \$rc" \
      < "$bootstrap" | tee "$outfile"
    ssh_rc=${PIPESTATUS[0]}

    if [ "$ssh_rc" -ne 0 ]; then
      warn "Remote bootstrap failed (ssh exit $ssh_rc)."
      tail -n 20 "$outfile" | sed 's/^/    /'
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    local result dev_mac wlan_ip fwver fwchan pid logpath health detach
    result="$(field PROVISION_RESULT "$outfile")"
    dev_mac="$(field DEVICE_MAC "$outfile")"
    wlan_ip="$(field WLAN_IP "$outfile")"
    fwver="$(field FW_VERSION "$outfile")"
    fwchan="$(field FW_CHANNEL "$outfile")"
    pid="$(field INSTALLER_PID "$outfile")"
    logpath="$(field LOG_PATH "$outfile")"
    health="$(field HEALTH "$outfile")"
    detach="$(field DETACH_METHOD "$outfile")"
    [ -n "$dev_mac" ] || dev_mac="$probe_mac"

    if [ "$result" != "ok" ] && [ "$result" != "already_running" ]; then
      warn "Provisioning did not complete (result: ${result:-none})."
      tail -n 25 "$outfile" | sed 's/^/    /'
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    local fwstat
    fwstat="$(compute_fw_status "$fwver" "$fwchan")"

    if [ "$result" = "already_running" ]; then
      say ""
      say "[!] An installer was already running on this Pager; no second copy started."
      say "    PID: $pid"
      say "    Log: ${logpath:-unknown}"
      print_fw_line "$fwver" "$fwchan" "$fwstat"
      state_add "$dev_mac" "$wlan_ip" "$SELECTION" "$logpath" "$pid" "$fwver" "$fwchan" "$fwstat" "$result"
      LAST_MAC="$dev_mac"
      say "    You can unplug this Pager and connect the next one."
      return 0
    fi

    if [ "$health" = "warning" ]; then
      warn "Installer is running, but the health check returned a warning."
      say "    Inspect the log before relying on this Pager:"
    else
      say ""
      say "[+] Installer is running detached and healthy."
      say "    PID:     $pid"
    fi

    say "    Device:  ${dev_mac:-unknown}"
    say "    Wi-Fi:   ${wlan_ip:-unknown}"
    say "    Log:     ${logpath:-unknown}"
    say "    Detach:  ${detach:-unknown}"
    print_fw_line "$fwver" "$fwchan" "$fwstat"

    local prev
    prev="$(previous_provisioning_time "$dev_mac" 2>/dev/null || true)"
    if [ -n "$prev" ] && [ "$prev" != "-" ]; then
      say "    Note: this Pager was previously provisioned on $prev."
    fi

    state_add "$dev_mac" "$wlan_ip" "$SELECTION" "$logpath" "$pid" "$fwver" "$fwchan" "$fwstat" "$result"

    LAST_MAC="$dev_mac"
    say ""
    say "[+] You can unplug this Pager now and connect the next one."
    return 0
  done
}

field() {
  local key="$1" file="$2"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null
}

print_summary() {
  [ -f "$STATE_FILE" ] || return 0
  say ""
  say "============================================="
  say " Provisioning summary"
  say "============================================="
  awk -F'\t' '
    NR == 1 { next }
    {
      printf "%-17s %-15s %-3s %-16s %-10s %s\n", $2, $3, $4, $7, $9, $5
    }
  ' "$STATE_FILE"
  say ""
  say "State: $STATE_FILE"
  say "Check later with: $0 --status"
}

# ---------------------------------------------------------------------------
# Completion-check mode (read-only)
# ---------------------------------------------------------------------------
make_completion_check_script() {
  local out="$1"
  cat > "$out" <<'CHECK_EOF'
#!/bin/sh

PAYLOAD_ROOT=/mmc/root/payloads
LOG_DIR=/mmc/root/skinny-install-logs

DEVICE_MAC="$(cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo unknown)"
FW_VERSION=""
FW_CHANNEL=""
if [ -f /etc/pineapplepager/version ]; then
  FW_VERSION="$(sed -n '1p' /etc/pineapplepager/version 2>/dev/null | tr -d '\r')"
  FW_CHANNEL="$(sed -n '2p' /etc/pineapplepager/version 2>/dev/null | tr -d '\r')"
fi
WLAN_IP="$(ip -4 addr show dev wlan0cli 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

INSTALLER_RUNNING=0
if pgrep -f 'online-install.sh' >/dev/null 2>&1 || pgrep -f 'skinny-install-runner' >/dev/null 2>&1; then
  INSTALLER_RUNNING=1
fi

PAYLOAD_TOTAL=9
PAYLOAD_OK=0
MISSING_PAYLOADS=""
for p in \
  recon/access_point/Aireplay-ng-AP-Deauth \
  recon/access_point/foxhunt_AP \
  recon/client/foxhunt_clients \
  recon/access_point/PMF-Checker \
  recon/access_point/Quick-Brown-Fox-AP \
  user/Skinny-Tools/Skinny-Skim-Scanner \
  user/Skinny-Tools/gps-mgmtap-nmea \
  user/Skinny-Tools/WiFi-Client-Tracker-Targeted \
  user/utilities/PAGERCTL
do
  parent="$(dirname "$p")"
  base="$(basename "$p")"
  if [ -d "$PAYLOAD_ROOT/$p" ] || [ -d "$PAYLOAD_ROOT/$parent/DISABLED.$base" ]; then
    PAYLOAD_OK=$((PAYLOAD_OK + 1))
  else
    MISSING_PAYLOADS="$MISSING_PAYLOADS $p"
  fi
done

BIN_TOTAL=7
BIN_OK=0
MISSING_BINS=""
for b in python3 airodump-ng aireplay-ng sqlite3 btmon hcitool hciconfig; do
  if command -v "$b" >/dev/null 2>&1; then
    BIN_OK=$((BIN_OK + 1))
  else
    MISSING_BINS="$MISSING_BINS $b"
  fi
done

PY_CTYPES=0
python3 -c 'import ctypes' >/dev/null 2>&1 && PY_CTYPES=1

PAGERCTL_OK=0
python3 -c 'from pagerctl import Pager' >/dev/null 2>&1 && PAGERCTL_OK=1

IW_PRESENT=0
command -v iw >/dev/null 2>&1 && IW_PRESENT=1

GPSD_PRESENT=0
[ -x /etc/init.d/gpsd ] && GPSD_PRESENT=1

RECON_DB_PRESENT=0
[ -d /root/recon ] && RECON_DB_PRESENT=1

LOG_PATH=""
LOG_SUCCESS=0
LOG_9OF9=0
if [ -d "$LOG_DIR" ]; then
  for f in $(ls -t "$LOG_DIR"/*.log 2>/dev/null); do
    [ -f "$f" ] || continue
    [ -n "$LOG_PATH" ] || LOG_PATH="$f"
    if grep -q 'SUCCESS: Pager Class deployment complete' "$f" 2>/dev/null; then
      LOG_PATH="$f"
      LOG_SUCCESS=1
      grep -q 'Pager Class payload set verified (9/9)' "$f" 2>/dev/null && LOG_9OF9=1
      break
    fi
  done
fi

RESULT="pass"
[ "$PAYLOAD_OK" -eq "$PAYLOAD_TOTAL" ] || RESULT="fail"
[ "$BIN_OK" -eq "$BIN_TOTAL" ] || RESULT="fail"
[ "$PY_CTYPES" -eq 1 ] || RESULT="fail"
[ "$PAGERCTL_OK" -eq 1 ] || RESULT="fail"
[ "$INSTALLER_RUNNING" -eq 0 ] || RESULT="fail"

MISSING_PAYLOADS="${MISSING_PAYLOADS# }"
MISSING_BINS="${MISSING_BINS# }"

echo "[completion] Device:        $DEVICE_MAC"
echo "[completion] Firmware:      $FW_VERSION ($FW_CHANNEL)"
echo "[completion] Wi-Fi IP:      $WLAN_IP"
echo "[completion] Installer running: $INSTALLER_RUNNING"
echo "[completion] Payloads:      $PAYLOAD_OK/$PAYLOAD_TOTAL present"
[ -n "$MISSING_PAYLOADS" ] && echo "[completion]   missing:     $MISSING_PAYLOADS"
echo "[completion] Tools:         $BIN_OK/$BIN_TOTAL present"
[ -n "$MISSING_BINS" ] && echo "[completion]   missing:     $MISSING_BINS"
echo "[completion] python ctypes: $PY_CTYPES"
echo "[completion] PAGERCTL:      $PAGERCTL_OK"
echo "[completion] iw (optional): $IW_PRESENT"
echo "[completion] gpsd (optional): $GPSD_PRESENT"
echo "[completion] /root/recon (optional): $RECON_DB_PRESENT"
if [ -n "$LOG_PATH" ]; then
  echo "[completion] Installer log: $LOG_PATH"
  echo "[completion]   success marker: $LOG_SUCCESS (9/9 marker: $LOG_9OF9)"
else
  echo "[completion] Installer log: not found"
fi
echo "[completion] Overall:       $RESULT"

echo "COMPLETION_RESULT=$RESULT"
echo "DEVICE_MAC=$DEVICE_MAC"
echo "FW_VERSION=$FW_VERSION"
echo "FW_CHANNEL=$FW_CHANNEL"
echo "WLAN_IP=$WLAN_IP"
echo "INSTALLER_RUNNING=$INSTALLER_RUNNING"
echo "PAYLOAD_OK=$PAYLOAD_OK"
echo "PAYLOAD_TOTAL=$PAYLOAD_TOTAL"
echo "MISSING_PAYLOADS=$MISSING_PAYLOADS"
echo "BIN_OK=$BIN_OK"
echo "BIN_TOTAL=$BIN_TOTAL"
echo "MISSING_BINS=$MISSING_BINS"
echo "PY_CTYPES=$PY_CTYPES"
echo "PAGERCTL_OK=$PAGERCTL_OK"
echo "IW_PRESENT=$IW_PRESENT"
echo "GPSD_PRESENT=$GPSD_PRESENT"
echo "RECON_DB_PRESENT=$RECON_DB_PRESENT"
echo "LOG_PATH=$LOG_PATH"
echo "LOG_SUCCESS=$LOG_SUCCESS"
echo "LOG_9OF9=$LOG_9OF9"
exit 0
CHECK_EOF
}

completion_state_init() {
  mkdir -p "$STATE_DIR" || die "could not create $STATE_DIR"
  if [ ! -f "$COMPLETION_STATE_FILE" ]; then
    printf 'timestamp\tdevice_mac\tfw_version\tresult\tpayloads\ttools\tpagerctl\tlog_path\tlog_success\n' > "$COMPLETION_STATE_FILE"
  fi
}

completion_add() {
  local mac="$1" fw="$2" result="$3" payloads="$4" tools="$5" pagerctl="$6" log="$7" logok="$8"
  [ -n "$mac" ] || mac="-"
  [ -n "$fw" ] || fw="-"
  [ -n "$result" ] || result="-"
  [ -n "$payloads" ] || payloads="-"
  [ -n "$tools" ] || tools="-"
  [ -n "$pagerctl" ] || pagerctl="-"
  [ -n "$log" ] || log="-"
  [ -n "$logok" ] || logok="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$mac" "$fw" "$result" "$payloads" "$tools" "$pagerctl" "$log" "$logok" \
    >> "$COMPLETION_STATE_FILE"
}

print_completion_summary() {
  [ -f "$COMPLETION_STATE_FILE" ] || return 0
  say ""
  say "============================================="
  say " Completion-check summary"
  say "============================================="
  awk -F'\t' '
    NR == 1 { next }
    {
      printf "%-17s %-9s %-6s %-6s %-8s %s\n", $2, $4, $5, $6, $7, $8
    }
  ' "$COMPLETION_STATE_FILE"
  say ""
  say "State: $COMPLETION_STATE_FILE"
}

shutdown_pager() {
  local cmd spid i
  # Match the Pager's own safe-shutdown path. halt-power touches
  # /root/properShutdown and /tmp/power_off before halting.
  cmd='if [ -x /sbin/halt-power ]; then sync; /sbin/halt-power; elif [ -x /sbin/poweroff ]; then sync; /sbin/poweroff; else sync; poweroff; fi'
  ssh_pager "$cmd" >/dev/null 2>&1 &
  spid=$!

  i=0
  while kill -0 "$spid" 2>/dev/null && [ "$i" -lt 20 ]; do
    i=$((i + 1))
    sleep 1
  done
  if kill -0 "$spid" 2>/dev/null; then
    kill "$spid" 2>/dev/null || true
  fi

  i=0
  while pager_reachable && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 1
  done
  if pager_reachable; then
    return 1
  fi
  return 0
}

run_completion_check() {
  local n="$1"
  local outfile="$TMP_DIR/completion-$n.out"
  local check_script="$TMP_DIR/completion-check.sh"
  local probe_mac=""
  local dup_answer=""
  local ssh_out=""
  local ssh_rc=0

  while true; do
    say ""
    say "---------------------------------------------"
    say " Completion check: Pager #$n"
    say "---------------------------------------------"

    if ! wait_for_pager 60; then
      warn "Pager not reachable at $PAGER_HOST:$PAGER_SSH_PORT."
      say "    Check the USB-C data cable and that the Pager is booted."
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    say "[*] SSH check..."
    ssh_out="$(ssh_pager 'echo PROVISION_SSH_OK' 2>&1)"
    if ! printf '%s' "$ssh_out" | grep -q 'PROVISION_SSH_OK'; then
      warn "SSH authentication failed for $PAGER_USER@$PAGER_HOST."
      printf '%s\n' "$ssh_out" | tail -n 5 | sed 's/^/    /'
      say "    Verify PAGER_PASSWORD (default: password) and that the Pager finished booting."
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    say "[*] Identifying Pager..."
    probe_mac="$(ssh_pager "cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -n1)"

    if [ "$FORCE" != 1 ] && [ -n "$LAST_CHECK_MAC" ] && [ -n "$probe_mac" ] && [ "$probe_mac" = "$LAST_CHECK_MAC" ]; then
      while true; do
        say ""
        warn "This is the same Pager you just checked ($probe_mac)."
        say "    Unplug it, connect the next Pager, then press Enter."
        say "    (q to quit)"
        printf '  > '
        IFS= read -r dup_answer || return 2
        case "$dup_answer" in
          q|Q) return 2 ;;
        esac
        if ! wait_for_pager 60; then
          warn "No Pager reachable at $PAGER_HOST:$PAGER_SSH_PORT."
          continue
        fi
        probe_mac="$(ssh_pager "cat /sys/class/net/wlan0/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | head -n1)"
        if [ -z "$probe_mac" ] || [ "$probe_mac" != "$LAST_CHECK_MAC" ]; then
          break
        fi
      done
      say "[*] New Pager detected: $probe_mac"
    fi

    say "[*] Reading Pager Class payloads and dependencies..."
    ssh_pager "cat > /tmp/.pager-completion-check.sh && sh /tmp/.pager-completion-check.sh; rc=\$?; rm -f /tmp/.pager-completion-check.sh; exit \$rc" \
      < "$check_script" | tee "$outfile"
    ssh_rc=${PIPESTATUS[0]}

    if [ "$ssh_rc" -ne 0 ]; then
      warn "Completion check failed to run (ssh exit $ssh_rc)."
      tail -n 20 "$outfile" | sed 's/^/    /'
      ask_retry_skip_quit
      case $? in
        0) continue ;;
        1) return 0 ;;
        2) return 2 ;;
      esac
    fi

    local result dev_mac fwver fwchan wlan_ip pay_ok pay_total missing_pay
    local bin_ok bin_total missing_bin py_ctypes pagerctl installer_running
    local logpath log_success
    result="$(field COMPLETION_RESULT "$outfile")"
    dev_mac="$(field DEVICE_MAC "$outfile")"
    fwver="$(field FW_VERSION "$outfile")"
    fwchan="$(field FW_CHANNEL "$outfile")"
    wlan_ip="$(field WLAN_IP "$outfile")"
    installer_running="$(field INSTALLER_RUNNING "$outfile")"
    pay_ok="$(field PAYLOAD_OK "$outfile")"
    pay_total="$(field PAYLOAD_TOTAL "$outfile")"
    missing_pay="$(field MISSING_PAYLOADS "$outfile")"
    bin_ok="$(field BIN_OK "$outfile")"
    bin_total="$(field BIN_TOTAL "$outfile")"
    missing_bin="$(field MISSING_BINS "$outfile")"
    py_ctypes="$(field PY_CTYPES "$outfile")"
    pagerctl="$(field PAGERCTL_OK "$outfile")"
    logpath="$(field LOG_PATH "$outfile")"
    log_success="$(field LOG_SUCCESS "$outfile")"
    [ -n "$dev_mac" ] || dev_mac="$probe_mac"

    say ""
    if [ "$result" = "pass" ]; then
      say "[+] COMPLETION CHECK: PASS"
      say "[*] Issuing safe shutdown (/sbin/halt-power)..."
      if shutdown_pager; then
        say "[+] Shutdown issued; the Pager is powering off."
      else
        warn "Shutdown was issued, but the Pager still answers SSH. Check its screen."
      fi
    else
      say "[-] COMPLETION CHECK: FAIL"
      [ -n "$missing_pay" ] && say "    Missing payloads:$missing_pay"
      [ -n "$missing_bin" ] && say "    Missing tools:$missing_bin"
      [ "$py_ctypes" = "1" ] || say "    Missing: python3 ctypes"
      [ "$pagerctl" = "1" ] || say "    Missing: PAGERCTL import"
      [ "$installer_running" = "1" ] && say "    Installer still running; not safe to shut down."
    fi
    say "    Payloads:  ${pay_ok:-?}/${pay_total:-9}"
    say "    Tools:     ${bin_ok:-?}/${bin_total:-7}"
    say "    PAGERCTL:  ${pagerctl:-?}"
    say "    Installer running: ${installer_running:-?}"
    say "    Firmware:  ${fwver:-unknown} (${fwchan:-unknown})"
    say "    Wi-Fi IP:  ${wlan_ip:-unknown}"
    if [ "$log_success" = "1" ]; then
      say "    Installer log confirms SUCCESS: $logpath"
    elif [ -n "$logpath" ]; then
      say "    Installer log has no success marker: $logpath"
    else
      say "    No installer log found; direct checks above are authoritative."
    fi

    completion_add "$dev_mac" "$fwver" "$result" "${pay_ok:-?}/${pay_total:-9}" \
      "${bin_ok:-?}/${bin_total:-7}" "${pagerctl:-?}" "$logpath" "$log_success"
    if [ "$result" = "pass" ]; then
      LAST_CHECK_MAC="$dev_mac"
    else
      LAST_CHECK_MAC=""
    fi

    say ""
    if [ "$result" = "pass" ]; then
      say "    Unplug the powered-off Pager, plug in the next one, then press Enter (q to quit)."
    else
      say "    This Pager did not pass and was left powered on for troubleshooting."
      say "    Unplug it, plug in the next one, then press Enter (q to quit)."
    fi
    return 0
  done
}

completion_loop() {
  local count=0 answer rc
  make_completion_check_script "$TMP_DIR/completion-check.sh"
  completion_state_init
  while true; do
    drain_stdin
    say ""
    say "============================================="
    say " Completion check: Pager #$((count + 1))"
    say " Plug in Pager and press Enter (q to quit):"
    say "============================================="
    printf '> '
    IFS= read -r answer || break
    case "$answer" in
      q|Q) break ;;
    esac
    count=$((count + 1))
    run_completion_check "$count"
    rc=$?
    [ "$rc" -eq 2 ] && break
  done
  print_completion_summary
}

# ---------------------------------------------------------------------------
# Preflight / prompts / main
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [--status [--check-firmware]] [--dry-run] [--force] [--help]

  (no args)         Asks "Completion check? [y/N]" first. No/blank enters
                    batch provisioning and prompts for SSID, Wi-Fi password,
                    firmware check (default NO), and the online-install.sh
                    profile (S/H/B/C).

                    Yes enters completion-check mode: it verifies
                    the 9 Pager Class payloads, the class dependencies,
                    PAGERCTL, and the installer log's success marker.
                    A PASS issues the Pager's safe shutdown so you know it
                    is ready to box; a FAIL leaves it powered on. It pauses
                    after every Pager so you can swap units.

  --status          Show the latest recorded state for every Pager and,
                    where reachable over Wi-Fi, whether its installer is
                    still running, its last log lines, and its firmware.

  --check-firmware  With --status: explicitly refresh the latest stable
                    firmware version from Hak5. Without this flag, --status
                    never contacts Hak5.

  --dry-run         Ask the questions, generate and validate the repo
                    tarball and per-Pager bootstrap, print them, and exit
                    without touching a Pager.

  --force           Bypass the "same Pager just provisioned" guard. Only
                    needed if you intentionally want to provision the same
                    Pager twice in one session.

  --help, -h        This text.

Environment:
  PAGER_HOST        Pager USB-C address (default: 172.16.52.1)
  PAGER_USER        SSH user (default: root)
  PAGER_PASSWORD    SSH password (default: password)
  PAGER_SSH_PORT    SSH port (default: 22)
  WIFI_SECURITY     Client-mode encryption: psk2 (default), sae, psk, or open
  SKINNY_PAGER_STATE_DIR
                    State directory (default: ~/.skinny-pager-provision)

Firmware updates are CHECK-ONLY. Yes prints whether an update is
available; it never downloads or installs firmware. Blank/no is the
default and contacts no Hak5 firmware endpoint.

The Pager must be on 2.4 GHz Wi-Fi, and the network must allow ICMP to
8.8.8.8 (the installer's own WAN check). Existing payloads are handled
by online-install.sh's no-clobber/no-delete merge; this script never
deletes /mmc/root/payloads.
EOF
}

preflight() {
  have ssh       || die "ssh is required."
  have sshpass   || die "sshpass is required (brew install sshpass)."
  have tar       || die "tar is required."
  have nc        || die "nc is required."
  have base64    || die "base64 is required."
  [ -f "$REPO_DIR/online-install.sh" ] || die "online-install.sh not found in $REPO_DIR"
  [ -d "$REPO_DIR/payloads" ] || die "payloads/ not found in $REPO_DIR"
  export SSHPASS="$PAGER_PASSWORD"
}

prompt_config() {
  while [ -z "$SSID" ]; do
    printf 'Enter your SSID: '
    IFS= read -r SSID || exit 130
  done

  printf 'Enter the password for the SSID: '
  IFS= read -rs PSK || true
  printf '\n'

  printf 'Would you like to check for Firmware updates? [y/N]: '
  local fw_answer=""
  IFS= read -r fw_answer || true
  case "$fw_answer" in
    y|Y|yes|YES|Yes) CHECK_FW=1 ;;
    *)               CHECK_FW=0 ;;
  esac

  while true; do
    cat <<'EOF'
How do you want to configure the pagers?
  [S] Skinny Pager Payloads
      Full install/update: dependencies + cross-compiled tools
  [H] Hak5 Pager Payloads
      Hak5 library/ payloads only
  [B] Both
      Hak5 + Skinny, full dependencies + cross-compiled tools
  [C] Pager Class
      Hak5 + non-cross-compiled Skinny payloads with the class deps:
      foxhunt_AP, foxhunt_clients, Aireplay-ng-AP-Deauth, PMF-Checker,
      Quick-Brown-Fox-AP, Skinny-Skim-Scanner, gps-mgmtap-nmea,
      WiFi-Client-Tracker-Targeted, PAGERCTL
EOF
    printf 'Choice [S/H/B/C]: '
    IFS= read -r SELECTION || exit 130
    case "$SELECTION" in
      s|S) SELECTION="S"; break ;;
      h|H) SELECTION="H"; break ;;
      b|B) SELECTION="B"; break ;;
      c|C) SELECTION="C"; break ;;
      *)   say "Invalid choice. Please enter S, H, B, or C." ;;
    esac
  done
}

main_loop() {
  local count=0 answer rc
  while true; do
    drain_stdin
    say ""
    say "============================================="
    say " Pager #$((count + 1))"
    say " Plug in Pager and press Enter (q to quit):"
    say "============================================="
    printf '> '
    IFS= read -r answer || break
    case "$answer" in
      q|Q) break ;;
    esac

    count=$((count + 1))
    run_one_pager "$count"
    rc=$?
    [ "$rc" -eq 2 ] && break
  done
  print_summary
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status)
      MODE="status"
      ;;
    --check-firmware)
      STATUS_CHECK_FW=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --force)
      FORCE=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf '[-] Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ "$STATUS_CHECK_FW" = 1 ] && [ "$MODE" != "status" ]; then
  warn "--check-firmware only applies with --status; the interactive prompt controls provisioning checks."
fi

preflight

if [ "$MODE" = "status" ]; then
  status_mode
  exit 0
fi

printf 'Completion check? [y/N]: '
IFS= read -r completion_answer || exit 130
case "$completion_answer" in
  y|Y|yes|YES|Yes) COMPLETION_MODE=1 ;;
  *)               COMPLETION_MODE=0 ;;
esac

if [ "$COMPLETION_MODE" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "[dry-run] Generated completion-check script:"
    make_completion_check_script "$TMP_DIR/completion-check-dryrun.sh"
    sed 's/^/          /' "$TMP_DIR/completion-check-dryrun.sh"
    say ""
    say "[dry-run] No Pager was contacted."
    exit 0
  fi
  completion_loop
  exit 0
fi

prompt_config

if [ "$CHECK_FW" = 1 ]; then
  if fetch_latest_firmware; then
    say "[+] Latest Pager firmware (stable): $LATEST_FW_RAW"
  else
    warn "Could not reach the Hak5 firmware feed; firmware status will show 'check failed'."
  fi
else
  say "[*] Firmware update check: disabled (default)."
fi

say "[*] SSID:       $SSID"
say "[*] Profile:    $SELECTION"
say "[*] Password:   ${#PSK} characters"
say "[*] Repo:       $REPO_DIR"
say "[*] Pager:      $PAGER_USER@$PAGER_HOST:$PAGER_SSH_PORT"
say "[*] State file: $STATE_FILE"

if [ "$DRY_RUN" = 1 ]; then
  say ""
  say "[dry-run] Validating repository tarball..."
  if tar_create_repo "$TMP_DIR/repo-dryrun.tar.gz"; then
    say "[dry-run] Tarball OK: $(du -h "$TMP_DIR/repo-dryrun.tar.gz" | awk '{print $1}')"
    say "[dry-run] Top-level contents:"
    tar -tzf "$TMP_DIR/repo-dryrun.tar.gz" | awk -F/ 'NF <= 2 {print "          " $0}' | sort -u | head -n 40
  else
    die "Tarball creation failed."
  fi
  say ""
  say "[dry-run] Generated Pager bootstrap:"
  SELECTION="${SELECTION:-C}"
  RUN_ID="dryrun-$(now_id)"
  make_bootstrap "$TMP_DIR/bootstrap-dryrun.sh"
  sed 's/^/          /' "$TMP_DIR/bootstrap-dryrun.sh"
  say ""
  say "[dry-run] No Pager was contacted."
  exit 0
fi

state_init
main_loop
