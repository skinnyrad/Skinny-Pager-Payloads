#!/usr/bin/env python3
"""
v27_ie221.py — Inject IE-221 vendor_elements into /tmp/run/hostapd-phy0.conf.

UCI does not expose a clean way to add a vendor-specific IE (Element ID
221) to a BSS's beacon/probe-resp frames. We do it by appending a raw
hostapd config line to /tmp/run/hostapd-phy0.conf after hostapd has
generated the file (which happens on every `wifi reload`).

Three legacy carrier OUIs are injected: Cisco 00:40:96, Aruba 00:1a:1e,
Ruckus 00:1b:0d. These match the kinds of gear AT&T legacy open hotspots
were built on; iOS carrier profiles keyed on attwifi as an open network
match these signatures.

Usage:
  v27_ie221.py [--ifname wlan0open] [--conf /tmp/run/hostapd-phy0.conf]

The script is idempotent: if the vendor_elements= line is already present,
it leaves it alone.
"""

import argparse
import os
import re
import subprocess
import sys

# vendor_elements line. Each IE-221 starts with 0xdd; 8 bytes total per
# IE (1 type + 1 length + 3 OUI + 4 payload). The payload is intentionally
# minimal — the goal is OUI recognition, not vendor-specific features.
VENDOR_ELEMENTS = (
    "vendor_elements=dd:08:00:40:96:00:00:00:01 "
    "dd:08:00:1a:1e:00:00:00:01 "
    "dd:08:00:1b:0d:00:00:00:01"
)
MARKER = "# v27_ie221 injected"


def find_bss_block(conf_path, ifname):
    """Return the index range [start, end) of the BSS block for ifname.

    hostapd uses `bss=<name>` for secondary BSSes and `interface=<name>`
    for the primary BSS. We handle both forms.
    """
    with open(conf_path, "r") as f:
        lines = f.readlines()

    start = None
    block_re = re.compile(r"^(?:bss|interface)=([\w\.-]+)\s*$")
    for i, line in enumerate(lines):
        m = block_re.match(line)
        if m and m.group(1) == ifname:
            start = i
            break
    if start is None:
        raise SystemExit(f"no bss= or interface= block for {ifname} in {conf_path}")

    # find next bss= or interface= block (or EOF)
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if block_re.match(lines[i]):
            end = i
            break
    return start, end, lines


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ifname", default="wlan0open")
    p.add_argument("--conf", default="/tmp/run/hostapd-phy0.conf")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if not os.path.exists(args.conf):
        raise SystemExit(f"{args.conf} not found; run `wifi reload` first")

    start, end, lines = find_bss_block(args.conf, args.ifname)

    # strip any existing vendor_elements= line(s) AND marker lines so we
    # can re-inject cleanly even if the config has stale injections
    new_lines = []
    for line in lines:
        if line.startswith("vendor_elements=") or line.strip() == MARKER:
            continue
        new_lines.append(line)

    # determine which keyword the block used (bss= or interface=)
    block_keyword = "bss"
    with open(args.conf, "r") as f:
        first_lines = [next(f, "").rstrip("\n") for _ in range(start + 1)]
    if start < len(first_lines) and first_lines[start].startswith("interface="):
        block_keyword = "interface"

    # insert at end of bss block
    final_lines = (
        new_lines[:end]
        + [f"{VENDOR_ELEMENTS}\n", f"{MARKER}\n"]
        + new_lines[end:]
    )

    if args.dry_run:
        print("--- DRY RUN ---")
        for line in final_lines[max(0, end - 3):end + 3]:
            print(line, end="")
        return 0

    with open(args.conf, "w") as f:
        f.writelines(final_lines)

    # hostapd needs SIGHUP to re-read config
    try:
        subprocess.run(["killall", "-HUP", "hostapd"], check=False)
    except Exception as e:
        print(f"warning: killall hostapd HUP failed: {e}", file=sys.stderr)

    print(f"injected IE-221 OUIs into {args.conf} {block_keyword}={args.ifname} block")
    return 0


if __name__ == "__main__":
    sys.exit(main())