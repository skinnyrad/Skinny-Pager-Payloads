#!/bin/sh
# v28_dryrun.sh — read-only sanity check for v28_run.py.
#
# Runs every UCI / bridge / firewall / dnsmasq probe the orchestrator would
# run, but in dry-run mode: it just reports what it WOULD do. No mutations.
#
# Exit codes:
#   0  -> all checks pass; orchestrator run would be safe
#   1  -> some pre-condition fails; orchestrator would refuse to run
#   2  -> critical environment problem (no wpad swap candidate, etc.)

set -u

PASS=0
FAIL=0
WARN=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }

hr() { printf '\n=== %s ===\n' "$*"; }

# 1. SSH source check (we can't reliably check from the Pager side; this
#    checks instead that the script's caller can be identified)
hr "1. SSH source / connection source"
client_ip=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $1}')
if [ -z "$client_ip" ]; then
    pass "not an SSH session (local / tmux / payload UI)"
else
    SRC_IF=$(ip route get "$client_ip" 2>/dev/null | head -1)
    case "$SRC_IF" in
        *"dev wlan"*|*"dev wl"*)
            fail "SSH arrives over WiFi ($SRC_IF) — wifi reload will drop the session"
            fail "Reconnect over USB-C Ethernet (br-lan) or run from on-Pager tmux"
            fail "Set ATT_FORCE_WLAN0CLI=1 to override (NOT recommended)"
            ;;
        *)
            pass "SSH source is wired/local: $(echo "$SRC_IF" | head -c 80)"
            ;;
    esac
fi

# 2. wpad swap engine + staged wolfssl assets
hr "2. wpad swap engine + assets"

# Resolve the shared engine the same way v28_run.py does.
WPAD_SWAP="${WPAD_SWAP:-}"
[ -z "$WPAD_SWAP" ] && [ -x /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh ] && \
    WPAD_SWAP=/mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh
[ -z "$WPAD_SWAP" ] && [ -x /root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh ] && \
    WPAD_SWAP=/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh

if [ -n "$WPAD_SWAP" ] && [ -x "$WPAD_SWAP" ]; then
    pass "wpad-swap engine present: $WPAD_SWAP"
else
    fail "wpad-swap engine MISSING (expected /mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh)"
fi

STAGE=/mmc/root/wpad-swap
for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl libwolfssl.so.5.9.1.e624513f; do
    if [ -f "$STAGE/$f" ]; then
        pass "staged: $f ($(sha256sum "$STAGE/$f" | cut -c1-16)…)"
    else
        fail "staged asset MISSING: $STAGE/$f — run: wpad-swap.sh stage"
    fi
done

if [ -f /usr/lib/libwolfssl.so.5.9.1.e624513f ]; then
    pass "libwolfssl installed at /usr/lib/libwolfssl.so.5.9.1.e624513f"
else
    fail "libwolfssl NOT installed — run: wpad-swap.sh stage"
fi

# The stock file must be untouched on disk (that is the whole safety model).
wpad_disk_sha=$(sha256sum /usr/sbin/wpad 2>/dev/null | cut -d' ' -f1)
if [ "$wpad_disk_sha" = "810d224edc4052aeb80fd4f6439857faba3065f8f6b01e968b952c5a95d81317" ]; then
    pass "/usr/sbin/wpad on disk is the factory wpad-basic-mbedtls (untouched)"
elif mount | grep -q "on /usr/sbin/wpad "; then
    warn "/usr/sbin/wpad has a wolfssl overlay mounted (run: wpad-swap.sh stock)"
else
    fail "/usr/sbin/wpad is neither factory nor a known overlay (sha $wpad_disk_sha)"
fi

# 3. Radio state
hr "3. Radio state"
radio_mac=$(cat /sys/class/ieee80211/phy0/macaddress 2>/dev/null || echo MISSING)
if [ "$radio_mac" = "MISSING" ]; then
    fail "cannot read /sys/class/ieee80211/phy0/macaddress"
else
    first=$(echo "$radio_mac" | cut -d: -f1)
    if [ $((0x$first & 0x02)) -ne 0 ]; then
        fail "radio MAC $radio_mac is locally-administered (first octet $first); iOS will filter BSSID"
    else
        pass "radio MAC $radio_mac is universally-administered (first octet $first)"
    fi
