#!/bin/bash
# Title: Skinny Pager Payload Updater
# Description: Pager-UI launcher for the canonical install script. Replaces
#              online-install.sh's keyboard S/H/B prompt with a 3-option
#              Pager picker, then exec's the install script with --select
#              so the menu behavior is always in lockstep with the upstream
#              code. This payload contains NO install logic of its own -
#              single source of truth is online-install.sh.
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
# Version: 2.0
#
# Install flow (delegated to online-install.sh):
#   0.  Pager picker: choose Skinny-Tools, Hak5 library/ payloads, or both
#   1.  Internet connectivity check
#   1A. Hak5 payload pull (H or B only) - cached at
#         /mmc/root/.skinny-tools-cache/hak5-library/ on first run
#   1B. Skinny-Tools source resolution (S or B only) - always fetched from
#         github.com/skinnyrad/Skinny-Pager-Payloads and cached at
#         /mmc/root/.skinny-tools-cache/skinny-tools/. Falls back to the
#         cached snapshot, then to the local clone, when offline.
#   2.  Pre-flight dependency check (tcpdump, aircrack-ng, python3)  [S/B only]
#   3.  Recursive .ipk discovery & install under cross-compiled-pager-tools/  [S/B only]
#   4.  Payload tree mirror with new-payload and updated-payload detection
#         (sha256 diff overwrites divergent files; nothing removed)  [S/B only]
#   5.  Global pagerctl hardware-interface symlinks  [S/B only]
#   6.  Verification & summary  [S/B only]
#
# Uninstall phases (delegated to online-install.sh --uninstall):
#   U1. Remove cross-compiled .ipk packages
#   U2. Remove custom payload directories
#   U3. Remove pagerctl hardware-interface symlinks
#   U4. Summary

# Canonical install script location. The payload is a pure launcher; the
# actual install lives in this file (which always refreshes itself from
# GitHub on each run).
INSTALL_SCRIPT="/mmc/root/Skinny-Pager-Payloads/online-install.sh"

# ==========================================
# Argument Parsing
# ==========================================
case "${1:-}" in
  --help|-h)
    cat <<EOF
Usage: $0 [--uninstall] [--help]

Default (no flag):  Pager picker asks which payload sources to pull:
                      [1] Skinny-Tools (full install/update)
                      [2] Hak5 library/ payloads from
                          github.com/hak5/wifipineapplepager-payloads
                      [3] Both (Skinny-Tools + Hak5)
                   All payload merges use no-clobber semantics: only
                   missing or upstream-divergent files are copied, nothing
                   on the Pager is ever removed by this payload.
  --uninstall, -u:   Delegates to online-install.sh --uninstall. Removes
                   cross-compiled tool .ipk packages, custom payload
                   directories, and PagerCTL hardware-interface symlinks.
                   Preserves all Hak5 factory payloads and system packages.

This payload is a thin Pager-UI wrapper around online-install.sh and
contains no install logic of its own. The canonical install behavior
lives in:

    $INSTALL_SCRIPT

If that file is missing (e.g. you don't maintain a local clone on the
Pager), this payload cannot run. Either clone the repo to
/mmc/root/Skinny-Pager-Payloads/ or download online-install.sh from
github.com/skinnyrad/Skinny-Pager-Payloads and place it at the path
above. You can also just run online-install.sh directly from the
command line.
EOF
    exit 0
    ;;
  --uninstall|-u)
    if [ ! -f "$INSTALL_SCRIPT" ]; then
      LOG red "[-] Canonical install script not found:"
      LOG "    $INSTALL_SCRIPT"
      exit 1
    fi
    exec sh "$INSTALL_SCRIPT" --uninstall
    ;;
  "")
    # Fall through to the picker below.
    ;;
  *)
    LOG red "[-] Unknown argument: $1"
    LOG "    Run '$0 --help' for usage."
    exit 1
    ;;
esac

# Ensure we're running as root (online-install.sh requires this too, but
# checking here gives a cleaner error before the picker even opens).
if [ "$(id -u)" -ne 0 ]; then
  LOG red "[-] Please run as root (SSH into the Pager)."
  exit 1
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  LOG red "[-] Canonical install script not found:"
  LOG "    $INSTALL_SCRIPT"
  LOG ""
  LOG "    Clone the Skinny-Pager-Payloads repo to /mmc/root/, or"
  LOG "    download online-install.sh from"
  LOG "    github.com/skinnyrad/Skinny-Pager-Payloads and place it at"
  LOG "    the expected path. You can also run online-install.sh"
  LOG "    directly from the command line."
  exit 1
fi

# ==========================================
# Pager Picker (replaces online-install.sh's stdin prompt)
# ==========================================
ack=$(PROMPT "Skinny-Tools Payload Updater

Select source:

1) Skinny-Tools
2) Hak5 Payloads
3) Both

Re-runs skip identical files; new and updated upstream files are
auto-applied. Nothing on the Pager is ever removed." "")
case "$?" in
  "$DUCKYSCRIPT_CANCELLED") LOG "User cancelled."; exit 1 ;;
  "$DUCKYSCRIPT_REJECTED")  LOG "Rejected.";      exit 1 ;;
  "$DUCKYSCRIPT_ERROR")     ERROR_DIALOG "Picker error."; exit 1 ;;
esac

SELECTION=""
while [ -z "$SELECTION" ]; do
  NUM=$(NUMBER_PICKER "Choose option (1-3)" 3)
  case "$?" in
    "$DUCKYSCRIPT_CANCELLED") LOG "User cancelled."; exit 1 ;;
    "$DUCKYSCRIPT_REJECTED")  LOG "Rejected.";      exit 1 ;;
    "$DUCKYSCRIPT_ERROR")     ERROR_DIALOG "Picker error."; exit 1 ;;
  esac
  case "$NUM" in
    1) SELECTION="S" ;;
    2) SELECTION="H" ;;
    3) SELECTION="B" ;;
    *) LOG red "[-] Invalid choice. Pick 1, 2, or 3." ;;
  esac
done
LOG green "[+] Selected: $SELECTION"
echo ""

# ==========================================
# Delegate to the canonical install script
# ==========================================
# exec replaces this process so the picker exit doesn't leave a wrapper
# shell hanging around. All install behavior lives in online-install.sh
# and is fetched fresh from GitHub on every run.
exec sh "$INSTALL_SCRIPT" --select "$SELECTION"
