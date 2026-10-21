#!/bin/sh
# Title: Git Repository Live Online Installer (Python, Security Tools, & Payloads)
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
#
# Install profiles:
#   S = Skinny only, full dependency + cross-compiled tool install
#   H = Hak5 library only (no Skinny payloads, no dependency install)
#   B = Both, full dependency + cross-compiled tool install
#   C = Pager Class: Hak5 + the non-cross-compiled Skinny payload set,
#       with only the class dependency profile installed. The guaranteed
#       class payloads are foxhunt_AP, foxhunt_clients,
#       Aireplay-ng-AP-Deauth, PMF-Checker, Quick-Brown-Fox-AP,
#       Skinny-Skim-Scanner, gps-mgmtap-nmea,
#       WiFi-Client-Tracker-Targeted, and PAGERCTL.
#
# Install flow:
#   0.  S/H/B/C selector
#   1.  Internet connectivity check (skipped with --offline)
#   1A. Hak5 payload pull (H/B/C) - fetches the upstream library and merges
#         it into /mmc/root/payloads/ (alert DISABLED.-aware, no-clobber)
#   1B. Skinny-Tools source resolution (S/B/C) - fetches upstream HEAD and
#         caches it under /mmc/root/.skinny-tools-cache/skinny-tools/.
#         Fallbacks: cached snapshot, then the local clone. With --offline,
#         the local clone is preferred and no network fetch is attempted.
#   2.  Dependency provisioning (S/B full, C class-minimal, H none)
#   3.  Cross-compiled .ipk install                         [S/B only]
#   3.5 wpad-swap asset staging (Passpoint / ATT)            [S/B only]
#   4.  Payload tree mirror with alert DISABLED.-aware updates  [S/B/C only]
#   5.  Global pagerctl hardware-interface symlinks          [S/B/C only]
#   6.  Verification & summary                               [S/B/C only]
#
# The DISABLED.<name> convention used by newer Pager firmware applies to
# alert payloads only. An alert toggled off in the Pager UI is updated in
# place under its DISABLED. name, and duplicate enabled+disabled alert
# copies are repaired when it is safe to do so. recon/ and user/ payloads
# are never renamed by the Pager.
#
# Uninstall phases (--uninstall):
#   U1. Remove cross-compiled .ipk packages
#   U2. Remove custom payload directories
#   U3. Remove pagerctl hardware-interface symlinks
#   U4. Summary

# ==========================================
# Argument Parsing
# ==========================================
MODE="install"
SELECTION=""
OFFLINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall|-u)
      MODE="uninstall"
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--uninstall] [--help] [--offline] [--select S|H|B|C] [S|H|B|C]

Default (no flag):  Interactive prompt asks which install profile to use:
                      [S] Skinny Pager Payloads
                          Full Skinny install/update: dependencies and
                          cross-compiled tools.
                      [H] Hak5 Pager Payloads
                          Hak5 library/ payloads only.
                      [B] Both
                          Hak5 + Skinny, with full dependencies and
                          cross-compiled tools.
                      [C] Pager Class
                          Hak5 + the Skinny payloads that do not need the
                          cross-compiled toolset. Installs only the class
                          dependency profile (python3/ctypes, aircrack-ng,
                          sqlite3, BlueZ) for: foxhunt_AP, foxhunt_clients,
                          Aireplay-ng-AP-Deauth, PMF-Checker,
                          Quick-Brown-Fox-AP, Skinny-Skim-Scanner,
                          gps-mgmtap-nmea, WiFi-Client-Tracker-Targeted,
                          and PAGERCTL.
                   Alert merges are DISABLED.<name>-aware and no-clobber:
                   existing payloads are updated in place, nothing is
                   removed by the install path.
  --uninstall, -u:   Remove all Skinny-Tools customizations (cross-compiled
                   tool .ipk packages, custom payload directories, and
                   PagerCTL hardware-interface symlinks). Preserves all
                   Hak5 factory payloads. Cross-compiled library packages
                   (lib* .ipk files) and pre-flight system packages
                   (python3, aircrack-ng, tcpdump, etc.) are NOT removed;
                   the summary lists the manual command to remove them
                   if a full factory reset is desired.
  --offline:         Skip the WAN check and do not fetch from GitHub. Uses
                   the local repository (preferred) or the cached snapshots
                   under /mmc/root/.skinny-tools-cache/. Useful on an
                   isolated Pager or for repeatable testing.
  --select S|H|B|C:  Non-interactive mode: skip the prompt and use the
                   given selection directly. Accepts "--select S",
                   "--select=S", or just "S" as a positional argument.
                   Used by the Skinny-Pager-Payload-Updater Pager-UI
                   menu payload so the menu always tracks this script.
  --help, -h:        Show this help.

Run from inside the cloned Skinny-Tools repository so the script can
discover payloads/ and cross-compiled-pager-tools/. Hak5 payloads are
fetched directly from GitHub at install time and do not require the
Skinny-Tools repo to be present locally.
EOF
      exit 0
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --select)
      if [ "$#" -lt 2 ]; then
        echo "[-] --select requires S, H, B, or C"
        exit 1
      fi
      SELECTION="$2"
      shift 2
      ;;
    --select=*)
      SELECTION="${1#--select=}"
      shift
      ;;
    [sShHbBcC])
      # Positional: "$0 S", "$0 H", "$0 B", or "$0 C" (case-insensitive).
      SELECTION="$1"
      shift
      ;;
    *)
      echo "[-] Unknown argument: $1"
      echo "    Run '$0 --help' for usage."
      exit 1
      ;;
  esac
done

case "$SELECTION" in
  "") ;;
  [sS]) SELECTION="S" ;;
  [hH]) SELECTION="H" ;;
  [bB]) SELECTION="B" ;;
  [cC]) SELECTION="C" ;;
  *)
    echo "[-] --select requires S, H, B, or C (got: $SELECTION)"
    exit 1
    ;;
esac

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Please run as root (SSH into the Pager)."
  exit 1
fi

# Get the directory where the cloned repository sits
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PAYLOADS_DIR="$REPO_DIR/payloads"
SYSTEM_PAYLOADS_DEST="/mmc/root/payloads"
CROSS_TOOLS_DIR="$REPO_DIR/cross-compiled-pager-tools"

# Profile flags, filled in after Phase 0.
DO_HAK5=0
DO_SKINNY=0
DEP_PROFILE="none"

# Pager Class: payloads that need the cross-compiled toolset. Everything
# else in the Skinny tree is mirrored, except PNL-Beacon-Lure, which is
# intentionally omitted from the class preset.
CLASS_EXCLUDE_CROSS="user/Skinny-Tools/att \
user/Skinny-Tools/ATT-Open-Steer \
user/Skinny-Tools/AWDL-Stim \
user/utilities/WPAD-SWAP"
CLASS_EXCLUDE_EXTRA="user/Skinny-Tools/PNL-Beacon-Lure"

# Pager Class dependency profile: only what the guaranteed class payloads
# need. aircrack-ng supplies airodump-ng/aireplay-ng, sqlite3-cli supplies
# PMF-Checker, and the BlueZ packages supply btmon/hcitool/hciconfig.
CLASS_PKGS="python3-base python3-light python3-ctypes \
            aircrack-ng sqlite3-cli \
            bluez-utils bluez-utils-btmon"
CLASS_BINS="python3 airodump-ng aireplay-ng sqlite3 btmon hcitool hciconfig"
CLASS_MODS="ctypes"

# Guaranteed class payloads (used by the Phase 6 verification).
CLASS_REQUIRED_PAYLOADS="recon/access_point/Aireplay-ng-AP-Deauth \
recon/access_point/foxhunt_AP \
recon/client/foxhunt_clients \
recon/access_point/PMF-Checker \
recon/access_point/Quick-Brown-Fox-AP \
user/Skinny-Tools/Skinny-Skim-Scanner \
user/Skinny-Tools/gps-mgmtap-nmea \
user/Skinny-Tools/WiFi-Client-Tracker-Targeted \
user/utilities/PAGERCTL"

