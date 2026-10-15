#!/usr/bin/env python3
# awdl_log.py - passive AWDL cluster observer -> loot log.
#
# Correlates, per device seen over AWDL:
#   MAC (flagged "(R)" if randomized/locally-administered)  <->  IPv6  <->  RSSI
#   <->  mDNS/Bonjour names, service types and TXT identifiers
#     (e.g. companion-link CLink-<hash>, _airplay-p2p "<id>@<Name>",
#      TXT sn=com.apple.sharingd.AirDrop dnm=<name> rpBA=<BT addr> rpVr=<ver>)
#
# Sources: owl's log (PSF/MIF RSSI + Arpa name), the awdl0 neighbor table
# (MAC<->IPv6), and passive mDNS on awdl0.
#
# Usage: awdl_log.py [iface] [owl_log_path]
# Loot : /root/loot/awdl/YYYYMMDD-awdl.log
#   TS | NAME | MAC | IPv6 | RSSI | SERVICES | TXT
import sys, os, time, subprocess, socket, re, logging
from collections import OrderedDict
from scapy.all import DNS, DNSRR, IPv6, AsyncSniffer, conf
conf.verb = 0
logging.getLogger("scapy.runtime").setLevel(logging.ERROR)

IFACE = sys.argv[1] if len(sys.argv) > 1 else "awdl0"
OWLLOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/owl.log"
LOOTDIR = "/root/loot/awdl"
os.makedirs(LOOTDIR, exist_ok=True)
LOGFILE = os.path.join(LOOTDIR, time.strftime("%Y%m%d") + "-awdl.log")
# Re-log an active device every COOLDOWN seconds (so alerts recur while it's seen),
# instead of only once per session. Override with env AWDL_COOLDOWN.
COOLDOWN = float(os.environ.get("AWDL_COOLDOWN", "15"))
ACTIVE = float(os.environ.get("AWDL_ACTIVE", "20"))  # heard within N s => still active

D = {}            # mac -> record
_logged = set()

def sh(c):
    try:
        return subprocess.check_output(c, shell=True, stderr=subprocess.DEVNULL).decode()
    except Exception:
        return ""

def rand_mac(m):
    try:
        return bool(int(m.split(':')[0], 16) & 2)
    except Exception:
        return False

def ip6_to_mac(ip):
    try:
        b = socket.inet_pton(socket.AF_INET6, ip.split('%')[0])
        if b[8:11] == b'\xff\xfe':
            return "%02x:%02x:%02x:%02x:%02x:%02x" % (b[8] ^ 2, b[9], b[10], b[13], b[14], b[15])
    except Exception:
        pass
    return None

def mac_to_ip6(mac):
    try:
        o = [int(x, 16) for x in mac.split(':')]
        o[0] ^= 2
        return "fe80::%02x%02x:%02xff:fe%02x:%02x%02x" % (o[0], o[1], o[2], o[3], o[4], o[5])
    except Exception:
        return None

def dev(mac):
    if not mac:
        return None
    return D.setdefault(mac, {'ipv6': None, 'rssi': None, 'arname': '',
                              'svc': set(), 'inst': set(), 'txt': OrderedDict(),
                              'last_seen': 0})

def poll_neigh():
    for line in sh("ip -6 neigh show dev %s" % IFACE).splitlines():
        p = line.split()
        if len(p) >= 3 and p[1] == "lladdr":
            d = dev(p[2].lower())
            d['ipv6'] = p[0].split('%')[0]

OWL_OFF = 0

def poll_owl():
    global OWL_OFF
    try:
        lines = open(OWLLOG, 'r', errors='replace').read().splitlines()
    except Exception:
        return
    if len(lines) < OWL_OFF:      # log rotated/truncated (owl restarted)
        OWL_OFF = 0
    now = time.time()
    for ln in lines[OWL_OFF:]:
        m = re.search(r'receive (?:PSF|MIF) from ([0-9A-Fa-f:]{17}) \(rssi (-?\d+)\)', ln)
        if m:
            d = dev(m.group(1).lower()); d['rssi'] = int(m.group(2)); d['last_seen'] = now
            continue
        m = re.search(r'add peer ([0-9A-Fa-f:]{17}) \(([^)]*)\)', ln)
        if m:
            d = dev(m.group(1).lower()); d['last_seen'] = now
            if m.group(2):
                d['arname'] = m.group(2)
    OWL_OFF = len(lines)