fi

# 4. UCI check: wlan0open / wlan0wpa config
hr "4. UCI: wlan0open / wlan0wpa"
wlan0open_disabled=$(uci -q get wireless.wlan0open.disabled)
wlan0wpa_disabled=$(uci -q get wireless.wlan0wpa.disabled)
wlan0wpa_auth=$(uci -q get wireless.wlan0wpa.auth_server)
wlan0wpa_iw=$(uci -q get wireless.wlan0wpa.iw_enabled)
wlan0wpa_hs20=$(uci -q get wireless.wlan0wpa.hs20)

if [ "$wlan0open_disabled" = "0" ]; then
    pass "wlan0open is enabled in UCI"
else
    warn "wlan0open is disabled in UCI (orchestrator will enable)"
fi
if [ "$wlan0wpa_disabled" = "0" ]; then
    pass "wlan0wpa is enabled in UCI"
else
    warn "wlan0wpa is disabled in UCI (orchestrator will enable for pseudonym/both/hybrid modes)"
fi
if [ -n "$wlan0wpa_auth" ]; then
    pass "wlan0wpa auth_server is set: $wlan0wpa_auth"
else
    warn "wlan0wpa auth_server is empty (pseudonym mode will set 127.0.0.1:1812)"
fi
if [ "$wlan0wpa_iw" = "1" ]; then
    pass "wlan0wpa iw_enabled=1"
else
    warn "wlan0wpa iw_enabled is not 1 (orchestrator will set)"
fi
if [ "$wlan0wpa_hs20" = "1" ]; then
    pass "wlan0wpa hs20=1"
else
    warn "wlan0wpa hs20 is not 1 (orchestrator will set)"
fi

# 5. DNS / DHCP
hr "5. dnsmasq / odhcpd"
dnsmasq_local=$(uci -q get dhcp.@dnsmasq[0].localise_queries)
if [ "$dnsmasq_local" = "1" ]; then
    pass "dnsmasq has localise_queries=1 (bind-dynamic local-service equivalent)"
else
    warn "dnsmasq localise_queries is $dnsmasq_local (orchestrator will use address=/ override)"
fi
odhcpd_main=$(uci -q get dhcp.@odhcpd[0].maindhcp)
if [ "$odhcpd_main" = "0" ]; then
    pass "odhcpd maindhcp=0 (dnsmasq is the main DHCP server)"
else
    warn "odhcpd maindhcp=$odhcpd_main (orchestrator uses v28_dhcpd.py on 192.168.99.1)"
fi

# 6. Firewall state
hr "6. Firewall"
wan_masq=$(uci -q get firewall.@zone[1].masq)
if [ "$wan_masq" = "1" ]; then
    pass "firewall wan zone has masq=1 (NAT automatic for wlan0open/wlan0wpa members)"
else
    fail "firewall wan zone has masq='$wan_masq' — connection-mode internet bridging will fail"
fi

# 7. Bridge state
hr "7. Bridge state"
brlan_ports=$(uci -q get network.brlan.ports)
if echo "$brlan_ports" | grep -q wlan0open && echo "$brlan_ports" | grep -q wlan0wpa; then
    pass "br-lan includes wlan0open + wlan0wpa"
else
    warn "br-lan ports: $brlan_ports"
fi

# 8. v28 scripts present
hr "8. v28 deployment"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for s in v28_run.py v28_run.sh v28_dhcpd.py v28_ie221.py v28_wispr.py \
         v28_isolate.sh v28_nat.sh radius-reject.py; do
    if [ -f "$SCRIPT_DIR/$s" ]; then
        pass "$s present"
    else
        fail "$s MISSING"
    fi
done

# Summary
hr "Summary"
printf '  PASS: %d   FAIL: %d   WARN: %d\n\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
    printf 'DRYRUN FAIL: %d blocking issue(s). Resolve before running v28_run.py.\n' "$FAIL"
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    printf 'DRYRUN OK (with %d warning(s)). Orchestrator will auto-fix warnings on entry.\n' "$WARN"
    exit 0
fi
printf 'DRYRUN OK. Ready to run.\n'
exit 0
