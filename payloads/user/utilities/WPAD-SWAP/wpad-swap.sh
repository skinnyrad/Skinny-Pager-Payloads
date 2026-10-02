#!/bin/sh
# wpad-swap.sh -- non-destructive hostapd/wpad hot-swap engine for the
# Hak5 WiFi Pineapple Pager.
#
# WHY THIS EXISTS
#   The factory Pager ships with Hak5's patched wpad-basic-mbedtls. The
#   ATT-Hotspot2 / Passpoint payloads need wpad-wolfssl's compiled-in
#   Hotspot2.0 / Interworking / EAP-AKA / EAP-SIM support. Installing
#   wpad-wolfssl via opkg would remove the factory package (it Conflicts:),
#   breaking stock Pager/PineAP functionality.
#
# HOW IT WORKS
#   The stock /usr/sbin/wpad file is NEVER modified on disk. Instead the
#   wolfssl binary set is staged under /mmc/root/wpad-swap/ and, while
#   "wolfssl" mode is active, bind-mounted over the three paths the Pager
#   actually executes:
#
#       /usr/sbin/wpad           (real file, 790 KB stock)
#       /usr/sbin/hostapd        (symlink -> wpad)
#       /usr/sbin/wpa_supplicant (symlink -> wpad)
#
#   All three are overlaid because wpad dispatches on argv[0] and the Pager
#   resolves hostapd/wpa_supplicant as symlinks to /usr/sbin/wpad. Overlaying
#   only /usr/sbin/wpad leaves the running hostapd/wpa_supplicant as the old
#   binary, which then rejects Passpoint IEs as "unknown configuration".
#
#   The `wpad` procd service is restarted so both processes re-exec under the
#   overlaid binary, then `wifi up` restores the interfaces. wlan0cli (the
#   managed uplink) comes back up automatically once hostapd succeeds.
#
# SAFETY MODEL
#   - Bind mounts do not survive a reboot: rebooting ALWAYS returns the Pager
#     to the factory wpad. This is the ultimate failsafe.
#   - `run` wraps a command with an EXIT/INT/TERM/HUP trap that always
#     restores stock, so a payload that crashes cannot strand wolfssl mode.
#   - Every flip hash-verifies the running hostapd/wpa_supplicant against the
#     expected binary and auto-rolls-back to stock on mismatch.
#   - Restoring stock is fully self-healing: `recover` force-unmounts any
#     stray overlays (even leftover from a crashed previous run) and restarts
#     the wpad service.
#
# USAGE
#   wpad-swap.sh stage              extract + verify the wolfssl asset set
#   wpad-swap.sh status             show stock/active/running state
#   wpad-swap.sh wolfssl            activate wolfssl (idempotent)
#   wpad-swap.sh stock              restore factory wpad (idempotent)
#   wpad-swap.sh run -- <command>   activate, run, ALWAYS restore stock
#   wpad-swap.sh recover            force-restore factory state
#   wpad-swap.sh --help
#
# The engine refuses to touch the radio when the active shell's own traffic
# arrives over a WiFi interface (a `wpad` restart would drop the session).
# SSH in over USB-C Ethernet (br-lan), serial, or run it in on-Pager tmux.

set -eu

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
WPAD_PATH=/usr/sbin/wpad
HOSTAPD_PATH=/usr/sbin/hostapd
SUPPLICANT_PATH=/usr/sbin/wpa_supplicant
WPAD_DIR=/usr/sbin

STAGE_DIR=/mmc/root/wpad-swap
LOOT_DIR=/mmc/root/loot/wpad-swap
MANIFEST="$STAGE_DIR/MANIFEST.sha256"

WPAD_WOLFSSL="$STAGE_DIR/wpad-wolfssl"
HOSTAPD_WOLFSSL="$STAGE_DIR/hostapd-wolfssl"
SUPPLICANT_WOLFSSL="$STAGE_DIR/wpa_supplicant-wolfssl"
LIB_WOLFSSL="$STAGE_DIR/libwolfssl.so.5.9.1.e624513f"

LIB_DEST=/usr/lib/libwolfssl.so.5.9.1.e624513f