# ==========================================
# UNINSTALL MODE
# ==========================================
if [ "$MODE" = "uninstall" ]; then
  echo "========================================================="
  echo "[*] Initializing Skinny-Tools UNINSTALL Sequence..."
  echo "========================================================="

  if [ ! -d "$LOCAL_PAYLOADS_DIR" ] && [ ! -d "$CROSS_TOOLS_DIR" ]; then
    echo "[-] Error: Cannot locate the Skinny-Tools repository at:"
    echo "    $REPO_DIR"
    echo "    The uninstall needs the cloned repository to know what to remove."
    echo "    Run the script from inside the Skinny-Tools repo directory."
    exit 1
  fi

  # --- Phase U1: Remove cross-compiled .ipk packages ---
  echo "[*] Removing cross-compiled .ipk packages..."
  if [ ! -d "$CROSS_TOOLS_DIR" ]; then
    echo "[!] No cross-compiled-pager-tools/ directory in repo. Skipping."
  else
    # Exclude the vendored awdl/ and wpad-wolfssl/ .ipk's (handled separately;
    # see the install path for details).
    IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f ! -name "._*" 2>/dev/null \
                  ! -path "*/wpad-wolfssl/*" ! -path "*/awdl/*" | sort)
    if [ -z "$IPK_FILES" ]; then
      echo "[!] No .ipk files found in $CROSS_TOOLS_DIR. Skipping."
    else
      REMOVED=0
      SKIPPED=0
      FAILED_PKGS=""
      for ipk in $IPK_FILES; do
        # Derive the opkg package name from the .ipk filename by stripping
        # the "_<version>_<arch>" suffix (e.g. librtlsdr_0.6.0-1_mipsel_24kc
        # -> librtlsdr, rtl_433_25.12-1_mipsel_24kc -> rtl_433).
        pkg=$(basename "$ipk" .ipk | sed 's/_[0-9][^_]*_mipsel.*$//')
        # Skip libraries: they're general-purpose system packages that other
        # Pager workflows may rely on, so the uninstall leaves them in place.
        # Only the tool packages (rtl_433, ubertooth-utils, ...) are removed.
        case "$pkg" in
          lib*)
            echo "    [skip] $pkg (library - left in place)"
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
        esac
        if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
          echo "    -> $pkg"
          OPKG_OUT=$(opkg remove "$pkg" 2>&1)
          OPKG_RC=$?
          echo "$OPKG_OUT" | sed 's/^/       /'
          if [ "$OPKG_RC" -ne 0 ]; then
            echo "       [ERROR] opkg remove returned non-zero for $pkg"
            FAILED_PKGS="$FAILED_PKGS $pkg"
          else
            REMOVED=$((REMOVED + 1))
          fi
        else
          echo "    [skip] $pkg (not installed)"
          SKIPPED=$((SKIPPED + 1))
        fi
      done
      echo "[*] .ipk removal summary: $REMOVED removed, $SKIPPED skipped."
      if [ -n "$FAILED_PKGS" ]; then
        echo "[!] Some packages could not be removed:$FAILED_PKGS"
        echo "    They may be dependencies of other installed packages."
      fi
    fi
  fi

  # --- Phase U2: Remove custom payload directories ---
  echo "[*] Removing custom payload directories..."
  if [ ! -d "$LOCAL_PAYLOADS_DIR" ]; then
    echo "[!] No payloads/ directory in repo. Skipping."
  else
    REMOVED=0
    SKIPPED=0
    # Remove a managed payload from the Pager. Alert payloads may also have
    # a DISABLED.<name> copy from the newer firmware's alert toggle, so
    # remove that variant only for the alerts tree. recon/ and user/ payloads
    # are never renamed by the Pager.
    remove_payload_dir() {
      label="$1"
      enabled="$2"
      allow_disabled="${3:-0}"
      parent="$(dirname "$enabled")"
      name="$(basename "$enabled")"
      disabled="$parent/DISABLED.$name"
      found=0
      for d in "$enabled" "$disabled"; do
        [ -d "$d" ] || continue
        if [ "$d" = "$disabled" ] && [ "$allow_disabled" != "1" ]; then
          continue
        fi
        found=1
        case "$d" in
          */DISABLED.*) echo "    -> $label (disabled)" ;;
          *)            echo "    -> $label" ;;
        esac
        rm -rf "$d"
        REMOVED=$((REMOVED + 1))
      done
      if [ "$found" -eq 0 ]; then
        echo "    [skip] $label (not present)"
        SKIPPED=$((SKIPPED + 1))
      fi
    }

    # Walk payloads/user/<tree>/* and payloads/recon/<tree>/* in the repo
    # and remove the matching names from the system destination. Hak5
    # factory payloads outside our repo tree are untouched.
    for tree in Skinny-Tools utilities; do
      src="$LOCAL_PAYLOADS_DIR/user/$tree"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        remove_payload_dir "user/$tree/$name" \
                           "$SYSTEM_PAYLOADS_DEST/user/$tree/$name"
      done
    done

    for tree in access_point client; do
      src="$LOCAL_PAYLOADS_DIR/recon/$tree"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        remove_payload_dir "recon/$tree/$name" \
                           "$SYSTEM_PAYLOADS_DEST/recon/$tree/$name"
      done
    done

    # Alerts tree: remove only the payloads WE ship (Auto-Kick,
    # CatchAndRelease), never Hak5 factory alert payloads (example/,
    # deduplicate/, ...).
    src="$LOCAL_PAYLOADS_DIR/alerts/pineapple_client_connected"
    if [ -d "$src" ]; then
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        remove_payload_dir "alerts/pineapple_client_connected/$name" \
                           "$SYSTEM_PAYLOADS_DEST/alerts/pineapple_client_connected/$name" 1
      done
    fi
    echo "[*] Payload removal summary: $REMOVED removed, $SKIPPED skipped."

    # Tidy up: remove the empty parent trees we created ourselves so the
    # uninstall leaves no trace of our custom payload directory layout.
    # Only touch the Skinny-Tools/ and utilities/ parents - never the
    # Hak5 factory recon/access_point/ and recon/client/ placeholders.
    for parent in \
        "$SYSTEM_PAYLOADS_DEST/user/Skinny-Tools" \
        "$SYSTEM_PAYLOADS_DEST/user/utilities"; do
      if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
        rmdir "$parent" 2>/dev/null && echo "    [tidy] removed empty $parent"
      fi
    done
  fi

  # --- Phase U2.5: Tear down wpad-swap state and restore factory wpad ---
  # The wpad-swap engine bind-mounts wolfssl over /usr/sbin/{wpad,hostapd,
  # wpa_supplicant} only while active and installs libwolfssl additively.
  # Restore stock first (so we never leave a half-mounted overlay behind),
  # then remove the staged assets and the additive libwolfssl.
  echo "[*] Restoring factory wpad and removing wpad-swap assets..."
  if mount 2>/dev/null | grep -q " on /usr/sbin/wpad "; then
    echo "    -> unmounting leftover wpad overlay(s)"
    umount /usr/sbin/wpa_supplicant 2>/dev/null || umount -l /usr/sbin/wpa_supplicant 2>/dev/null || true
    umount /usr/sbin/hostapd 2>/dev/null || umount -l /usr/sbin/hostapd 2>/dev/null || true
    umount /usr/sbin/wpad 2>/dev/null || umount -l /usr/sbin/wpad 2>/dev/null || true
  fi
  # Restart wpad so the on-disk factory binary is the running one again.
  /etc/init.d/wpad restart >/dev/null 2>&1 || true
  wifi up >/dev/null 2>&1 || true
  # Remove the additive libwolfssl (only if it is our known artifact).
  if [ -f /usr/lib/libwolfssl.so.5.9.1.e624513f ]; then
    rm -f /usr/lib/libwolfssl.so.5.9.1.e624513f
    echo "    -> removed /usr/lib/libwolfssl.so.5.9.1.e624513f"
  fi
  if [ -d /mmc/root/wpad-swap ]; then
    rm -rf /mmc/root/wpad-swap
    echo "    -> removed /mmc/root/wpad-swap/"
  fi
  echo "[+] wpad-swap teardown complete (factory wpad restored)."

  # --- Phase U3: Remove pagerctl symlinks ---
  echo "[*] Removing PagerCTL hardware-interface symlinks..."
  PYTHON_SITE_DIR=""
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
  fi
  rm -f /usr/lib/libpagerctl.so
  if [ -n "$PYTHON_SITE_DIR" ]; then
    rm -f "$PYTHON_SITE_DIR/pagerctl.py" "$PYTHON_SITE_DIR/libpagerctl.so"
  fi
  echo "[+] PagerCTL symlinks removed."

  # --- Phase U4: Summary ---
  echo "========================================================="
  echo "[+] UNINSTALL COMPLETE"
  echo "========================================================="
  echo "[*] Removed:"
  echo "    - Custom cross-compiled tool .ipk packages (e.g. rtl_433,"
  echo "      ubertooth-utils)"
  echo "    - Custom payload directories under payloads/user/ and payloads/recon/"
  echo "    - PagerCTL hardware-interface symlinks"
  echo "    - wpad-swap staged assets (/mmc/root/wpad-swap/) and the additive"
  echo "      libwolfssl helper object (factory wpad is restored)"
  echo ""
  echo "[*] Preserved (not removed):"
  echo "    - Hak5 factory payloads (alerts/, recon/ factory entries,"
  echo "      user/<factory folders like evil_portal, prank, ...>)"
  echo "    - Cross-compiled library .ipk packages (librtlsdr, libbtbb,"
  echo "      libubertooth, ...) - these are general-purpose system libs"
  echo "      that other Pager workflows may rely on"
  echo "    - System packages installed by the pre-flight phase:"
  echo "        python3 (+ python3-ctypes/-email/-urllib/-logging/-decimal/-codecs),"
  echo "        aircrack-ng, tcpdump, sqlite3-cli, hostapd-utils, umdns,"
  echo "        bluez-utils, bluez-utils-btmon, bluez-tools, hcxtools,"
  echo "        nftables-json, kmod-mt76-usb, libpcap, libopenssl, libffi,"
  echo "        libbz2, zlib, libpcre2, libnl-core200, libnl-genl200,"
  echo "        iw, libev, scapy, and avahi-nodbus-daemon + libavahi-nodbus-support"
  echo "        (installed to /mmc for the AWDL-Stim lure)"
  echo "      To fully remove these, run manually:"
  echo "        opkg remove python3 python3-ctypes python3-email python3-urllib \\"
  echo "                 aircrack-ng tcpdump sqlite3-cli hostapd-utils umdns \\"
  echo "                 bluez-utils bluez-utils-btmon bluez-tools hcxtools \\"
  echo "                 nftables-json libpcap libopenssl libffi libbz2 zlib \\"
  echo "                 libpcre2 libnl-core200 libnl-genl200 \\"
  echo "                 iw libev scapy \\"
  echo "                 librtlsdr libbtbb libubertooth"
  echo "        opkg remove -d mmc avahi-nodbus-daemon libavahi-nodbus-support"
  echo ""
  echo "[*] The Pager is back to its pre-Skinny-Tools state."
  exit 0
