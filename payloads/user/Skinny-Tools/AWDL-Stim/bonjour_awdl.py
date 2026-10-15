#!/usr/bin/env python3
# bonjour_awdl.py - recursive DNS-SD (Bonjour) enumerator over an AWDL interface.
# Walks: _services._dns-sd._udp -> service types -> instances -> SRV/TXT/AAAA,
# while also passively capturing all mDNS on the link. Prints a per-instance table.
#
# Usage:  python3 bonjour_awdl.py [iface] [listen_secs] [-v]
import sys, time, socket, subprocess, logging
from collections import defaultdict, OrderedDict
from scapy.all import Ether, IPv6, UDP, DNS, DNSQR, sendp, AsyncSniffer, conf
conf.verb = 0
logging.getLogger("scapy.runtime").setLevel(logging.ERROR)

argv = [a for a in sys.argv[1:] if a != "-v"]
VERBOSE = "-v" in sys.argv
iface = argv[0] if len(argv) > 0 else "awdl0"
listen = float(argv[1]) if len(argv) > 1 else 45.0

MCAST = "ff02::fb"
MCAST_MAC = "33:33:00:00:00:fb"

def if_ll():
    return subprocess.check_output(
        "ip -6 addr show dev %s | awk '/inet6/{print $2}'|cut -d/ -f1|head -1" % iface,
        shell=True).decode().strip()

SRC = if_ll()

services = set()
inst_type = {}
ptr = defaultdict(set)
srv = {}
txt = defaultdict(OrderedDict)
aaaa = defaultdict(set)
a = defaultdict(set)
sources = defaultdict(set)
hosts = set()
raw_lines = []

def ip6(rd):
    try:
        return socket.inet_ntop(socket.AF_INET6, rd) if isinstance(rd, (bytes, bytearray)) and len(rd) == 16 else str(rd)
    except Exception:
        return str(rd)

def ip4(rd):
    try:
        return socket.inet_ntop(socket.AF_INET, rd) if isinstance(rd, (bytes, bytearray)) and len(rd) == 4 else str(rd)
    except Exception:
        return str(rd)

def handle(p):
    if not p.haslayer(DNS):
        return
    d = p[DNS]
    if d.qr != 1:
        return
    sip = p[IPv6].src if p.haslayer(IPv6) else "?"
    for sect in (d.an, d.ar):
        rr = sect
        n = 0
        while rr is not None and hasattr(rr, "rrname") and n < 80:
            name = rr.rrname.decode(errors="replace")
            t = rr.type
            sources[name].add(sip)
            if t == 12:  # PTR
                try:
                    tgt = rr.rdata.decode(errors="replace") if isinstance(rr.rdata, bytes) else str(rr.rdata)
                except Exception:
                    tgt = str(rr.rdata)
                ptr[name].add(tgt)
                if name.lower().startswith("_services._dns-sd._udp"):
                    services.add(tgt)
                else:
                    inst_type[tgt] = name
            elif t == 33:  # SRV
                try:
                    tgt = rr.target.decode(errors="replace")
                    srv[name] = (tgt, getattr(rr, "port", "?"), getattr(rr, "priority", "?"), getattr(rr, "weight", "?"))
                    hosts.add(tgt)
                except Exception:
                    pass
            elif t == 16:  # TXT
                items = rr.rdata if isinstance(rr.rdata, list) else [rr.rdata]
                for it in items:
                    s = it.decode(errors="replace") if isinstance(it, bytes) else str(it)
                    if "=" in s:
                        k, v = s.split("=", 1)
                        txt[name][k] = v
                    elif s:
                        txt[name][s] = ""
            elif t == 28:  # AAAA
                aaaa[name].add(ip6(rr.rdata))
            elif t == 1:   # A
                a[name].add(ip4(rr.rdata))
            if VERBOSE:
                raw_lines.append("  %s %-58s t=%-3s" % (sip, name, t))
            rr = getattr(rr, "payload", None)
            n += 1

def q(qname, qtype="PTR", unicast=False):
    qclass = 0x8001 if unicast else 1
    try:
        sendp(Ether(dst=MCAST_MAC) / IPv6(src=SRC, dst=MCAST, hlim=255) /
              UDP(sport=5353, dport=5353) /
              DNS(id=0, qr=0, qd=DNSQR(qname=qname, qtype=qtype, qclass=qclass)),
              iface=iface, verbose=0)
    except Exception:
        pass

def ask(qname, qtype="PTR", reps=2, gap=0.15):
    for _ in range(reps):
        q(qname, qtype)
        time.sleep(gap)

print("[*] bonjour_awdl on %s (src %s), listen %ss" % (iface, SRC, listen))
t0 = time.time()
snif = AsyncSniffer(iface=iface, filter="udp and port 5353", prn=handle, store=0)
snif.start()
time.sleep(0.4)

# Phase 0: let passive announcements arrive
time.sleep(2.0)

# Phase 1: service types
ask("_services._dns-sd._udp.local", "PTR", reps=3)
time.sleep(2.0)
if VERBOSE:
    print("[*] service types so far: %s" % (", ".join(sorted(services)) or "(none)"))

# Phase 2: instances per type
for t in sorted(services):
    ask(t, "PTR", reps=2)
    time.sleep(0.3)
time.sleep(2.0)

# Phase 3: resolve every instance
for inst in sorted(inst_type):
    for qt in ("SRV", "TXT", "AAAA", "ANY"):
        ask(inst, qt, reps=1, gap=0.08)
    time.sleep(0.1)
time.sleep(1.5)

# Phase 4: resolve every discovered hostname (AAAA/A/ANY)
for h in sorted(hosts):
    for qt in ("AAAA", "A", "ANY"):
        ask(h, qt, reps=1, gap=0.08)
time.sleep(1.0)

# Phase 5: keep listening to catch periodic announcements
deadline = t0 + listen
while time.time() < deadline:
    time.sleep(0.5)
snif.stop()

print("\n================ SERVICE TYPES ADVERTISED ================")
for t in sorted(services):
    print("  %s" % t)

print("\n================ PER-INSTANCE TABLE ================")
print("%-52s %-26s %-40s %-9s %s" % ("INSTANCE", "TYPE", "DEVICE(IPv6)", "PORT", "TARGET / TXT"))
rows = sorted(inst_type.items())
for inst, typ in rows:
    dev = ",".join(sorted(sources.get(inst, ["?"])))
    s = srv.get(inst)
    port = s[1] if s else "-"
    tgt = s[0] if s else ""
    tx = " ".join("%s=%s" % (k, v) if v else k for k, v in txt.get(inst, {}).items())
    print("%-52s %-26s %-40s %-9s %s %s" % (
        inst[:52], typ[:26], dev[:40], port, (tgt[:30] if s else ""), tx))

print("\n================ HOSTNAME -> IPv6 ================")
for h in sorted(set(list(aaaa) + list(a))):
    print("  %-52s %s %s" % (h, ",".join(sorted(aaaa.get(h, []))), ",".join(sorted(a.get(h, [])))))

print("\n================ REVERSE (ip6.arpa -> name) ================")
for k, v in sorted(ptr.items()):
    if ".ip6.arpa" in k.lower():
        print("  %s -> %s" % (k, ",".join(v)))

if VERBOSE and raw_lines:
    print("\n================ RAW RECORDS ================")
    print("\n".join(raw_lines[:400]))

print("\n[*] done: %d service types, %d instances" % (len(services), len(inst_type)))