# Expected hashes (see cross-compiled-pager-tools/wpad-wolfssl/SHA256SUMS)
STOCK_SHA=810d224edc4052aeb80fd4f6439857faba3065f8f6b01e968b952c5a95d81317
WOLFSSL_SHA=d958be658486bf0637aabbb859230895bae93aff22ec519bdd45c93e4c029f14
LIB_SHA=f3e25b79294dd3088f5aef716e89d9350be1552283d3ce2cae3593d7202ef5cd

FORCE=0

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
log()  { printf '[wpad-swap] %s\n' "$*"; }
warn() { printf '[wpad-swap] WARN: %s\n' "$*" >&2; }
fail() { printf '[wpad-swap] ERROR: %s\n' "$*" >&2; exit 2; }

sha_of() {
    [ -e "$1" ] || { printf 'missing'; return; }
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

is_mounted() {
    # Exact mountpoint match against /proc/mounts (field 2), more reliable than
    # parsing busybox `mount` output.
    awk -v p="$1" '$2 == p {found=1} END {exit !found}' /proc/mounts 2>/dev/null
}

hostapd_pid()  { pidof hostapd 2>/dev/null | awk '{print $1}'; }
supp_pid()     { pidof wpa_supplicant 2>/dev/null | awk '{print $1}'; }
exe_sha()      { [ -n "${1:-}" ] && sha256sum "/proc/$1/exe" 2>/dev/null | awk '{print $1}'; }

logdir() {
    mkdir -p "$LOOT_DIR" 2>/dev/null || true
}

# The currently-active wpad binary as seen by the running hostapd.
active_sha() {
    local pid; pid=$(hostapd_pid)
    [ -n "$pid" ] && exe_sha "$pid" || printf 'none'
}

# mode is derived from the LIVE running binary, not just mount state, so a
# half-restored state is reported honestly (and triggers a corrective flip).
current_mode() {
    local a
    a=$(active_sha)
    if [ "$a" = "$WOLFSSL_SHA" ]; then
        printf 'wolfssl'
    elif [ "$a" = "$STOCK_SHA" ]; then
        printf 'stock'
    elif is_mounted "$WPAD_PATH"; then
        printf 'wolfssl'
    else
        printf 'stock'
    fi
}

# ----------------------------------------------------------------------------
# safety: refuse to restart the radio over a WiFi SSH session
# ----------------------------------------------------------------------------
ssh_over_wifi() {
    # SSH_CONNECTION: "<client-ip> <client-port> <server-ip> <server-port>"
    local cip
    cip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')
    [ -z "$cip" ] && return 1              # not an SSH session (e.g. local tmux)
    local dev
    dev=$(ip route get "$cip" 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$dev" in
        wlan*|wl*) return 0 ;;             # traffic arrives over WiFi
        *)         return 1 ;;
    esac
}

assert_safe_shell() {
    if ssh_over_wifi && [ "$FORCE" != "1" ]; then
        fail "your SSH session arrives over a WiFi interface; restarting wpad would DISCONNECT you.
       Use USB-C Ethernet (br-lan), serial console, or on-Pager tmux.
       Override with: FORCE=1 $0 <action>"
    fi
}