fi

# ==========================================
# INSTALL MODE
# ==========================================
echo "========================================================="
echo "[*] Initializing Live Git Online Installation Sequence..."
echo "========================================================="

# ==========================================
# PHASE 0: Install Profile Selector (S/H/B/C)
# ==========================================
if [ -z "$SELECTION" ]; then
  echo ""
  echo "Do you want to install:"
  echo "  [S] Skinny Pager Payloads"
  echo "      Full install/update: dependencies + cross-compiled tools"
  echo "  [H] Hak5 Pager Payloads"
  echo "      Hak5 library/ payloads only"
  echo "  [B] Both"
  echo "      Hak5 + Skinny, full dependencies + cross-compiled tools"
  echo "  [C] Pager Class"
  echo "      Hak5 + non-cross-compiled Skinny payloads with the class deps:"
  echo "      foxhunt_AP, foxhunt_clients, Aireplay-ng-AP-Deauth, PMF-Checker,"
  echo "      Quick-Brown-Fox-AP, Skinny-Skim-Scanner, gps-mgmtap-nmea,"
  echo "      WiFi-Client-Tracker-Targeted, PAGERCTL"
  while [ -z "$SELECTION" ]; do
    printf "Choice [S/H/B/C]: "
    read -r SELECTION
    case "$SELECTION" in
      [sS]) SELECTION="S" ;;
      [hH]) SELECTION="H" ;;
      [bB]) SELECTION="B" ;;
      [cC]) SELECTION="C" ;;
      *)
        echo "[-] Invalid choice. Please enter S, H, B, or C."
        SELECTION=""
        ;;
    esac
  done
  echo "[+] Selected: $SELECTION"
  echo ""
else
  # Non-interactive mode: --select (or positional S/H/B/C) was supplied.
  echo "[+] Selected: $SELECTION (non-interactive)"
  echo ""
fi

# Translate the selection into the phases that run and the dependency
# profile used by Phase 2.
case "$SELECTION" in
  S) DO_HAK5=0; DO_SKINNY=1; DEP_PROFILE="full" ;;
  H) DO_HAK5=1; DO_SKINNY=0; DEP_PROFILE="none" ;;
  B) DO_HAK5=1; DO_SKINNY=1; DEP_PROFILE="full" ;;
  C) DO_HAK5=1; DO_SKINNY=1; DEP_PROFILE="class" ;;
esac

case "$DEP_PROFILE" in
  full)  echo "[*] Profile: full dependency + cross-compiled tool install." ;;
  class) echo "[*] Profile: Pager Class (minimal deps, no cross-compiled tools)." ;;
  none)  echo "[*] Profile: Hak5 payloads only (no Skinny dependency install)." ;;
esac
echo ""

# Stage directories for tarballs fetched at runtime (Hak5 and Skinny-Tools).
# Initialized empty; each phase that creates a stage dir will overwrite its
# variable, and the EXIT trap will clean whatever was created.
HAK5_STAGE=""
SKINNY_STAGE=""
# MERGE_TMP is created lazily by merge_payload_category() the first time
# a payload is processed; the EXIT trap cleans it like the stage dirs.
MERGE_TMP=""
# Trap cleans any staged dirs on every exit path so /tmp doesn't accumulate
# cruft on the Pager. rm -rf on empty vars is a harmless no-op.
trap 'rm -rf "$HAK5_STAGE" "$SKINNY_STAGE" "$MERGE_TMP" 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# Payload path / merge helpers
# ---------------------------------------------------------------------------
# Newer Pager firmware represents a toggled-off ALERT payload by renaming
# its directory to DISABLED.<name>. This convention applies only to the
# alerts/ tree; recon/ and user/ payloads are always enabled directories.
# The merge helper already knows the parent category directory, so it only
# has to resolve the payload directory name.
#
# payload_dir_dst <parent_dir> <name> [<top>]
payload_dir_dst() {
  parent="${1%/}"
  name="$2"
  top="${3:-}"
  if [ "$top" = "alerts" ]; then
    if [ -d "$parent/DISABLED.$name" ]; then
      # Disabled copy wins when both exist: it reflects the user's last
      # toggle state, and the merge helper repairs safe duplicates.
      printf '%s\n' "$parent/DISABLED.$name"
    elif [ -d "$parent/$name" ]; then
      printf '%s\n' "$parent/$name"
    else
      # New alert payloads default to disabled, matching Hak5's own
      # UpdatePayloads behavior and the newer Pager convention.
      printf '%s\n' "$parent/DISABLED.$name"
    fi
  else
    # recon/ and user/ payloads have no DISABLED. state. Always use the
    # plain directory name; any stray DISABLED.<name> is not ours to touch.
    printf '%s\n' "$parent/$name"
  fi
}

# sha256_file: print the sha256 of a single file's contents. sha256sum ships
# in BusyBox on OpenWrt (including the Hak5 Pager), so no fallback is needed.
sha256_file() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

payload_file_count() {
  ( cd "$1" && find . -type f ! -name '._*' ! -name '.DS_Store' ) | wc -l
}

# payload_trees_match <a> <b> - true when both trees have the same file set
# and every file hashes identically.
payload_trees_match() {
  a="$1"
  b="$2"
  [ -d "$a" ] && [ -d "$b" ] || return 1
  [ "$(payload_file_count "$a")" = "$(payload_file_count "$b")" ] || return 1
  diffs=$( ( cd "$a" && find . -type f ! -name '._*' ! -name '.DS_Store' ) | while IFS= read -r f; do
    [ -e "$b/$f" ] || { echo diff; break; }
    [ "$(sha256_file "$a/$f")" = "$(sha256_file "$b/$f")" ] || { echo diff; break; }
  done )
  [ -z "$diffs" ]
}

# class_exclude_reason <full_label> - print why a payload is omitted from
# Pager Class, or return 1 when it is part of the class preset.
class_exclude_reason() {
  case " $CLASS_EXCLUDE_CROSS " in
    *" $1 "*) echo "requires cross-compiled tools"; return 0 ;;
  esac
  case " $CLASS_EXCLUDE_EXTRA " in
    *" $1 "*) echo "omitted from the Pager Class preset"; return 0 ;;
  esac
  return 1
}

