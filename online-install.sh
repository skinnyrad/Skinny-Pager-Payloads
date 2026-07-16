#!/bin/sh
# Title: Git Repository Live Online Installer (Python, Security Tools, & Payloads)
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
#
# Install flow:
#   0.  S/H/B selector: choose Skinny-Tools, Hak5 library/ payloads, or both
#   1.  Internet connectivity check
#   1A. Hak5 payload pull (H or B only) - fetches
#         github.com/hak5/wifipineapplepager-payloads/library and merges
#         new payload folders into /mmc/root/payloads/ (no-clobber)
#   1B. Skinny-Tools repo auto-fetch (S or B only) - if a full local clone
#         isn't next to the script, fetches the GitHub tarball so Phase 3-5
#         have payloads/, cross-compiled-pager-tools/, pagerctl.{py,so} to
#         work with. Existing users with a full clone see no behavior change.
#   2.  Pre-flight dependency check (tcpdump, aircrack-ng, python3)  [S/B only]
#   3.  Recursive .ipk discovery & install under cross-compiled-pager-tools/  [S/B only]
#   4.  Payload tree mirror with new-payload detection  [S/B only]
#   5.  Global pagerctl hardware-interface symlinks  [S/B only]
#   6.  Verification & summary  [S/B only]
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

Default (no flag):  Interactive prompt asks which payload sources to pull:
                      [S] Skinny-Tools (full install/update, identical to
                          prior behavior)
                      [H] Hak5 library/ payloads from
                          github.com/hak5/wifipineapplepager-payloads
                      [B] Both (Skinny-Tools + Hak5)
                   All payload merges use no-clobber semantics: only
                   missing payloads are copied, nothing on the Pager is
                   ever removed by this script.
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
discover payloads/ and cross-compiled-pager-tools/. Hak5 payloads are
fetched directly from GitHub at install time and do not require the
Skinny-Tools repo to be present locally.
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
# PHASE 0: Payload Source Selector (S/H/B)
# ==========================================
echo ""
echo "Do you want to install:"
echo "  [S] Skinny-Tools"
echo "  [H] Hak5 Payloads"
echo "  [B] Both"
SELECTION=""
while [ -z "$SELECTION" ]; do
  printf "Choice [S/H/B]: "
  read -r SELECTION
  case "$SELECTION" in
    [sS]) SELECTION="S" ;;
    [hH]) SELECTION="H" ;;
    [bB]) SELECTION="B" ;;
    *)
      echo "[-] Invalid choice. Please enter S, H, or B."
      SELECTION=""
      ;;
  esac
done
echo "[+] Selected: $SELECTION"
echo ""

# Stage directories for tarballs fetched at runtime (Hak5 and Skinny-Tools).
# Initialized empty; each phase that creates a stage dir will overwrite its
# variable, and the EXIT trap will clean whatever was created.
HAK5_STAGE=""
SKINNY_STAGE=""
# Trap cleans any staged dirs on every exit path so /tmp doesn't accumulate
# cruft on the Pager. rm -rf on empty vars is a harmless no-op.
trap 'rm -rf "$HAK5_STAGE" "$SKINNY_STAGE" 2>/dev/null' EXIT