# ----------------------------------------------------------------------------
# stage: put the wolfssl asset set on disk and verify it
# ----------------------------------------------------------------------------
# Accepts a directory of pre-extracted assets (used by the installer) via
# WPAD_SRC, or already-staged files copied in manually.
do_stage() {
    mkdir -p "$STAGE_DIR"

    local need=""
    [ -f "$WPAD_WOLFSSL" ]     || need="$need wpad-wolfssl"
    [ -f "$HOSTAPD_WOLFSSL" ]  || need="$need hostapd-wolfssl"
    [ -f "$SUPPLICANT_WOLFSSL" ] || need="$need wpa_supplicant-wolfssl"
    [ -f "$LIB_WOLFSSL" ]      || need="$need libwolfssl.so.5.9.1.e624513f"

    if [ -n "$need" ]; then
        if [ -n "${WPAD_SRC:-}" ] && [ -d "${WPAD_SRC:-}" ]; then
            log "staging from $WPAD_SRC"
            for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl \
                     libwolfssl.so.5.9.1.e624513f; do
                [ -f "$WPAD_SRC/$f" ] && cp "$WPAD_SRC/$f" "$STAGE_DIR/$f"
            done
        else
            fail "missing staged asset(s):$need
       copy the wpad-wolfssl asset set into $STAGE_DIR first
       (or run: WPAD_SRC=<dir> $0 stage)"
        fi
    fi

    chmod 755 "$WPAD_WOLFSSL" "$HOSTAPD_WOLFSSL" "$SUPPLICANT_WOLFSSL" 2>/dev/null || true
    chmod 644 "$LIB_WOLFSSL" 2>/dev/null || true

    local rc=0
    [ "$(sha_of "$WPAD_WOLFSSL")" = "$WOLFSSL_SHA" ]         || { warn "wpad-wolfssl hash mismatch: $(sha_of "$WPAD_WOLFSSL")"; rc=1; }
    [ "$(sha_of "$HOSTAPD_WOLFSSL")" = "$WOLFSSL_SHA" ]      || { warn "hostapd-wolfssl hash mismatch"; rc=1; }
    [ "$(sha_of "$SUPPLICANT_WOLFSSL")" = "$WOLFSSL_SHA" ]   || { warn "wpa_supplicant-wolfssl hash mismatch"; rc=1; }
    [ "$(sha_of "$LIB_WOLFSSL")" = "$LIB_SHA" ]              || { warn "libwolfssl hash mismatch"; rc=1; }

    if [ "$rc" = "0" ]; then
        # Install libwolfssl additively so wolfssl mode has its dependency.
        if [ "$(sha_of "$LIB_DEST")" != "$LIB_SHA" ]; then
            log "installing $LIB_DEST (additive, inert for stock wpad)"
            cp "$LIB_WOLFSSL" "$LIB_DEST"
            chmod 755 "$LIB_DEST"
            ldconfig 2>/dev/null || true
        fi
        {
            printf '%s  %s\n' "$WOLFSSL_SHA" "wpad-wolfssl"
            printf '%s  %s\n' "$WOLFSSL_SHA" "hostapd-wolfssl"
            printf '%s  %s\n' "$WOLFSSL_SHA" "wpa_supplicant-wolfssl"
            printf '%s  %s\n' "$LIB_SHA"     "libwolfssl.so.5.9.1.e624513f"
        } > "$MANIFEST"
        log "stage OK"
    else
        fail "stage verification failed"
    fi
}

# ----------------------------------------------------------------------------
# status
# ----------------------------------------------------------------------------
do_status() {
    printf '=== wpad-swap status ===\n'
    printf '  mode            : %s\n' "$(current_mode)"
    printf '  on-disk wpad    : %s  (%s)\n' "$WPAD_PATH" "$(sha_of "$WPAD_PATH")"
    local a; a=$(active_sha)
    printf '  running hostapd : pid=%s sha=%s\n' "$(hostapd_pid)" "$a"
    local s; s=$(supp_pid)
    printf '  running supplic. : pid=%s sha=%s\n' "$s" "$(exe_sha "$s")"

    case "$a" in
        "$STOCK_SHA")  printf '  -> factory wpad-basic-mbedtls\n' ;;
        "$WOLFSSL_SHA") printf '  -> wpad-wolfssl (Passpoint capable)\n' ;;
        none)          printf '  -> hostapd not running\n' ;;
        *)             printf '  -> UNKNOWN build %s\n' "$a" ;;
    esac

    printf '\n=== staged assets (%s) ===\n' "$STAGE_DIR"
    for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl libwolfssl.so.5.9.1.e624513f; do
        if [ -f "$STAGE_DIR/$f" ]; then
            printf '  %-30s %s\n' "$f" "$(sha_of "$STAGE_DIR/$f")"
        else
            printf '  %-30s MISSING\n' "$f"
        fi
    done
    printf '  libwolfssl installed at %s : %s\n' "$LIB_DEST" "$(sha_of "$LIB_DEST")"

    printf '\n=== overlays ===\n'
    mount 2>/dev/null | grep "/usr/sbin/" || printf '  (none)\n'
}

# ----------------------------------------------------------------------------
# flip primitives
# ----------------------------------------------------------------------------
restart_wpad() {
    # (Re)start the procd wpad service so hostapd + wpa_supplicant exec under
    # whatever /usr/sbin/{wpad,hostapd,wpa_supplicant} currently resolve to.
    # We may have deleted the procd instance in kill_wpad_procs(), so `start`
    # (rather than `restart`) is the reliable op here.
    /etc/init.d/wpad start >/dev/null 2>&1 || /etc/init.d/wpad restart >/dev/null 2>&1 || true
    sleep 3
    # Bring the radio back (hostapd re-adds the AP BSSs; wlan0cli re-associates).
    wifi up >/dev/null 2>&1 || true
}

