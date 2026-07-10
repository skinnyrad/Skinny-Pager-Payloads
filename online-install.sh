#!/bin/sh
# Title: Git Repository Live Online Installer (Python, Security Tools, & Payloads)
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
#
# Install phases:
#   1. Internet connectivity check
#   2. Pre-flight dependency check (tcpdump, aircrack-ng, python3)
#   3. Recursive .ipk discovery & install under cross-compiled-pager-tools/
#   4. Payload tree mirror with new-payload detection
#   5. Global pagerctl hardware-interface symlinks
#   6. Verification & summary
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
case "${1:-}" in
  --uninstall|-u) MODE="uninstall" ;;
  --help|-h)
    cat <<EOF
Usage: $0 [--uninstall] [--help]

Default (no flag):  Install / update Skinny-Tools on the Pager.
  --uninstall, -u:   Remove all Skinny-Tools customizations (cross-compiled
                   tool .ipk packages, custom payload directories, and
                   PagerCTL hardware-interface symlinks). Preserves all
                   Hak5 factory payloads. Cross-compiled library packages
                   (lib* .ipk files) and pre-flight system packages
                   (python3, aircrack-ng, tcpdump, etc.) are NOT removed;
                   the summary lists the manual command to remove them
                   if a full factory reset is desired.
--help, -h:        Show this help.

Run from inside the cloned Skinny-Tools repository so the script can
discover payloads/ and cross-compiled-pager-tools/.
EOF
    exit 0
    ;;
  "") MODE="install" ;;
  *)
    echo "[-] Unknown argument: $1"
    echo "    Run '$0 --help' for usage."
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
    IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f 2>/dev/null | sort)
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
    # Walk payloads/user/<tree>/* and payloads/recon/<tree>/* in the repo
    # and remove the matching names from the system destination. Hak5
    # factory payloads outside our repo tree are untouched.
    for tree in Skinny-Tools utilities; do
      src="$LOCAL_PAYLOADS_DIR/user/$tree"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        dst="$SYSTEM_PAYLOADS_DEST/user/$tree/$name"
        if [ -d "$dst" ]; then
          echo "    -> user/$tree/$name"
          rm -rf "$dst"
          REMOVED=$((REMOVED + 1))
        else
          echo "    [skip] user/$tree/$name (not present)"
          SKIPPED=$((SKIPPED + 1))
        fi
      done
    done

    for tree in access_point client; do
      src="$LOCAL_PAYLOADS_DIR/recon/$tree"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        dst="$SYSTEM_PAYLOADS_DEST/recon/$tree/$name"
        if [ -d "$dst" ]; then
          echo "    -> recon/$tree/$name"
          rm -rf "$dst"
          REMOVED=$((REMOVED + 1))
        else
          echo "    [skip] recon/$tree/$name (not present)"
          SKIPPED=$((SKIPPED + 1))
        fi
      done
    done
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
  echo ""
  echo "[*] Preserved (not removed):"
  echo "    - Hak5 factory payloads (alerts/, recon/ factory entries,"
  echo "      user/<factory folders like evil_portal, prank, ...>)"
  echo "    - Cross-compiled library .ipk packages (librtlsdr, libbtbb,"
  echo "      libubertooth, ...) - these are general-purpose system libs"
  echo "      that other Pager workflows may rely on"
  echo "    - System packages installed by the pre-flight phase:"
  echo "        python3, aircrack-ng, tcpdump, libpcap, libopenssl, libffi,"
  echo "        libbz2, zlib, libpcre2, libnl-core200, libnl-genl200"
  echo "      To fully remove these, run manually:"
  echo "        opkg remove python3 aircrack-ng tcpdump libpcap libopenssl \\"
  echo "                 libffi libbz2 zlib libpcre2 libnl-core200 libnl-genl200 \\"
  echo "                 librtlsdr libbtbb libubertooth"
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
# PHASE 1: Internet Connectivity Check
# ==========================================
echo "[*] Checking live WAN internet link via Google DNS..."
# Ping 8.8.8.8 exactly twice, timeout after 3 seconds, silence output
if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    echo "[+] Internet Connection: ONLINE"
else
    echo "[-] Critical Error: No internet connectivity detected!"
    echo "    Please verify your upstream client network/tether configuration and retry."
    exit 1
fi

# ==========================================
# PHASE 2: Pre-flight Dependency Check
# ==========================================
echo "[*] Running pre-flight dependency check (tcpdump, aircrack-ng, python3)..."

MISSING=""
for tool in tcpdump aircrack-ng python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING="$MISSING $tool"
  fi
done

if [ -z "$MISSING" ]; then
  echo "[+] All critical tools present. Skipping pre-flight install."
else
  echo "[*] Missing tools detected:$MISSING"
  echo "[*] Synchronizing OpenWrt package ecosystem lists..."
  opkg update || { echo "[-] Critical Error: opkg update failed!"; exit 1; }
  echo "[*] Provisioning Python3 framework, wireless stack, and missing tools..."
  opkg install python3 python3-base python3-light libffi libbz2-1.0 \
              zlib libpcap libopenssl libpcre2 libnl-core200 libnl-genl200 \
              aircrack-ng tcpdump
  STILL_MISSING=""
  for tool in tcpdump aircrack-ng python3; do
    command -v "$tool" >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING $tool"
  done
  if [ -n "$STILL_MISSING" ]; then
    echo "[-] Critical Error: tools still missing after install:$STILL_MISSING"
    exit 1
  fi
  echo "[+] Pre-flight dependency check satisfied."
fi