# Shared helper for payload tree-walking. Used by both Phase 1A (Hak5 fetch)
# and Phase 4 (Skinny-Tools mirror) so the two phases cannot drift in their
# iteration logic. For each payload subdir under $1 (src), installs it into
# $2 (dst root).
# Alert payloads (<top> = alerts) use the DISABLED.<name> toggle convention:
#   - If only <name> exists: update it in place.
#   - If only DISABLED.<name> exists: update it in place and keep it disabled.
#   - If both exist: repair the duplicate when safe (identical copies, or the
#     enabled copy is an unmodified repo copy); otherwise warn and leave both.
#   - If neither exists: create the new alert as DISABLED.<name>.
# recon/ and user/ payloads always use <name>; they are never toggled into
# DISABLED.<name> by the Pager.
# Per-file updates use sha256 and overwrite divergent upstream files.
# Updates MERGE_NEW_LABELS, MERGE_UPDATED_LABELS, MERGE_PRESENT_LABELS,
# MERGE_FAILED_LABELS, MERGE_SKIPPED_LABELS, MERGE_REPAIRED_LABELS, and
# MERGE_DUPLICATE_LABELS.
merge_payload_category() {
  src="$1"
  dst_root="$2"
  label="$3"
  [ -d "$src" ] || return 0
  if [ -z "$MERGE_TMP" ] || [ ! -d "$MERGE_TMP" ]; then
    MERGE_TMP="$(mktemp -d -t skinny-merge.XXXXXX)"
  fi
  for entry in "$src"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    full_label="$label/$name"

    if [ "${DEP_PROFILE:-full}" = "class" ]; then
      if skip_reason="$(class_exclude_reason "$full_label")"; then
        echo "[skip] $full_label ($skip_reason)"
        MERGE_SKIPPED_LABELS="${MERGE_SKIPPED_LABELS}${MERGE_SKIPPED_LABELS:+ }$full_label"
        continue
      fi
    fi

    top="${label%%/*}"
    enabled="$dst_root/$name"
    disabled="$dst_root/DISABLED.$name"

    # Only alerts use the DISABLED.<name> toggle convention. Repair the old
    # double-install state there, and only delete the enabled copy when it is
    # provably redundant: identical to the disabled copy, or an unmodified
    # copy of the repo source. Edited copies are left alone.
    if [ "$top" = "alerts" ] && [ -d "$enabled" ] && [ -d "$disabled" ]; then
      if payload_trees_match "$enabled" "$disabled" || \
         payload_trees_match "$entry" "$enabled"; then
        rm -rf "$enabled"
        echo "[REPAIRED] $full_label (removed duplicate enabled copy; kept DISABLED.$name)"
        MERGE_REPAIRED_LABELS="${MERGE_REPAIRED_LABELS}${MERGE_REPAIRED_LABELS:+ }$full_label"
      else
        echo "[!] WARNING: duplicate payload copies detected:"
        echo "      $enabled"
        echo "      $disabled"
        echo "    The enabled copy has local changes; leaving both in place."
        echo "    Remove the enabled duplicate manually: rm -rf '$enabled'"
        MERGE_DUPLICATE_LABELS="${MERGE_DUPLICATE_LABELS}${MERGE_DUPLICATE_LABELS:+ }$full_label"
      fi
    fi

    dst="$(payload_dir_dst "$dst_root" "$name" "$top")"
    state=""
    case "$dst" in
      */DISABLED.*) state=" (disabled)" ;;
    esac

    if [ -d "$dst" ]; then
      flag="$MERGE_TMP/$name.updated"
      : > "$flag"
      ( cd "$entry" && find . -type f ! -name '._*' ! -name '.DS_Store' ) | while IFS= read -r f; do
        if [ ! -e "$dst/$f" ]; then
          mkdir -p "$dst/$(dirname "$f")"
          cp "$entry/$f" "$dst/$f"
          echo "[NEW FILE] $full_label/$f$state"
          echo x >> "$flag"
        elif [ "$(sha256_file "$entry/$f")" != "$(sha256_file "$dst/$f")" ]; then
          cp "$entry/$f" "$dst/$f"
          echo "[UPDATED FILE] $full_label/$f$state"
          echo x >> "$flag"
        fi
      done
      if [ -s "$flag" ]; then
        MERGE_UPDATED_LABELS="${MERGE_UPDATED_LABELS}${MERGE_UPDATED_LABELS:+ }$full_label"
        echo "[UPDATED PAYLOAD] $full_label$state"
      else
        MERGE_PRESENT_LABELS="${MERGE_PRESENT_LABELS}${MERGE_PRESENT_LABELS:+ }$full_label"
      fi
      rm -f "$flag"
    else
      mkdir -p "$dst"
      if cp -r "$entry/." "$dst/" 2>/dev/null; then
        # Strip macOS AppleDouble (`._*`) sidecars and .DS_Store that may
        # have been copied along, so they never appear as bogus payload files.
        find "$dst" -name '._*' -type f -exec rm -f {} \; 2>/dev/null
        find "$dst" -name '.DS_Store' -type f -exec rm -f {} \; 2>/dev/null
        MERGE_NEW_LABELS="${MERGE_NEW_LABELS}${MERGE_NEW_LABELS:+ }$full_label"
        echo "[NEW PAYLOAD] $full_label$state"
      else
        rm -rf "$dst"
        MERGE_FAILED_LABELS="${MERGE_FAILED_LABELS}${MERGE_FAILED_LABELS:+ }$full_label"
      fi
    fi
  done
}

# ==========================================
# PHASE 1: Internet Connectivity Check
# ==========================================
if [ "$OFFLINE" = "1" ]; then
    echo "[*] Offline mode: skipping WAN check (using local repo/cache)."
else
    echo "[*] Checking live WAN internet link via Google DNS..."
    # Ping 8.8.8.8 exactly twice, timeout after 3 seconds, silence output
    if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "[+] Internet Connection: ONLINE"
    else
        echo "[-] Critical Error: No internet connectivity detected!"
        echo "    Please verify your upstream client network/tether configuration,"
        echo "    or re-run with --offline to use the local repo/cache."
        exit 1
    fi
fi