kill_wpad_procs() {
    # Stop the procd service first so it does NOT respawn hostapd underneath us
    # while we are trying to umount the overlay (a kill alone makes procd
    # immediately restart it, which keeps the overlay path busy).
    /etc/init.d/wpad stop >/dev/null 2>&1 || true
    ubus call service delete '{"name":"wpad"}' >/dev/null 2>&1 || true

    local pid i
    pid=$(hostapd_pid);  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    pid=$(supp_pid);     [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 10 ]; do
        [ -z "$(hostapd_pid)" ] && [ -z "$(supp_pid)" ] && break
        sleep 1; i=$((i + 1))
    done
    pid=$(hostapd_pid);  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    pid=$(supp_pid);     [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
    sleep 1
}

overlay_up() {
    is_mounted "$WPAD_PATH" && return 0
    log "bind-mounting wolfssl over $WPAD_PATH, $HOSTAPD_PATH, $SUPPLICANT_PATH"
    mount --bind "$WPAD_WOLFSSL" "$WPAD_PATH"       || fail "bind mount $WPAD_PATH failed"
    mount --bind "$HOSTAPD_WOLFSSL" "$HOSTAPD_PATH" || { umount "$WPAD_PATH" 2>/dev/null; fail "bind mount $HOSTAPD_PATH failed"; }
    mount --bind "$SUPPLICANT_WOLFSSL" "$SUPPLICANT_PATH" || { umount "$HOSTAPD_PATH" 2>/dev/null; umount "$WPAD_PATH" 2>/dev/null; fail "bind mount $SUPPLICANT_PATH failed"; }
}

overlay_down() {
    local m n
    for m in "$SUPPLICANT_PATH" "$HOSTAPD_PATH" "$WPAD_PATH"; do
        # Loop: stacked/lazy bind mounts can leave more than one layer on the
        # same mountpoint, and one umount only peels one layer.
        n=0
        while is_mounted "$m" && [ "$n" -lt 10 ]; do
            log "unmounting $m"
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || { warn "could not unmount $m"; break; }
            n=$((n + 1))
        done
    done
}

verify_active() {
    # return 0 iff hostapd AND wpa_supplicant are running the expected binary.
    local want="$1" hp sp
    hp=$(hostapd_pid); sp=$(supp_pid)
    [ -n "$hp" ] || return 1
    [ "$(exe_sha "$hp")" = "$want" ] || return 1
    [ -z "$sp" ] || [ "$(exe_sha "$sp")" = "$want" ] || return 1
    return 0
}

wait_active() {
    # poll up to ~20s for the expected binary to be live
    local want="$1" i
    for i in $(seq 1 20); do
        verify_active "$want" && return 0
        sleep 1
    done
    return 1
}

do_wolfssl() {
    assert_safe_shell
    [ -f "$WPAD_WOLFSSL" ] || fail "wolfssl assets not staged; run: $0 stage"
    # Self-heal: if assets are staged but libwolfssl was never installed (e.g.
    # a prior install step was interrupted), re-run stage to install it.
    if [ "$(sha_of "$LIB_DEST")" != "$LIB_SHA" ]; then
        log "libwolfssl not installed; running stage to install it"
        do_stage
    fi

    if [ "$(current_mode)" = "wolfssl" ] && verify_active "$WOLFSSL_SHA"; then
        log "already in wolfssl mode (no-op)"
        return 0
    fi

    log "activating wolfssl (Passpoint capable)"
    # Kill the live processes first (releases the path), then overlay, then restart.
    kill_wpad_procs
    overlay_up
    restart_wpad

    if wait_active "$WOLFSSL_SHA"; then
        log "wolfssl active (hostapd sha=$(active_sha))"
        return 0
    fi

    warn "hostapd did not come up under wolfssl (active=$(active_sha)); rolling back to stock"
    do_stock_internal
    fail "wolfssl activation failed; restored factory wpad"
}

do_stock_internal() {
    # no safety check -- used both by `stock` and by the wolfssl rollback path.
    # ORDER MATTERS: the live hostapd/wpa_supplicant processes hold the overlay
    # mountbusy (their /proc/<pid>/exe points into it), so they MUST be killed
    # BEFORE we can umount. An umount attempt against a running hostapd fails
    # with EBUSY and a lazy umount leaves the mount visible.
    log "restoring factory wpad"
    kill_wpad_procs
    sleep 1
    overlay_down
    restart_wpad

    # Guard: the on-disk wpad must be the factory file before we call it done.
    local disk; disk=$(sha_of "$WPAD_PATH")
    if [ "$disk" != "$STOCK_SHA" ]; then
        warn "on-disk $WPAD_PATH is $disk (expected stock $STOCK_SHA) -- is an overlay still mounted?"
    fi

    if wait_active "$STOCK_SHA"; then
        log "stock wpad active (hostapd sha=$(active_sha))"
        return 0
    fi
    warn "hostapd not verified as stock yet (active=$(active_sha)); on-disk wpad is $disk"
    return 1
}

do_stock() {
    assert_safe_shell
    if [ "$(current_mode)" = "stock" ] && verify_active "$STOCK_SHA"; then
        log "already in stock mode (no-op)"
        return 0
    fi
    do_stock_internal
}

do_recover() {
    # Force-restore, no safety check. Idempotent. Always unmounts + restarts.
    log "recover: forcing factory wpad state"
    kill_wpad_procs
    overlay_down
    restart_wpad
    if wait_active "$STOCK_SHA"; then
        log "recover complete: hostapd sha=$(active_sha)"
    else
        warn "recover: hostapd not verified (active=$(active_sha)); reboot if the radio is stuck"
    fi
    do_status
}

# ----------------------------------------------------------------------------
# run: activate wolfssl around an arbitrary command, ALWAYS restore stock
# ----------------------------------------------------------------------------
do_run() {
    [ "${1:-}" = "--" ] && shift
    [ "$#" -gt 0 ] || fail "usage: $0 run -- <command> [args...]"

    logdir
    local logfile="$LOOT_DIR/$(date +%Y%m%d-%H%M%S)-run.log"
    local restored=0

    restore_once() {
        [ "$restored" = "1" ] && return 0
        restored=1
        log "run finished; restoring stock" | tee -a "$logfile" >&2 || true
        do_stock_internal >>"$logfile" 2>&1 || true
    }

    trap 'restore_once; exit 130' INT
    trap 'restore_once; exit 143' TERM
    trap 'restore_once; exit 129' HUP
    trap 'restore_once' EXIT

    do_wolfssl
    log "running: $*" | tee -a "$logfile"
    local rc=0
    "$@" 2>&1 | tee -a "$logfile" || rc=$?
    log "command exited rc=$rc" | tee -a "$logfile" >&2 || true

    restore_once
    trap - INT TERM HUP EXIT
    return "$rc"
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
ACTION="${1:-}"
shift 2>/dev/null || true
for a in "$@"; do
    case "$a" in
        --force|-f) FORCE=1 ;;
        --yes|-y)   : ;;
        --help|-h)  ACTION=help ;;
    esac