# Dynamically locate the newly active Python site-packages folder
PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
if [ -z "$PYTHON_SITE_DIR" ]; then
    echo "[-] Error: Python 3 ecosystem failed to initialize cleanly!"
    exit 1
fi
echo "[+] Target Python Environment Verified: $PYTHON_SITE_DIR"

# Verify core sniffing framework availability
if ! command -v airodump-ng >/dev/null 2>&1; then
    echo "[-] Critical Error: airodump-ng suite setup verification failed!"
    exit 1
fi

# ==========================================
# PHASE 3: Cross-Compiled .ipk Discovery & Install
# ==========================================
echo "[*] Scanning cross-compiled-pager-tools/ for cross-compiled .ipk packages..."

if [ ! -d "$CROSS_TOOLS_DIR" ]; then
  echo "[!] No cross-compiled-pager-tools/ directory in repo. Skipping .ipk install."
else
  IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f 2>/dev/null | sort)

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

    install_ipk_batch() {
      label="$1"
      files="$2"
      [ -z "$files" ] && return 0
      echo "[*] Installing $label .ipk file(s)..."
      for ipk in $files; do
        rel="${ipk#$REPO_DIR/}"
        echo "    -> $rel"
        # Capture opkg output and exit code separately so we can flag failures
        OPKG_OUT=$(opkg install "$ipk" 2>&1)
        OPKG_RC=$?
        echo "$OPKG_OUT" | sed 's/^/       /'
        if [ "$OPKG_RC" -ne 0 ]; then
          echo "       [ERROR] opkg install returned non-zero for $rel"
          FAILED="$FAILED $rel"
        fi
      done
    }

    install_ipk_batch "library" "$LIBS"
    install_ipk_batch "tool"    "$TOOLS"

    if [ -n "$FAILED" ]; then
      echo "[!] WARNING: the following .ipk(s) failed to install:$FAILED"
      echo "    The script will continue, but the affected tools may not work."
    else
      echo "[+] All .ipk packages installed successfully."
    fi
  fi
fi

# ==========================================
# PHASE 4: Repository Payload Tree Mirroring
# ==========================================
echo "[*] Syncing custom security payloads to local hardware storage..."

if [ -d "$LOCAL_PAYLOADS_DIR" ]; then
    # Snapshot the destination's Skinny-Tools / utilities trees BEFORE the copy
    # so we can detect which payload directories are brand-new on this run.
    # The per-subdir check works whether or not the destination parent exists
    # yet -- if the parent is missing, every subdir counts as new.
    NEW_PAYLOADS=""
    PRESENT_PAYLOADS=""
    for tree in Skinny-Tools utilities; do
      src="$LOCAL_PAYLOADS_DIR/user/$tree"
      [ -d "$src" ] || continue
      for entry in "$src"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        if [ ! -d "$SYSTEM_PAYLOADS_DEST/user/$tree/$name" ]; then
          NEW_PAYLOADS="$NEW_PAYLOADS user/$tree/$name"
        else
          PRESENT_PAYLOADS="$PRESENT_PAYLOADS user/$tree/$name"
        fi
      done
    done

    mkdir -p "$SYSTEM_PAYLOADS_DEST"
    # Portable "cp -rn" equivalent that actually descends into pre-existing
    # destination directories. BusyBox's cp -n skips the whole copy when the
    # destination dir already exists, which would silently break re-runs.
    # This loop creates all source directories in the destination (mkdir -p
    # is a no-op when they exist) and then copies only files that aren't
    # already present, preserving any local tweaks to existing files.
    ( cd "$LOCAL_PAYLOADS_DIR" && find . -type d -exec mkdir -p "$SYSTEM_PAYLOADS_DEST/{}" \; )
    ( cd "$LOCAL_PAYLOADS_DIR" && find . -type f | while IFS= read -r src; do
        dst="$SYSTEM_PAYLOADS_DEST/$src"
        if [ ! -e "$dst" ]; then
          mkdir -p "$(dirname "$dst")"
          cp "$src" "$dst"
        fi
      done )
    # Enforce global executable permissions across launcher scripts
    find "$SYSTEM_PAYLOADS_DEST" -name "*.sh" -exec chmod +x {} \;
    echo "[+] Payloads successfully synced to $SYSTEM_PAYLOADS_DEST/"

    # Verify the two required custom folder landing zones exist on disk
    for required in Skinny-Tools utilities; do
      if [ ! -d "$SYSTEM_PAYLOADS_DEST/user/$required" ]; then
        echo "[-] Critical Error: required payload folder missing: $SYSTEM_PAYLOADS_DEST/user/$required"
        exit 1
      fi
    done
    echo "[+] Verified: payloads/user/Skinny-Tools and payloads/user/utilities are in place."

    # Report new vs. existing payload directories detected pre-copy
    NEW_COUNT=0
    for p in $NEW_PAYLOADS; do
      echo "[NEW PAYLOAD] $p"
      NEW_COUNT=$((NEW_COUNT + 1))
    done
    PRESENT_COUNT=0
    for p in $PRESENT_PAYLOADS; do
      PRESENT_COUNT=$((PRESENT_COUNT + 1))
    done
    echo "[*] Payload summary: $NEW_COUNT new sub-payload(s), $PRESENT_COUNT existing."
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

if [ $? -eq 0 ]; then
    echo "[+++++] SUCCESS: Entire deployment is 100% complete and fully optimized!"
    echo "[*] Pager is ready for immediate operation from the hardware UI menus."
else
    echo "[-] Warning: Setup finished but the validation test returned an environment alert."
fi
