#!/usr/bin/env python3
# Expand router SSID templates into concrete SSIDs and write a lure list
# (treated as WPA2-PSK by the payload).
#
# Template syntax:
#   x/X run     -> alphanumeric placeholder of that length
#   {a|b|}      -> alternatives; one is chosen (empty allowed), e.g.
#                  GL-MT300N{|-V1|-V2}-XXX  ->
#                    GL-MT300N-<sfx>, GL-MT300N-V1-<sfx>, GL-MT300N-V2-<sfx>
#
# Values are generated numeric-first; each template gets an even share of the
# global budget. Full enumeration (36^N) is astronomically large; raise caps
# for more coverage.
#
# Usage:
#   ./gen-common-ssids.py --templates ../lists/common_router_ssids.templates.txt \
#                         --out ../lists/common_router_ssids.txt --report
# Author: Skinny Research & Development

import argparse
import itertools
import re
import sys

DEFAULT_ALPHA = "0123456789abcdefghijklmnopqrstuvwxyz"
TOKEN_RE = re.compile(r"\{([^{}]*)\}|([xX]+)")


def _decode(n, alphabet, ln):
    base = len(alphabet)
    chars = []
    for _ in range(ln):
        chars.append(alphabet[n % base])
        n //= base
    return "".join(reversed(chars))


def values_for_len(alphabet, ln, cap):
    """Numeric-first values of length ln over alphabet, up to cap."""
    out = []
    seen = set()
    ntotal = 10 ** ln
    if ntotal <= cap:
        for n in range(ntotal):
            out.append(str(n).zfill(ln)); seen.add(out[-1])
    else:
        step = max(1, ntotal // cap)
        for n in range(0, ntotal, step):
            s = str(n).zfill(ln)
            if s not in seen:
                out.append(s); seen.add(s)
            if len(out) >= cap:
                break
    if len(out) < cap:
        total = len(alphabet) ** ln
        need = cap - len(out)
        step = max(1, total // need)
        n = 0
        while len(out) < cap and n < total:
            s = _decode(n, alphabet, ln)
            if s not in seen:
                out.append(s); seen.add(s)
            n += step
    return out


def _segments(tmpl, alphabet, run_cap):
    """Template -> list of value-lists (cartesian product of these)."""
    segs = []
    groups = 1
    pos = 0
    for m in TOKEN_RE.finditer(tmpl):
        if m.start() > pos:
            segs.append([tmpl[pos:m.start()]])
        if m.group(1) is not None:
            alts = m.group(1).split("|")
            segs.append(alts if alts else [""])
        else:
            segs.append(values_for_len(alphabet, len(m.group(2)), run_cap))
        pos = m.end()
    if pos < len(tmpl):
        segs.append([tmpl[pos:]])
    return segs


def _alt_combos(tmpl):
    """Number of alternative-group combinations in a template (>=1)."""
    n = 1
    for m in TOKEN_RE.finditer(tmpl):
        if m.group(1) is not None:
            n *= max(1, len(m.group(1).split("|")))
    return n


def expand_template(tmpl, alphabet, run_cap, tmpl_cap):
    # split the per-template budget across alternative combos so every revision
    # (e.g. -V1/-V2) gets a share instead of the first one eating the cap
    run_budget = max(1, min(run_cap, tmpl_cap // _alt_combos(tmpl)))
    segs = _segments(tmpl, alphabet, run_budget)
    if not segs:
        return [tmpl]
    out = []
    for combo in itertools.product(*segs):
        out.append("".join(combo)[:32])
        if len(out) >= tmpl_cap:
            break
    return out


def main():
    ap = argparse.ArgumentParser(description="Expand common-router SSID templates.")
    ap.add_argument("--templates", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-cap", type=int, default=1024)
    ap.add_argument("--template-cap", type=int, default=1024)
    ap.add_argument("--global-cap", type=int, default=12000)
    ap.add_argument("--upper", action="store_true", help="also use A-Z")
    ap.add_argument("--full", action="store_true", help="no caps (very large)")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    alphabet = DEFAULT_ALPHA + ("ABCDEFGHIJKLMNOPQRSTUVWXYZ" if args.upper else "")

    templates = []
    for line in open(args.templates, "r", errors="ignore"):
        s = line.strip()
        if s and not s.startswith("#"):
            templates.append(s)
    if not templates:
        sys.stderr.write("gen-common-ssids: no templates\n")
        sys.exit(1)

    if args.full:
        budget = tmpl_cap = run_cap = glob = 10 ** 12
    else:
        glob = args.global_cap
        budget = max(1, glob // len(templates))
        tmpl_cap = min(args.template_cap, budget)
        run_cap = min(args.run_cap, budget)

    seen = set()
    out = []
    counts = []
    for t in templates:
        added = 0
        for v in expand_template(t, alphabet, run_cap, tmpl_cap):
            if v and len(v) <= 32 and v not in seen:
                seen.add(v)
                out.append(v)
                added += 1
                if len(out) >= glob:
                    break
        counts.append((t, added))
        if len(out) >= glob:
            break

    with open(args.out, "w") as fh:
        fh.write("# generated by gen-common-ssids.py from %s\n" % args.templates)
        fh.write("# %d unique SSIDs\n" % len(out))
        for s in out:
            fh.write("%s\n" % s)

    sys.stderr.write("gen-common-ssids: wrote %d SSIDs to %s (budget %d/template)\n"
                     % (len(out), args.out, tmpl_cap))
    if args.report:
        for t, n in counts:
            sys.stderr.write("  %-34s %d\n" % (t, n))


if __name__ == "__main__":
    main()