done

case "$ACTION" in
    stage)   do_stage ;;
    status)  do_status ;;
    wolfssl) do_wolfssl ;;
    stock)   do_stock ;;
    run)     do_run "$@" ;;
    recover) do_recover ;;
    help|--help|-h)
        cat <<'USAGE'
wpad-swap.sh -- non-destructive wpad/hostapd hot-swap for the Pineapple Pager

Usage:
  wpad-swap.sh stage            extract + verify the wolfssl asset set
  wpad-swap.sh status           show stock/active/running state
  wpad-swap.sh wolfssl          activate wpad-wolfssl (Passpoint capable)
  wpad-swap.sh stock            restore factory wpad-basic-mbedtls
  wpad-swap.sh run -- <cmd>     activate, run <cmd>, ALWAYS restore stock
  wpad-swap.sh recover          force-restore factory state (self-healing)

Flags:
  --force, -f    override the "don't run this over WiFi SSH" guard

Env:
  WPAD_SRC=<dir>   stage assets from <dir> (installer path)
  FORCE=1          same as --force

Safety:
  The stock /usr/sbin/wpad file is never modified. wolfssl is bind-mounted
  over /usr/sbin/{wpad,hostapd,wpa_supplicant} only while active. A reboot
  always returns the Pager to factory wpad.
USAGE
        ;;
    *) fail "usage: $0 {stage|status|wolfssl|stock|run|recover|--help}" ;;
esac