def mdns(p):
    if not p.haslayer(DNS) or p[DNS].qr != 1 or not p.haslayer(IPv6):
        return
    src = p[IPv6].src.split('%')[0]
    mac = ip6_to_mac(src)
    if not mac:
        return
    d = dev(mac)
    d['last_seen'] = time.time()
    if not d['ipv6']:
        d['ipv6'] = src
    for sect in (p[DNS].an, p[DNS].ar):
        rr = sect; n = 0
        while rr is not None and hasattr(rr, 'rrname') and n < 60:
            t = rr.type
            if t == 12:
                try:
                    v = rr.rdata.decode(errors='replace') if isinstance(rr.rdata, bytes) else str(rr.rdata)
                except Exception:
                    v = str(rr.rdata)
                d['inst'].add(v)
                d['svc'].add(v.split('._')[0] + '._' + v.split('._')[1] if '._' in v else v)
            elif t == 16:
                items = rr.rdata if isinstance(rr.rdata, list) else [rr.rdata]
                for it in items:
                    s = it.decode(errors='replace') if isinstance(it, bytes) else str(it)
                    if '=' in s:
                        k, v = s.split('=', 1); d['txt'][k] = v
            rr = getattr(rr, 'payload', None); n += 1

def friendly_name(d):
    # airplay-p2p / airplay instance "<id>@<Real Name>"
    for v in sorted(d['inst']):
        m = re.match(r'[0-9A-Fa-f]+@(.+?)\._(airplay|raop|airplay-p2p)', v)
        if m:
            return m.group(1)
    for k in ('dnm', 'name'):
        if d['txt'].get(k):
            return d['txt'][k]
    # NOTE: owl's Arpa name is a random UUID -> never use it as a device name.
    return ""

_sig = {}
_lastlog = {}

def log_new():
    now = time.time()
    for mac, d in list(D.items()):
        if not (d.get('ipv6') or d['arname'] or d['svc'] or d['txt'] or d['rssi'] is not None):
            continue
        name = friendly_name(d) or ("random MAC" if rand_mac(mac) else "unknown")
        maclab = mac + (" (R)" if rand_mac(mac) else "")
        ipv6 = d.get('ipv6') or mac_to_ip6(mac) or "-"
        svc = ",".join(sorted(s for s in d['svc'])) or "-"
        txt = " ".join(("%s=%s" % (k, v)) if v else k for k, v in d['txt'].items()) or "-"
        sig = (name, ipv6, svc, txt)
        # log on first sight / identity change, or every COOLDOWN seconds WHILE the
        # device is still actively transmitting (heard within ACTIVE seconds)
        changed = _sig.get(mac) != sig
        due = (now - _lastlog.get(mac, 0)) >= COOLDOWN
        active = (now - d.get('last_seen', 0)) <= ACTIVE
        if not (changed or (due and active)):
            continue
        _sig[mac] = sig
        _lastlog[mac] = now
        line = "%s | %s | %s | %s | %s | %s | %s" % (
            time.strftime("%Y-%m-%d %H:%M:%S"), name, maclab, ipv6,
            d['rssi'] if d['rssi'] is not None else "-", svc, txt)
        try:
            with open(LOGFILE, 'a') as f:
                f.write(line + "\n")
        except Exception:
            pass
        print(line, flush=True)

def main():
    print("[*] awdl_log iface=%s loot=%s" % (IFACE, LOGFILE), flush=True)
    sn = AsyncSniffer(iface=IFACE, filter="udp and port 5353", prn=mdns, store=0)
    sn.start()
    try:
        while True:
            # keep the loot file present even if it gets deleted mid-run
            try:
                open(LOGFILE, 'a').close()
            except Exception:
                pass
            poll_neigh(); poll_owl(); log_new()
            time.sleep(2)
    except KeyboardInterrupt:
        pass
    finally:
        sn.stop()

if __name__ == "__main__":
    main()