# ==========================================
# PHASE 1A: Hak5 Payload Library Fetch (H or B only)
# ==========================================
# Pulls github.com/hak5/wifipineapplepager-payloads and merges the contents
# of its library/ tree (alerts/, recon/, user/) into the Pager's payload
# destination. Merges are DISABLED.-aware and never remove unrelated
# payloads.
#
# Efficiency: the extracted library is cached at
#   /mmc/root/.skinny-tools-cache/hak5-library/
# so subsequent runs skip the GitHub download entirely and just diff the
# cached manifest against the Pager's filesystem. Delete that directory to
# force a fresh download. With --offline, the cache is required.
# ==========================================
if [ "$DO_HAK5" = "1" ]; then
  HAK5_CACHE_ROOT="/mmc/root/.skinny-tools-cache"
  HAK5_CACHE="$HAK5_CACHE_ROOT/hak5-library"

  if [ -d "$HAK5_CACHE/alerts" ] && [ -d "$HAK5_CACHE/user" ] && [ -d "$HAK5_CACHE/recon" ]; then
    echo "[*] Using cached Hak5 payload library at $HAK5_CACHE (delete to force refresh)"
    HAK5_SRC="$HAK5_CACHE"
  elif [ "$OFFLINE" = "1" ]; then
    echo "[-] Critical Error: --offline was requested, but no Hak5 library cache exists at:"
    echo "      $HAK5_CACHE"
    echo "    Run once with internet access to populate it, or seed it manually."
    exit 1
  else
    echo "[*] Fetching Hak5 payload library from github.com/hak5/wifipineapplepager-payloads..."

    HAK5_TARBALL_URL="https://github.com/hak5/wifipineapplepager-payloads/archive/refs/heads/master.tar.gz"
    HAK5_STAGE="$(mktemp -d -t hak5-payloads.XXXXXX)"

    # wget is the Pager's default fetcher; fall back to curl if missing.
    if command -v wget >/dev/null 2>&1; then
      if ! wget -qO "$HAK5_STAGE/hak5.tar.gz" "$HAK5_TARBALL_URL"; then
        echo "[-] Critical Error: wget failed to download Hak5 tarball."
        exit 1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL -o "$HAK5_STAGE/hak5.tar.gz" "$HAK5_TARBALL_URL"; then
        echo "[-] Critical Error: curl failed to download Hak5 tarball."
        exit 1
      fi
    else
      echo "[-] Critical Error: neither wget nor curl is available on this Pager."
      exit 1
    fi

    if ! tar -xzf "$HAK5_STAGE/hak5.tar.gz" -C "$HAK5_STAGE" 2>/dev/null; then
      echo "[-] Critical Error: tar failed to extract Hak5 tarball."
      exit 1
    fi

    HAK5_SRC="$HAK5_STAGE/wifipineapplepager-payloads-master/library"
    if [ ! -d "$HAK5_SRC" ]; then
      echo "[-] Critical Error: expected library/ folder missing in Hak5 tarball."
      exit 1
    fi

    # Persist the extracted library to /mmc so future runs skip the download.
    mkdir -p "$HAK5_CACHE_ROOT"
    rm -rf "$HAK5_CACHE"
    cp -r "$HAK5_SRC" "$HAK5_CACHE"
    HAK5_SRC="$HAK5_CACHE"
    echo "[+] Hak5 library cached at $HAK5_CACHE for future runs."
  fi

  mkdir -p "$SYSTEM_PAYLOADS_DEST"

  HAK5_NEW=0
  HAK5_UPDATED=0
  HAK5_PRESENT=0
  HAK5_FAILED=""
  MERGE_NEW_LABELS=""
  MERGE_UPDATED_LABELS=""
  MERGE_PRESENT_LABELS=""
  MERGE_FAILED_LABELS=""
  MERGE_SKIPPED_LABELS=""
  MERGE_REPAIRED_LABELS=""
  MERGE_DUPLICATE_LABELS=""

  # Hak5's library/ tree is nested at every level:
  #   alerts/<category>/<payload>/
  #   recon/<subtree>/<payload>/
  #   user/<factory>/<payload>/
  # Walk each category/factory folder individually so merge_payload_category
  # receives a directory whose direct children are payloads. This is what
  # makes the DISABLED.<name> resolution and per-payload logging work for
  # Hak5 payloads too (a one-level walk over alerts/ would treat the whole
  # category as one payload and never see the nested DISABLED. names).
  for alert_cat in "$HAK5_SRC/alerts"/*; do
    [ -d "$alert_cat" ] || continue
    alert_name="$(basename "$alert_cat")"
    merge_payload_category "$alert_cat" \
                           "$SYSTEM_PAYLOADS_DEST/alerts/$alert_name" \
                           "alerts/$alert_name"
  done
  for subtree in "$HAK5_SRC/recon"/*; do
    [ -d "$subtree" ] || continue
    subtree_name="$(basename "$subtree")"
    merge_payload_category "$subtree" \
                           "$SYSTEM_PAYLOADS_DEST/recon/$subtree_name" \
                           "recon/$subtree_name"
  done
  for factory_dir in "$HAK5_SRC/user"/*; do
    [ -d "$factory_dir" ] || continue
    factory_name="$(basename "$factory_dir")"
    merge_payload_category "$factory_dir" \
                           "$SYSTEM_PAYLOADS_DEST/user/$factory_name" \
                           "user/$factory_name"
  done

  HAK5_NEW=$(echo "$MERGE_NEW_LABELS" | wc -w)
  HAK5_UPDATED=$(echo "$MERGE_UPDATED_LABELS" | wc -w)
  HAK5_PRESENT=$(echo "$MERGE_PRESENT_LABELS" | wc -w)
  HAK5_FAILED="$MERGE_FAILED_LABELS"

  # Ensure any launcher scripts Hak5 ships with executable bit set.
  for tree in alerts recon user; do
    if [ -d "$SYSTEM_PAYLOADS_DEST/$tree" ]; then
      find "$SYSTEM_PAYLOADS_DEST/$tree" -name "*.sh" -exec chmod +x {} \; 2>/dev/null
    fi
  done

  echo "[*] Hak5 payload summary: $HAK5_NEW new, $HAK5_UPDATED updated, $HAK5_PRESENT unchanged."
  if [ -n "$HAK5_FAILED" ]; then
    echo "[!] WARNING: failed to copy Hak5 payloads:$HAK5_FAILED"
  fi
  echo "[+] Hak5 payload library merged into $SYSTEM_PAYLOADS_DEST/"
fi

# ==========================================
# PHASE 1B: Skinny-Tools Source Resolution (S/B/C)
# ==========================================
# Strategy: use upstream HEAD as the source of truth when online. The local
# clone sitting next to the script is a fallback for users who don't maintain
# a full copy. With --offline, the local working tree is preferred (so
# deliberate local changes are testable), then the cached snapshot.
#
# Fetch order (online):
#   1. GitHub tarball. On success, refresh the cache and use it.
#   2. On failure: the existing cache.
#   3. Then the local clone (git archive HEAD, or working tree).
#   4. Otherwise: critical error.
#
# Offline order:
#   1. Local repo working tree, if complete.
#   2. Cached snapshot.
#   3. Otherwise: critical error.
# ==========================================
if [ "$DO_SKINNY" = "1" ]; then
  SKINNY_CACHE_ROOT="/mmc/root/.skinny-tools-cache"
  SKINNY_CACHE="$SKINNY_CACHE_ROOT/skinny-tools"
  SKINNY_TARBALL_URL="https://github.com/skinnyrad/Skinny-Pager-Payloads/archive/refs/heads/main.tar.gz"

  SKINNY_SRC=""
  SKINNY_STAGE=""

  local_repo_complete() {
    [ -d "$LOCAL_PAYLOADS_DIR" ] && [ -d "$CROSS_TOOLS_DIR" ] && \
      [ -f "$REPO_DIR/pagerctl.py" ] && [ -f "$REPO_DIR/libpagerctl.so" ]
  }

  cache_complete() {
    [ -d "$SKINNY_CACHE/payloads" ] && \
      [ -d "$SKINNY_CACHE/cross-compiled-pager-tools" ] && \
      [ -f "$SKINNY_CACHE/pagerctl.py" ] && \
      [ -f "$SKINNY_CACHE/libpagerctl.so" ]
  }

  if [ "$OFFLINE" = "1" ]; then
    echo "[*] Offline mode: skipping GitHub fetch."
    if local_repo_complete; then
      echo "[*] Offline mode: using local repo at $REPO_DIR (working tree)."
      SKINNY_SRC="$REPO_DIR"
    elif cache_complete; then
      echo "[*] Offline mode: using cached Skinny-Tools snapshot at $SKINNY_CACHE."
      SKINNY_SRC="$SKINNY_CACHE"
    else
      echo "[-] Critical Error: --offline was requested, but no complete local repo"
      echo "    or cached Skinny-Tools snapshot is available."
      echo "    Expected: $REPO_DIR/payloads + cross-compiled-pager-tools/"
      echo "    or:       $SKINNY_CACHE/"
      exit 1
    fi
  else
    echo "[*] Fetching Skinny-Tools from github.com/skinnyrad/Skinny-Pager-Payloads..."
    SKINNY_STAGE="$(mktemp -d -t skinny-tools.XXXXXX)"

    fetch_ok=0
    if command -v wget >/dev/null 2>&1; then
      if wget -qO "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL" 2>/dev/null; then
        fetch_ok=1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -fsSL -o "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL" 2>/dev/null; then
        fetch_ok=1
      fi
    else
      echo "[-] Critical Error: neither wget nor curl is available on this Pager."
      exit 1
    fi

    if [ "$fetch_ok" = "1" ]; then
      if ! tar -xzf "$SKINNY_STAGE/skinny.tar.gz" -C "$SKINNY_STAGE" 2>/dev/null; then
        echo "[-] Critical Error: tar failed to extract Skinny-Tools tarball."
        exit 1
      fi
      # GitHub tarballs extract to <repo-name>-<branch>/; discover whatever
      # directory tar created so branch renames don't require a script edit.
      SKINNY_SRC="$(find "$SKINNY_STAGE" -mindepth 1 -maxdepth 1 -type d ! -name '*.tar.gz' | head -n 1)"
      if [ -z "$SKINNY_SRC" ] || [ ! -d "$SKINNY_SRC/payloads" ]; then
        echo "[-] Critical Error: extracted Skinny-Tools repo is missing payloads/."
        exit 1
      fi
      # Refresh the cache with the freshly extracted content so the next
      # offline run still has a recent snapshot to fall back to.
      mkdir -p "$SKINNY_CACHE_ROOT"
      rm -rf "$SKINNY_CACHE"
      cp -r "$SKINNY_SRC" "$SKINNY_CACHE"
      SKINNY_SRC="$SKINNY_CACHE"
      echo "[+] Skinny-Tools cache refreshed at $SKINNY_CACHE."
    else
      echo "[!] Failed to download Skinny-Tools tarball from GitHub."
      if cache_complete; then
        echo "[*] Falling back to cached Skinny-Tools snapshot at $SKINNY_CACHE (may be stale)."
        SKINNY_SRC="$SKINNY_CACHE"
      elif local_repo_complete; then
        # Materialize a clean copy of HEAD from the local clone via `git
        # archive` rather than pointing at the working tree directly. This
        # respects the tracked index and skips untracked / .gitignored
        # files (e.g. dev-only payloads sitting in the working tree) so a
        # polluted working copy can't poison the Pager's payload set on
        # a fallback run. Falls back to the raw working tree only when
        # git is unavailable or the archive fails.
        if command -v git >/dev/null 2>&1 && [ -d "$REPO_DIR/.git" ]; then
          echo "[!] No cache available; materializing local clone at $REPO_DIR via 'git archive HEAD' (may be stale)."
          LOCAL_STAGE="$(mktemp -d -t skinny-local-archive.XXXXXX)"
          trap 'rm -rf "$HAK5_STAGE" "$SKINNY_STAGE" "$MERGE_TMP" "$LOCAL_STAGE" 2>/dev/null' EXIT
          if git -C "$REPO_DIR" archive --format=tar HEAD 2>/dev/null | tar -xf - -C "$LOCAL_STAGE" 2>/dev/null && \
             [ -d "$LOCAL_STAGE/payloads" ] && [ -d "$LOCAL_STAGE/cross-compiled-pager-tools" ] && \
             [ -f "$LOCAL_STAGE/pagerctl.py" ] && [ -f "$LOCAL_STAGE/libpagerctl.so" ]; then
            SKINNY_SRC="$LOCAL_STAGE"
          else
            echo "[!] 'git archive' failed or produced an incomplete tree; falling back to working tree at $REPO_DIR (untracked files may leak)."
            rm -rf "$LOCAL_STAGE"
            SKINNY_SRC="$REPO_DIR"
          fi
        else
          echo "[!] No cache available and no git binary; falling back to working tree at $REPO_DIR (untracked files may leak)."
          SKINNY_SRC="$REPO_DIR"
        fi
      else
        echo "[-] Critical Error: no Skinny-Tools source available (no internet, no cache, no local clone)."
        exit 1
      fi
    fi
  fi

  REPO_DIR="$SKINNY_SRC"
  LOCAL_PAYLOADS_DIR="$REPO_DIR/payloads"
  CROSS_TOOLS_DIR="$REPO_DIR/cross-compiled-pager-tools"
  echo "[+] Using Skinny-Tools source: $REPO_DIR"
fi

# ==========================================
# PHASE 2: Pre-flight Dependency Check
# ==========================================
# Skinny profiles (S/B/C) only. Hak5-only runs (H) are just a payload
# pull, so they don't need python3, airodump-ng, the cross-compiled tools,
# or the PagerCTL shims.
if [ "$DO_SKINNY" = "1" ]; then
# --------------------------------------------------------------------------
# Dependency inventory (what the repo's payloads actually require)
# --------------------------------------------------------------------------
# The full profile keeps the historical mandatory list. The Pager Class
# profile installs only what its guaranteed payloads need:
#   python3-base/light  foxhunt_AP/clients, PagerCTL
#   python3-ctypes      foxhunt_AP/clients, PagerCTL
#   aircrack-ng         Aireplay-ng-AP-Deauth, foxhunt_AP/clients
#   sqlite3-cli         PMF-Checker
#   bluez-utils         hcitool/hciconfig (Skinny-Skim-Scanner)
#   bluez-utils-btmon   btmon (Skinny-Skim-Scanner)
# Quick-Brown-Fox-AP and WiFi-Client-Tracker-Targeted use iw, gps-mgmtap-nmea
# uses the factory gpsd service, and both are assumed present/factory.
# --------------------------------------------------------------------------

if [ "$DEP_PROFILE" = "class" ]; then
  REQUIRED_PKGS="$CLASS_PKGS"
  REQUIRED_BINS="$CLASS_BINS"
  REQUIRED_MODS="$CLASS_MODS"
  PROFILE_LABEL="Pager Class"
else
  REQUIRED_PKGS="python3 python3-base python3-light python3-ctypes \
                 python3-email python3-urllib python3-logging python3-decimal \
                 python3-codecs libffi libbz2-1.0 zlib libpcap libopenssl \
                 libpcre2 libnl-core200 libnl-genl200 sqlite3-cli hostapd-utils \
                 aircrack-ng tcpdump umdns bluez-utils bluez-utils-btmon \
                 bluez-tools hcxtools nftables-json kmod-mt76-usb \
                 iw libev scapy"
  # Binaries that must all exist after provisioning. Keep this in sync with
  # the packages above -- the verification loop below hard-fails if any are
  # absent.
  REQUIRED_BINS="tcpdump aircrack-ng airodump-ng aireplay-ng python3 sqlite3 \
hostapd_cli nft whoismac btmon hcitool hciconfig iw"
  REQUIRED_MODS="ctypes http.server email urllib.request re socket struct zlib \
select hashlib hmac threading argparse scapy"
  PROFILE_LABEL="full"
fi

echo "[*] Running pre-flight dependency check ($PROFILE_LABEL profile)..."
echo "[*] Verifying required tools ..."
MISSING_TOOLS=""
for tool in $REQUIRED_BINS; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done

echo "[*] Verifying required python3 modules ..."
MISSING_MODS=""
for m in $REQUIRED_MODS; do
  python3 -c "import $m" >/dev/null 2>&1 || MISSING_MODS="$MISSING_MODS $m"
done

if [ -z "$MISSING_TOOLS" ] && [ -z "$MISSING_MODS" ]; then
  echo "[+] All required tools and python3 modules present."
else
  [ -n "$MISSING_TOOLS" ] && echo "[*] Missing tools:$MISSING_TOOLS"
  [ -n "$MISSING_MODS" ]  && echo "[*] Missing python3 modules:$MISSING_MODS"
  if [ "$OFFLINE" = "1" ]; then
    echo "[-] Critical Error: --offline was requested, but dependencies are missing."
    echo "    Install them once from a feed-enabled run, or seed the .ipk files"
    echo "    manually. Missing tools:${MISSING_TOOLS:- none}"
    echo "    Missing modules:${MISSING_MODS:- none}"
    exit 1
  fi
  echo "[*] Synchronizing OpenWrt package ecosystem lists..."
  opkg update || { echo "[-] Critical Error: opkg update failed!"; exit 1; }
  echo "[*] Provisioning $PROFILE_LABEL dependencies..."
  # shellcheck disable=SC2086
  opkg install $REQUIRED_PKGS
  # Re-verify -- every dependency is mandatory, so any remaining gap aborts.
  STILL_TOOLS=""
  for tool in $REQUIRED_BINS; do
    command -v "$tool" >/dev/null 2>&1 || STILL_TOOLS="$STILL_TOOLS $tool"
  done
  STILL_MODS=""
  for m in $REQUIRED_MODS; do
    python3 -c "import $m" >/dev/null 2>&1 || STILL_MODS="$STILL_MODS $m"
  done
  if [ -n "$STILL_TOOLS" ] || [ -n "$STILL_MODS" ]; then
    echo "[-] Critical Error: still missing after install:"
    [ -n "$STILL_TOOLS" ] && echo "      tools:$STILL_TOOLS"
    [ -n "$STILL_MODS" ]  && echo "      modules:$STILL_MODS"
    echo "    These are mandatory; refusing to continue with a partial install."
    exit 1
  fi
  echo "[+] Required dependencies satisfied."
fi

# Pager Class: warn about optional/factory dependencies.
if [ "$DEP_PROFILE" = "class" ]; then
  command -v iw >/dev/null 2>&1 || \
    echo "[!] Warning: iw is missing; Quick-Brown-Fox-AP and WiFi-Client-Tracker-Targeted need it."
  [ -x /etc/init.d/gpsd ] || \
    echo "[!] Warning: gpsd service not found; gps-mgmtap-nmea needs it."
  [ -d /root/recon ] || \
    echo "[!] Warning: /root/recon not found; PMF-Checker expects the factory recon database."
fi

# --------------------------------------------------------------------------
# AWDL-Stim (Apple AWDL stimulation) extra dependency: avahi-daemon on /mmc
# --------------------------------------------------------------------------
# The AWDL Stim payload advertises a fake AirPlay2/AirPlay service to draw
# nearby iPhones, and its wake script invokes the daemon by absolute path
# (/mmc/usr/sbin/avahi-daemon). avahi must therefore be installed to the
# /mmc dest (not the root overlay). Install the daemon and its support
# library together so the dynamic loader finds libavahi on /mmc/usr/lib.
# Only the full profile installs AWDL-Stim.
if [ "$DEP_PROFILE" = "full" ]; then
  if [ ! -x /mmc/usr/sbin/avahi-daemon ]; then
    if [ "$OFFLINE" = "1" ]; then
      echo "[!] Offline mode: avahi-daemon not present on /mmc; skipping install."
    else
      echo "[*] Provisioning avahi-daemon to /mmc (AWDL-Stim AirPlay lure)..."
      opkg install -d mmc avahi-nodbus-daemon libavahi-nodbus-support || true
    fi
  fi
  if [ -x /mmc/usr/sbin/avahi-daemon ]; then
    echo "[+] avahi-daemon present on /mmc (AWDL-Stim lure ready)."
  else
    echo "[!] Warning: avahi-daemon is not on /mmc; AWDL-Stim's lure will not start."
  fi
fi

# Seed the hcxtools OUI database that `whoismac` reads from ~/.hcxtools/oui.txt.
# StripConnectedClients (and PNL's whoismac fallback) call `whoismac -m`, which
# fails with "failed read oui.txt" unless ~/.hcxtools/oui.txt exists. The Pager
# ships a factory OUI DB at /lib/hak5/oui.txt (tab-separated, same format), so
# seed from it when the user's copy is missing.
if command -v whoismac >/dev/null 2>&1; then
  if [ ! -s "$HOME/.hcxtools/oui.txt" ] && [ -s /lib/hak5/oui.txt ]; then
    mkdir -p "$HOME/.hcxtools"
    cp /lib/hak5/oui.txt "$HOME/.hcxtools/oui.txt"
    echo "[+] Seeded ~/.hcxtools/oui.txt from /lib/hak5/oui.txt (whoismac vendor lookup)."
  else
    echo "[+] whoismac OUI database present."
  fi
fi

# Dynamically locate the newly active Python site-packages folder
PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
if [ -z "$PYTHON_SITE_DIR" ]; then
    echo "[-] Error: Python 3 ecosystem failed to initialize cleanly!"
    exit 1
fi
echo "[+] Target Python Environment Verified: $PYTHON_SITE_DIR"

# ==========================================
# PHASE 3: Cross-Compiled .ipk Discovery & Install
# ==========================================
if [ "$DEP_PROFILE" != "full" ]; then
  echo "[*] $PROFILE_LABEL: cross-compiled .ipk install skipped."
else
echo "[*] Scanning cross-compiled-pager-tools/ for cross-compiled .ipk packages..."

if [ ! -d "$CROSS_TOOLS_DIR" ]; then
  echo "[!] No cross-compiled-pager-tools/ directory in repo. Skipping .ipk install."
else
  # NOTE: */awdl/* and */wpad-wolfssl/* are excluded. The awdl .ipk's are
  # vendored only for the OFFLINE installer; online installs get iw/libev/
  # scapy from the OpenWrt feed and avahi to /mmc (see the AWDL-Stim block
  # in Phase 2). Installing them from here would land avahi on the root
  # overlay, which the AWDL-Stim payload does not use.
  IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f ! -name "._*" 2>/dev/null \
                ! -path "*/wpad-wolfssl/*" ! -path "*/awdl/*" | sort)

  if [ -z "$IPK_FILES" ]; then
    echo "[!] No .ipk files found under $CROSS_TOOLS_DIR. Skipping."
  else
    IPK_COUNT=$(echo "$IPK_FILES" | wc -l)
    echo "[*] Discovered $IPK_COUNT .ipk package(s):"
    for ipk in $IPK_FILES; do
      echo "    - ${ipk#$REPO_DIR/}"
    done

    # Split into library and tool .ipk files; libraries install first so
    # cross-package dependencies resolve cleanly for the binaries.
    LIBS=""
    TOOLS=""
    for ipk in $IPK_FILES; do
      case "$(basename "$ipk")" in
        lib*) LIBS="$LIBS
$ipk" ;;
        *)    TOOLS="$TOOLS
$ipk" ;;
      esac
    done
    # Strip the leading newline injected by the loop above.
    LIBS=$(echo "$LIBS" | sed '/^$/d')
    TOOLS=$(echo "$TOOLS" | sed '/^$/d')

    FAILED=""
    INSTALLED=0
    ALREADY_PRESENT=0

    install_ipk_batch() {
      label="$1"
      files="$2"
      [ -z "$files" ] && return 0
      echo "[*] Installing $label .ipk file(s)..."
      for ipk in $files; do
        rel="${ipk#$REPO_DIR/}"
        # Derive the opkg package name (same parsing as the uninstall path
        # in --uninstall) so we can pre-check installed state via opkg and
        # avoid re-running opkg install for packages that are already
        # current. opkg install is fast on a hit but skips cleanly here.
        pkg=$(basename "$ipk" .ipk | sed 's/_[0-9][^_]*_mipsel.*$//')
        if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
          echo "    [skip] $rel (already installed: $pkg)"
          ALREADY_PRESENT=$((ALREADY_PRESENT + 1))
          continue
        fi
        echo "    -> $rel"
        # Capture opkg output and exit code separately so we can flag failures
        OPKG_OUT=$(opkg install "$ipk" 2>&1)
        OPKG_RC=$?
        echo "$OPKG_OUT" | sed 's/^/       /'
        if [ "$OPKG_RC" -ne 0 ]; then
          echo "       [ERROR] opkg install returned non-zero for $rel"
          FAILED="$FAILED $rel"
        else
          INSTALLED=$((INSTALLED + 1))
        fi
      done
    }

    install_ipk_batch "library" "$LIBS"
    install_ipk_batch "tool"    "$TOOLS"

    echo "[*] .ipk install summary: $INSTALLED installed, $ALREADY_PRESENT already present."
    if [ -n "$FAILED" ]; then
      echo "[!] WARNING: the following .ipk(s) failed to install:$FAILED"
      echo "    The script will continue, but the affected tools may not work."
    elif [ "$INSTALLED" = "0" ] && [ "$ALREADY_PRESENT" -gt 0 ]; then
      echo "[+] All .ipk packages already installed; nothing to do."
    else
      echo "[+] All .ipk packages installed successfully."
    fi
  fi
fi
fi

# ==========================================
# PHASE 3.5: wpad-swap asset staging (non-destructive Passpoint support)
# ==========================================
# The ATT/Passpoint payloads need wpad-wolfssl for its compiled-in Hotspot2.0 /
# Interworking / EAP-AKA / EAP-SIM support. Installing wpad-wolfssl via opkg
# would REMOVE the factory wpad-basic-mbedtls (it Conflicts:), breaking stock
# Pager/PineAP behavior. Instead we extract the pinned wolfssl binaries into
# /mmc/root/wpad-swap/ and install ONLY the libwolfssl shared object
# additively; the wpad-swap engine bind-mounts the rest over /usr/sbin/*
# on demand and always restores the factory wpad on exit.
if [ "$DEP_PROFILE" != "full" ]; then
  echo "[*] $PROFILE_LABEL: wpad-swap staging skipped."
else
WPAD_ASSET_DIR="$CROSS_TOOLS_DIR/wpad-wolfssl"
if [ -d "$WPAD_ASSET_DIR" ]; then
  echo "[*] Staging wpad-swap (Passpoint) assets from $WPAD_ASSET_DIR..."
  if ! command -v python3 >/dev/null 2>&1; then
    : # staging shells out to tar; python3 not required here
  fi
  TMPSTAGE=$(mktemp -d /tmp/wpad-assets.XXXXXX)
  # 1. extract the wolfssl ELF (wpad == hostapd == wpa_supplicant, argv[0] dispatch)
  tar -xzOf "$WPAD_ASSET_DIR"/wpad-wolfssl_*.ipk ./data.tar.gz 2>/dev/null \
    | tar -xzO ./usr/sbin/wpad > "$TMPSTAGE/wpad-wolfssl" 2>/dev/null
  if [ -s "$TMPSTAGE/wpad-wolfssl" ]; then
    cp "$TMPSTAGE/wpad-wolfssl" "$TMPSTAGE/hostapd-wolfssl"
    cp "$TMPSTAGE/wpad-wolfssl" "$TMPSTAGE/wpa_supplicant-wolfssl"
  fi
  # 2. extract libwolfssl
  tar -xzOf "$WPAD_ASSET_DIR"/libwolfssl5.9.1.e624513f_*.ipk ./data.tar.gz 2>/dev/null \
    | tar -xzO ./usr/lib/libwolfssl.so.5.9.1.e624513f > "$TMPSTAGE/libwolfssl.so.5.9.1.e624513f" 2>/dev/null

  if [ -s "$TMPSTAGE/wpad-wolfssl" ] && [ -s "$TMPSTAGE/libwolfssl.so.5.9.1.e624513f" ]; then
    mkdir -p /mmc/root/wpad-swap
    # Recompose (LF only) so the hashes match the engine's manifest.
    for f in wpad-wolfssl hostapd-wolfssl wpa_supplicant-wolfssl \
             libwolfssl.so.5.9.1.e624513f; do
      cp "$TMPSTAGE/$f" /mmc/root/wpad-swap/$f 2>/dev/null || true
    done
    chmod 755 /mmc/root/wpad-swap/wpad-wolfssl \
              /mmc/root/wpad-swap/hostapd-wolfssl \
              /mmc/root/wpad-swap/wpa_supplicant-wolfssl 2>/dev/null || true
    chmod 644 /mmc/root/wpad-swap/libwolfssl.so.5.9.1.e624513f 2>/dev/null || true
    echo "[+] wpad-swap assets staged in /mmc/root/wpad-swap/"

    # 3. hand verification + libwolfssl install to the engine (it validates the
    #    pinned hashes and copies libwolfssl to /usr/lib additively).
    ENGINE_SRC="$REPO_DIR/payloads/user/utilities/WPAD-SWAP/wpad-swap.sh"
    if [ -f "$ENGINE_SRC" ]; then
      ( cd "$REPO_DIR/payloads/user/utilities/WPAD-SWAP" && sh ./wpad-swap.sh stage ) \
        && echo "[+] wpad-swap stage verified (libwolfssl installed additively)." \
        || echo "[!] wpad-swap stage reported a verification failure; check the assets."
    else
      echo "[!] wpad-swap engine not found in repo; assets staged but not verified."
    fi
  else
    echo "[!] Could not extract wpad-wolfssl assets from the vendored .ipk files."
    echo "    Passpoint ATT modes will be unavailable until this is fixed."
  fi
  rm -rf "$TMPSTAGE"
else
  echo "[!] No cross-compiled-pager-tools/wpad-wolfssl/ directory; skipping Passpoint staging."
fi
fi

# ==========================================
# PHASE 4: Repository Payload Tree Mirroring
# ==========================================
echo "[*] Syncing custom security payloads to local hardware storage..."

if [ -d "$LOCAL_PAYLOADS_DIR" ]; then
    MERGE_NEW_LABELS=""
    MERGE_UPDATED_LABELS=""
    MERGE_PRESENT_LABELS=""
    MERGE_FAILED_LABELS=""
    MERGE_SKIPPED_LABELS=""
    MERGE_REPAIRED_LABELS=""
    MERGE_DUPLICATE_LABELS=""

    # Walk every top-level category and every middle-level container. For
    # alerts and recon the middle level is the event/subtree; for user it is
    # the Skinny factory tree (Skinny-Tools, utilities). This keeps future
    # categories working without adding another hardcoded call.
    for top in alerts recon user; do
      for mid in "$LOCAL_PAYLOADS_DIR/$top"/*; do
        [ -d "$mid" ] || continue
        mid_name="$(basename "$mid")"
        merge_payload_category "$mid" \
                               "$SYSTEM_PAYLOADS_DEST/$top/$mid_name" \
                               "$top/$mid_name"
      done
    done

    # Enforce global executable permissions across launcher scripts.
    find "$SYSTEM_PAYLOADS_DEST" -name "*.sh" -exec chmod +x {} \; 2>/dev/null
    # Purge macOS AppleDouble sidecars / .DS_Store that may have been left
    # by a previous run (or copied in by an older installer version).
    find "$SYSTEM_PAYLOADS_DEST" -name '._*' -type f -exec rm -f {} \; 2>/dev/null
    find "$SYSTEM_PAYLOADS_DEST" -name '.DS_Store' -type f -exec rm -f {} \; 2>/dev/null

    # Verify the two required custom folder landing zones exist on disk.
    # The recon/<subtree> skeletons always exist (factory default) so we
    # don't need to verify them here - they were just populated by the
    # helper calls above.
    for required in Skinny-Tools utilities; do
      if [ ! -d "$SYSTEM_PAYLOADS_DEST/user/$required" ]; then
        echo "[-] Critical Error: required payload folder missing: $SYSTEM_PAYLOADS_DEST/user/$required"
        exit 1
      fi
    done
    echo "[+] Verified: payloads/user/Skinny-Tools, payloads/user/utilities, payloads/recon/access_point, payloads/recon/client are in place."

    NEW_COUNT=$(echo "$MERGE_NEW_LABELS" | wc -w)
    UPDATED_COUNT=$(echo "$MERGE_UPDATED_LABELS" | wc -w)
    PRESENT_COUNT=$(echo "$MERGE_PRESENT_LABELS" | wc -w)
    SKIPPED_COUNT=$(echo "$MERGE_SKIPPED_LABELS" | wc -w)
    REPAIRED_COUNT=$(echo "$MERGE_REPAIRED_LABELS" | wc -w)
    echo "[*] Payload summary: $NEW_COUNT new, $UPDATED_COUNT updated, $PRESENT_COUNT unchanged, $SKIPPED_COUNT skipped."
    [ "$REPAIRED_COUNT" != "0" ] && \
      echo "[*] Repaired duplicate payload copies: $MERGE_REPAIRED_LABELS"
    [ -n "$MERGE_DUPLICATE_LABELS" ] && \
      echo "[!] Unresolved duplicate payloads (manual cleanup needed): $MERGE_DUPLICATE_LABELS"
    echo "[+] Payloads synced to $SYSTEM_PAYLOADS_DEST/"
else
    echo "[-] Error: 'payloads' folder missing from the cloned Git repository!"
    exit 1
fi

# ==========================================
# PHASE 5: Global PagerCTL Environment Setup
# ==========================================
echo "[*] Establishing system hardware translation symlinks..."

PAGERCTL_SRC_DIR="$SYSTEM_PAYLOADS_DEST/user/utilities/PAGERCTL"

# Fallback checking inside the repository folder itself if utilities structure alters
if [ ! -d "$PAGERCTL_SRC_DIR" ]; then
    PAGERCTL_SRC_DIR="$REPO_DIR"
fi

# Clean up any dead legacy links
rm -f /usr/lib/libpagerctl.so
rm -f "$PYTHON_SITE_DIR/pagerctl.py"
rm -f "$PYTHON_SITE_DIR/libpagerctl.so"

# Create global symbolic mappings to link the hardware libraries directly into Python
if [ -f "$PAGERCTL_SRC_DIR/pagerctl.py" ] && [ -f "$PAGERCTL_SRC_DIR/libpagerctl.so" ]; then
    ln -s "$PAGERCTL_SRC_DIR/pagerctl.py" "$PYTHON_SITE_DIR/pagerctl.py"
    ln -s "$PAGERCTL_SRC_DIR/libpagerctl.so" /usr/lib/libpagerctl.so
    ln -s "$PAGERCTL_SRC_DIR/libpagerctl.so" "$PYTHON_SITE_DIR/libpagerctl.so"
    echo "[+] Global Hardware Interface Links configured."
else
    echo "[-] Error: Could not locate 'pagerctl.py' or 'libpagerctl.so' in payload paths!"
    exit 1
fi

# ==========================================
# PHASE 6: Functional Verification Check
# ==========================================
echo "========================================================="
echo "[*] Verification Phase..."
echo "========================================================="

VERIFY_CMD="python3 -c 'from pagerctl import Pager; print(\"[+] Python Verification: PagerCTL Loaded Natively.\")' 2>&1"
eval $VERIFY_CMD
VERIFY_RC=$?

if [ "$DEP_PROFILE" = "class" ]; then
    echo "[*] Verifying Pager Class payload set..."
    MISSING_CLASS=""
    for p in $CLASS_REQUIRED_PAYLOADS; do
        parent="$(dirname "$p")"
        base="$(basename "$p")"
        case "$p" in
            alerts/*)
                if [ -d "$SYSTEM_PAYLOADS_DEST/$p" ] || \
                   [ -d "$SYSTEM_PAYLOADS_DEST/$parent/DISABLED.$base" ]; then
                    :
                else
                    MISSING_CLASS="$MISSING_CLASS $p"
                fi
                ;;
            *)
                [ -d "$SYSTEM_PAYLOADS_DEST/$p" ] || \
                    MISSING_CLASS="$MISSING_CLASS $p"
                ;;
        esac
    done
    if [ -n "$MISSING_CLASS" ]; then
        echo "[-] Critical Error: Pager Class payload(s) missing:$MISSING_CLASS"
        exit 1
    fi
    echo "[+] Pager Class payload set verified (9/9)."
fi

if [ "$VERIFY_RC" -eq 0 ]; then
    if [ "$DEP_PROFILE" = "class" ]; then
        echo "[+++++] SUCCESS: Pager Class deployment complete."
        echo "[*] Guaranteed payloads: foxhunt_AP, foxhunt_clients,"
        echo "    Aireplay-ng-AP-Deauth, PMF-Checker, Quick-Brown-Fox-AP,"
        echo "    Skinny-Skim-Scanner, gps-mgmtap-nmea,"
        echo "    WiFi-Client-Tracker-Targeted, PAGERCTL."
        echo "[*] Cross-compiled toolset was intentionally skipped."
    else
        echo "[+++++] SUCCESS: Entire deployment is 100% complete and fully optimized!"
        echo "[*] Pager is ready for immediate operation from the hardware UI menus."
    fi
else
    echo "[-] Warning: Setup finished but the validation test returned an environment alert."
fi
fi

# End of Skinny install block. Hak5-only runs (SELECTION=H) skip everything
# inside the conditional above and exit cleanly here.