# Shared helper for payload tree-walking. Used by both Phase 1A (Hak5 fetch)
# and Phase 4 (Skinny-Tools mirror) so the two phases cannot drift in their
# iteration logic. Copies each payload subdir from $1 (src) into $2 (dst
# root) using dir-level no-clobber semantics: if a subdir of the same name
# already exists at the destination, the entry is skipped entirely (no files
# are touched). Updates the MERGE_NEW_LABELS, MERGE_PRESENT_LABELS, and
# MERGE_FAILED_LABELS globals (space-separated "<label>/<name>" strings) and
# emits "[NEW PAYLOAD] <label>/<name>" to stdout for each newly copied
# entry. The caller translates the labels into its preferred summary format.
merge_payload_category() {
  src="$1"
  dst_root="$2"
  label="$3"
  [ -d "$src" ] || return 0
  for entry in "$src"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    full_label="$label/$name"
    dst="$dst_root/$name"
    if [ -d "$dst" ]; then
      MERGE_PRESENT_LABELS="${MERGE_PRESENT_LABELS}${MERGE_PRESENT_LABELS:+ }$full_label"
    else
      mkdir -p "$dst"
      if cp -r "$entry/." "$dst/" 2>/dev/null; then
        MERGE_NEW_LABELS="${MERGE_NEW_LABELS}${MERGE_NEW_LABELS:+ }$full_label"
        echo "[NEW PAYLOAD] $full_label"
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
# PHASE 1A: Hak5 Payload Library Fetch (H or B only)
# ==========================================
# Pulls github.com/hak5/wifipineapplepager-payloads and merges the contents
# of its library/ tree (alerts/, recon/, user/) into the Pager's payload
# destination. Strictly no-clobber: payloads already on the Pager are
# skipped, nothing is ever removed or overwritten.
# ==========================================
if [ "$SELECTION" = "H" ] || [ "$SELECTION" = "B" ]; then
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

  mkdir -p "$SYSTEM_PAYLOADS_DEST"

  HAK5_NEW=0
  HAK5_PRESENT=0
  HAK5_FAILED=""
  MERGE_NEW_LABELS=""
  MERGE_PRESENT_LABELS=""
  MERGE_FAILED_LABELS=""

  # Hak5's library/ tree is mostly flat (alerts/, user/) but the recon/
  # subtree nests payloads two levels deep: library/recon/<subtree>/<payload>.
  # The Pager ships empty skeleton folders at /mmc/root/payloads/recon/<subtree>/
  # by default, so a single one-level walk over library/recon/* would only see
  # the subtree roots and incorrectly mark every recon payload as "already
  # present". Two passes - flat then nested - keep the recursion explicit.
  for tree in alerts user; do
    merge_payload_category "$HAK5_SRC/$tree" "$SYSTEM_PAYLOADS_DEST/$tree" "$tree"
  done
  for subtree in access_point client; do
    merge_payload_category "$HAK5_SRC/recon/$subtree" \
                           "$SYSTEM_PAYLOADS_DEST/recon/$subtree" \
                           "recon/$subtree"
  done

  HAK5_NEW=$(echo "$MERGE_NEW_LABELS" | wc -w)
  HAK5_PRESENT=$(echo "$MERGE_PRESENT_LABELS" | wc -w)
  HAK5_FAILED="$MERGE_FAILED_LABELS"

  # Ensure any launcher scripts Hak5 ships with executable bit set.
  for tree in alerts recon user; do
    if [ -d "$SYSTEM_PAYLOADS_DEST/$tree" ]; then
      find "$SYSTEM_PAYLOADS_DEST/$tree" -name "*.sh" -exec chmod +x {} \; 2>/dev/null
    fi
  done

  echo "[*] Hak5 payload summary: $HAK5_NEW new, $HAK5_PRESENT already present."
  if [ -n "$HAK5_FAILED" ]; then
    echo "[!] WARNING: failed to copy Hak5 payloads:$HAK5_FAILED"
  fi
  echo "[+] Hak5 payload library merged into $SYSTEM_PAYLOADS_DEST/"
fi

# ==========================================
# PHASE 1B: Skinny-Tools Repo Auto-Fetch (S/B only)
# ==========================================
# If the script was launched from a folder that doesn't contain the full
# Skinny-Tools repo (e.g. the user only downloaded online-install.sh from
# GitHub in their browser), fetch the tarball so Phase 3-5 have payloads/,
# cross-compiled-pager-tools/, pagerctl.py, and libpagerctl.so to work
# with. A local clone is always preferred when present so existing users
# running 'git pull && ./online-install.sh' see no behavior change.
# ==========================================
if [ "$SELECTION" = "S" ] || [ "$SELECTION" = "B" ]; then
  NEEDS_FETCH=0
  # payloads/ is the most critical - Phase 4 errors out without it.
  [ -d "$LOCAL_PAYLOADS_DIR" ] || NEEDS_FETCH=1
  # cross-compiled-pager-tools/ - Phase 3 just warns and skips without it,
  # but rtl_433 / ubertooth-utils won't install if missing.
  [ -d "$CROSS_TOOLS_DIR" ] || NEEDS_FETCH=1
  # pagerctl.py + libpagerctl.so are required by Phase 5's symlink block.
  if [ ! -f "$REPO_DIR/pagerctl.py" ] || [ ! -f "$REPO_DIR/libpagerctl.so" ]; then
    NEEDS_FETCH=1
  fi

  if [ "$NEEDS_FETCH" = "1" ]; then
    echo "[*] Local Skinny-Tools repo incomplete; fetching from github.com/skinnyrad/Skinny-Tools..."
    SKINNY_TARBALL_URL="https://github.com/skinnyrad/Skinny-Tools/archive/refs/heads/master.tar.gz"
    SKINNY_STAGE="$(mktemp -d -t skinny-tools.XXXXXX)"

    if command -v wget >/dev/null 2>&1; then
      if ! wget -qO "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL"; then
        echo "[-] Critical Error: wget failed to download Skinny-Tools tarball."
        exit 1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL -o "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL"; then
        echo "[-] Critical Error: curl failed to download Skinny-Tools tarball."
        exit 1
      fi
    else
      echo "[-] Critical Error: neither wget nor curl is available on this Pager."
      exit 1
    fi

    if ! tar -xzf "$SKINNY_STAGE/skinny.tar.gz" -C "$SKINNY_STAGE" 2>/dev/null; then
      echo "[-] Critical Error: tar failed to extract Skinny-Tools tarball."
      exit 1
    fi

    # GitHub tarballs extract to <repo-name>-<branch>/ so the branch name is
    # part of the path. master is the branch used by skinnyrad/Skinny-Tools.
    SKINNY_SRC="$SKINNY_STAGE/Skinny-Tools-master"
    if [ ! -d "$SKINNY_SRC/payloads" ]; then
      # Fallback: discover whatever directory tar created (covers branch
      # renames without requiring a script update).
      SKINNY_SRC="$(find "$SKINNY_STAGE" -mindepth 1 -maxdepth 1 -type d ! -name '*.tar.gz' | head -n 1)"
      if [ -z "$SKINNY_SRC" ] || [ ! -d "$SKINNY_SRC/payloads" ]; then
        echo "[-] Critical Error: extracted Skinny-Tools repo is missing payloads/."
        exit 1
      fi
    fi

    REPO_DIR="$SKINNY_SRC"
    LOCAL_PAYLOADS_DIR="$REPO_DIR/payloads"
    CROSS_TOOLS_DIR="$REPO_DIR/cross-compiled-pager-tools"
    echo "[+] Skinny-Tools repo staged from GitHub tarball."
  else
    echo "[*] Local Skinny-Tools repo detected; using $REPO_DIR"
  fi
fi

# ==========================================
# PHASE 2: Pre-flight Dependency Check
# ==========================================
# Skinny-Tools-specific phases (2 through 6) only run when S or B was
# selected. Hak5 is just a payload pull, so it doesn't need python3,
# airodump-ng, the cross-compiled tools, or the PagerCTL shims.
if [ "$SELECTION" = "S" ] || [ "$SELECTION" = "B" ]; then
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
fi

# End of Skinny-Tools install block. Hak5-only runs (SELECTION=H) skip
# everything inside the conditional above and exit cleanly here.
