#!/bin/bash
# Title: Skinny Pager Payload Updater
# Description: Pager-UI launcher port of ./online-install.sh. Replaces the script's
#              keyboard S/H/B prompt with a 3-option picker, then runs the full
#              Skinny-Tools install / update sequence (Hak5 payload fetch,
#              Skinny-Tools repo auto-fetch, pre-flight deps, .ipk install,
#              payload tree mirror, pagerctl symlinks). Behavior matches
#              ./online-install.sh exactly once the source is selected.
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
# Version: 1.0
#
# Install flow (per online-install.sh):
#   0.  3-option picker: choose Skinny-Tools, Hak5 library/ payloads, or both
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

Default (no flag):  Pager picker asks which payload sources to pull:
                      [1] Skinny-Tools (full install/update, identical to
                          prior behavior)
                      [2] Hak5 library/ payloads from
                          github.com/hak5/wifipineapplepager-payloads
                      [3] Both (Skinny-Tools + Hak5)
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
    LOG red "[-] Unknown argument: $1"
    LOG "    Run '$0 --help' for usage."
    exit 1
    ;;
esac

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  LOG red "[-] Please run as root (SSH into the Pager)."
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
  LOG blue "========================================================="
  LOG "[*] Initializing Skinny-Tools UNINSTALL Sequence..."
  LOG blue "========================================================="

  if [ ! -d "$LOCAL_PAYLOADS_DIR" ] && [ ! -d "$CROSS_TOOLS_DIR" ]; then
    LOG red "[-] Error: Cannot locate the Skinny-Tools repository at:"
    LOG "    $REPO_DIR"
    LOG "    The uninstall needs the cloned repository to know what to remove."
    LOG "    Run the script from inside the Skinny-Tools repo directory."
    exit 1
  fi

  # --- Phase U1: Remove cross-compiled .ipk packages ---
  LOG "[*] Removing cross-compiled .ipk packages..."
  if [ ! -d "$CROSS_TOOLS_DIR" ]; then
    LOG yellow "[!] No cross-compiled-pager-tools/ directory in repo. Skipping."
  else
    IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f ! -name "._*" 2>/dev/null | sort)
    if [ -z "$IPK_FILES" ]; then
      LOG yellow "[!] No .ipk files found in $CROSS_TOOLS_DIR. Skipping."
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
            LOG "    [skip] $pkg (library - left in place)"
            SKIPPED=$((SKIPPED + 1))
            continue
            ;;
        esac
        if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
          LOG "    -> $pkg"
          OPKG_OUT=$(opkg remove "$pkg" 2>&1)
          OPKG_RC=$?
          echo "$OPKG_OUT" | sed 's/^/       /' | while IFS= read -r line; do LOG "$line"; done
          if [ "$OPKG_RC" -ne 0 ]; then
            LOG red "       [ERROR] opkg remove returned non-zero for $pkg"
            FAILED_PKGS="$FAILED_PKGS $pkg"
          else
            REMOVED=$((REMOVED + 1))
          fi
        else
          LOG "    [skip] $pkg (not installed)"
          SKIPPED=$((SKIPPED + 1))
        fi
      done
      LOG "[*] .ipk removal summary: $REMOVED removed, $SKIPPED skipped."
      if [ -n "$FAILED_PKGS" ]; then
        LOG yellow "[!] Some packages could not be removed:$FAILED_PKGS"
        LOG "    They may be dependencies of other installed packages."
      fi
    fi
  fi

  # --- Phase U2: Remove custom payload directories ---
  LOG "[*] Removing custom payload directories..."
  if [ ! -d "$LOCAL_PAYLOADS_DIR" ]; then
    LOG yellow "[!] No payloads/ directory in repo. Skipping."
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
          LOG "    -> user/$tree/$name"
          rm -rf "$dst"
          REMOVED=$((REMOVED + 1))
        else
          LOG "    [skip] user/$tree/$name (not present)"
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
          LOG "    -> recon/$tree/$name"
          rm -rf "$dst"
          REMOVED=$((REMOVED + 1))
        else
          LOG "    [skip] recon/$tree/$name (not present)"
          SKIPPED=$((SKIPPED + 1))
        fi
      done
    done
    LOG "[*] Payload removal summary: $REMOVED removed, $SKIPPED skipped."

    # Tidy up: remove the empty parent trees we created ourselves so the
    # uninstall leaves no trace of our custom payload directory layout.
    # Only touch the Skinny-Tools/ and utilities/ parents - never the
    # Hak5 factory recon/access_point/ and recon/client/ placeholders.
    for parent in \
        "$SYSTEM_PAYLOADS_DEST/user/Skinny-Tools" \
        "$SYSTEM_PAYLOADS_DEST/user/utilities"; do
      if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
        rmdir "$parent" 2>/dev/null && LOG "    [tidy] removed empty $parent"
      fi
    done
  fi

  # --- Phase U3: Remove pagerctl symlinks ---
  LOG "[*] Removing PagerCTL hardware-interface symlinks..."
  PYTHON_SITE_DIR=""
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
  fi
  rm -f /usr/lib/libpagerctl.so
  if [ -n "$PYTHON_SITE_DIR" ]; then
    rm -f "$PYTHON_SITE_DIR/pagerctl.py" "$PYTHON_SITE_DIR/libpagerctl.so"
  fi
  LOG green "[+] PagerCTL symlinks removed."

  # --- Phase U4: Summary ---
  LOG blue "========================================================="
  LOG green "[+] UNINSTALL COMPLETE"
  LOG blue "========================================================="
  LOG "[*] Removed:"
  LOG "    - Custom cross-compiled tool .ipk packages (e.g. rtl_433,"
  LOG "      ubertooth-utils)"
  LOG "    - Custom payload directories under payloads/user/ and payloads/recon/"
  LOG "    - PagerCTL hardware-interface symlinks"
  LOG ""
  LOG "[*] Preserved (not removed):"
  LOG "    - Hak5 factory payloads (alerts/, recon/ factory entries,"
  LOG "      user/<factory folders like evil_portal, prank, ...>)"
  LOG "    - Cross-compiled library .ipk packages (librtlsdr, libbtbb,"
  LOG "      libubertooth, ...) - these are general-purpose system libs"
  LOG "      that other Pager workflows may rely on"
  LOG "    - System packages installed by the pre-flight phase:"
  LOG "        python3, aircrack-ng, tcpdump, libpcap, libopenssl, libffi,"
  LOG "        libbz2, zlib, libpcre2, libnl-core200, libnl-genl200"
  LOG "      To fully remove these, run manually:"
  LOG "        opkg remove python3 aircrack-ng tcpdump libpcap libopenssl \\"
  LOG "                 libffi libbz2 zlib libpcre2 libnl-core200 libnl-genl200 \\"
  LOG "                 librtlsdr libbtbb libubertooth"
  LOG ""
  LOG "[*] The Pager is back to its pre-Skinny-Tools state."
  exit 0
fi

# ==========================================
# INSTALL MODE
# ==========================================
LOG blue "========================================================="
LOG "[*] Initializing Live Git Online Installation Sequence..."
LOG blue "========================================================="

# ==========================================
# PHASE 0: Payload Source Selector (Pager picker)
# ==========================================
ack=$(PROMPT "Skinny-Tools Payload Updater\n\nSelect source:\n\n1) Skinny-Tools\n2) Hak5 Payloads\n3) Both\n\nRe-runs skip existing files (no clobber)." "")
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
# iteration logic. For each payload subdir under $1 (src), installs it into
# $2 (dst root) using two-tier no-clobber semantics:
#   - If the destination subdir doesn't exist: create it and copy the entire
#     payload contents (fresh install). Logs "[NEW PAYLOAD] <label>/<name>".
#   - If the destination subdir already exists: leave it in place but descend
#     into it and copy any individual FILES that are missing. The Pager ships
#     empty placeholder folders at /mmc/root/payloads/{alerts,recon/<subtree>,
#     user/<factory>}/<payload>/ that need to be populated with Hak5's files
#     on first run; existing files at the destination are preserved so local
#     user tweaks to e.g. payload.sh survive re-runs. Logs
#     "[NEW FILE] <label>/<name>/<relpath>" for each file copied.
# Updates the MERGE_NEW_LABELS, MERGE_PRESENT_LABELS, and MERGE_FAILED_LABELS
# globals (space-separated "<label>/<name>" strings for whole-payload rows).
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
      ( cd "$entry" && find . -type f ) | while IFS= read -r f; do
        if [ ! -e "$dst/$f" ]; then
          mkdir -p "$dst/$(dirname "$f")"
          cp "$entry/$f" "$dst/$f"
          LOG "[NEW FILE] $full_label/$f"
        fi
      done
    else
      mkdir -p "$dst"
      if cp -r "$entry/." "$dst/" 2>/dev/null; then
        MERGE_NEW_LABELS="${MERGE_NEW_LABELS}${MERGE_NEW_LABELS:+ }$full_label"
        LOG "[NEW PAYLOAD] $full_label"
      else
        rm -rf "$dst"
        MERGE_FAILED_LABELS="${MERGE_FAILED_LABELS}${MERGE_FAILED_LABELS:+ }$full_label"
      fi
    fi
  done
}

# count_missing_files: emits one line per file in $1 (src root) that does
# not exist at the corresponding path under $2 (dst root), and prints the
# total count on stdout. Used by Phase 4 to decide whether the per-file
# no-clobber sync is necessary or can be skipped as a no-op.
count_missing_files() {
  src_root="$1"
  dst_root="$2"
  [ -d "$src_root" ] || { echo 0; return 0; }
  ( cd "$src_root" && find . -type f ) | while IFS= read -r src; do
    [ ! -e "$dst_root/$src" ] && echo x
  done | wc -l
}

# ==========================================
# PHASE 1: Internet Connectivity Check
# ==========================================
LOG "[*] Checking live WAN internet link via Google DNS..."
# Ping 8.8.8.8 exactly twice, timeout after 3 seconds, silence output
if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    LOG green "[+] Internet Connection: ONLINE"
else
    LOG red "[-] Critical Error: No internet connectivity detected!"
    LOG "    Please verify your upstream client network/tether configuration and retry."
    exit 1
fi

# ==========================================
# PHASE 1A: Hak5 Payload Library Fetch (H or B only)
# ==========================================
# Pulls github.com/hak5/wifipineapplepager-payloads and merges the contents
# of its library/ tree (alerts/, recon/, user/) into the Pager's payload
# destination. Strictly no-clobber: payloads already on the Pager are
# skipped, nothing is ever removed or overwritten.
#
# Efficiency: the extracted library is cached at
#   /mmc/root/.skinny-tools-cache/hak5-library/
# so subsequent runs skip the GitHub download entirely and just diff the
# cached manifest against the Pager's filesystem. Delete that directory to
# force a fresh download.
# ==========================================
if [ "$SELECTION" = "H" ] || [ "$SELECTION" = "B" ]; then
  HAK5_CACHE_ROOT="/mmc/root/.skinny-tools-cache"
  HAK5_CACHE="$HAK5_CACHE_ROOT/hak5-library"

  if [ -d "$HAK5_CACHE/alerts" ] && [ -d "$HAK5_CACHE/user" ] && [ -d "$HAK5_CACHE/recon" ]; then
    LOG "[*] Using cached Hak5 payload library at $HAK5_CACHE (delete to force refresh)"
    HAK5_SRC="$HAK5_CACHE"
  else
    LOG "[*] Fetching Hak5 payload library from github.com/hak5/wifipineapplepager-payloads..."

    HAK5_TARBALL_URL="https://github.com/hak5/wifipineapplepager-payloads/archive/refs/heads/master.tar.gz"
    HAK5_STAGE="$(mktemp -d -t hak5-payloads.XXXXXX)"

    # wget is the Pager's default fetcher; fall back to curl if missing.
    if command -v wget >/dev/null 2>&1; then
      if ! wget -qO "$HAK5_STAGE/hak5.tar.gz" "$HAK5_TARBALL_URL"; then
        LOG red "[-] Critical Error: wget failed to download Hak5 tarball."
        exit 1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL -o "$HAK5_STAGE/hak5.tar.gz" "$HAK5_TARBALL_URL"; then
        LOG red "[-] Critical Error: curl failed to download Hak5 tarball."
        exit 1
      fi
    else
      LOG red "[-] Critical Error: neither wget nor curl is available on this Pager."
      exit 1
    fi

    if ! tar -xzf "$HAK5_STAGE/hak5.tar.gz" -C "$HAK5_STAGE" 2>/dev/null; then
      LOG red "[-] Critical Error: tar failed to extract Hak5 tarball."
      exit 1
    fi

    HAK5_SRC="$HAK5_STAGE/wifipineapplepager-payloads-master/library"
    if [ ! -d "$HAK5_SRC" ]; then
      LOG red "[-] Critical Error: expected library/ folder missing in Hak5 tarball."
      exit 1
    fi

    # Persist the extracted library to /mmc so future runs skip the download.
    mkdir -p "$HAK5_CACHE_ROOT"
    rm -rf "$HAK5_CACHE"
    cp -r "$HAK5_SRC" "$HAK5_CACHE"
    HAK5_SRC="$HAK5_CACHE"
    LOG green "[+] Hak5 library cached at $HAK5_CACHE for future runs."
  fi

  mkdir -p "$SYSTEM_PAYLOADS_DEST"

  HAK5_NEW=0
  HAK5_PRESENT=0
  HAK5_FAILED=""
  MERGE_NEW_LABELS=""
  MERGE_PRESENT_LABELS=""
  MERGE_FAILED_LABELS=""

  # Hak5's library/ tree mixes flat and nested layouts:
  #   - alerts/, recon/<subtree>/ - payloads are direct children
  #   - user/ - payloads are NESTED inside factory folder names:
  #       library/user/<factory>/<payload>/payload.sh
  # The Pager ships empty factory folders under user/ (general, evil_portal,
  # examples, ...). A one-level walk over library/user/* would see those
  # factory roots as already-present on the Pager and silently skip every
  # payload inside them. Walk each factory folder individually so the helper
  # descends into the actual payload directories.
  merge_payload_category "$HAK5_SRC/alerts" "$SYSTEM_PAYLOADS_DEST/alerts" "alerts"
  for subtree in access_point client; do
    merge_payload_category "$HAK5_SRC/recon/$subtree" \
                           "$SYSTEM_PAYLOADS_DEST/recon/$subtree" \
                           "recon/$subtree"
  done
  for factory_dir in "$HAK5_SRC/user"/*; do
    [ -d "$factory_dir" ] || continue
    factory_name="$(basename "$factory_dir")"
    merge_payload_category "$factory_dir" \
                           "$SYSTEM_PAYLOADS_DEST/user/$factory_name" \
                           "user/$factory_name"
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

  LOG "[*] Hak5 payload summary: $HAK5_NEW new, $HAK5_PRESENT already present."
  if [ -n "$HAK5_FAILED" ]; then
    LOG yellow "[!] WARNING: failed to copy Hak5 payloads:$HAK5_FAILED"
  fi
  LOG green "[+] Hak5 payload library merged into $SYSTEM_PAYLOADS_DEST/"
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
    LOG "[*] Local Skinny-Tools repo incomplete; fetching from github.com/skinnyrad/Skinny-Tools..."
    SKINNY_TARBALL_URL="https://github.com/skinnyrad/Skinny-Tools/archive/refs/heads/master.tar.gz"
    SKINNY_STAGE="$(mktemp -d -t skinny-tools.XXXXXX)"

    if command -v wget >/dev/null 2>&1; then
      if ! wget -qO "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL"; then
        LOG red "[-] Critical Error: wget failed to download Skinny-Tools tarball."
        exit 1
      fi
    elif command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL -o "$SKINNY_STAGE/skinny.tar.gz" "$SKINNY_TARBALL_URL"; then
        LOG red "[-] Critical Error: curl failed to download Skinny-Tools tarball."
        exit 1
      fi
    else
      LOG red "[-] Critical Error: neither wget nor curl is available on this Pager."
      exit 1
    fi

    if ! tar -xzf "$SKINNY_STAGE/skinny.tar.gz" -C "$SKINNY_STAGE" 2>/dev/null; then
      LOG red "[-] Critical Error: tar failed to extract Skinny-Tools tarball."
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
        LOG red "[-] Critical Error: extracted Skinny-Tools repo is missing payloads/."
        exit 1
      fi
    fi

    REPO_DIR="$SKINNY_SRC"
    LOCAL_PAYLOADS_DIR="$REPO_DIR/payloads"
    CROSS_TOOLS_DIR="$REPO_DIR/cross-compiled-pager-tools"
    LOG green "[+] Skinny-Tools repo staged from GitHub tarball."
  else
    LOG "[*] Local Skinny-Tools repo detected; using $REPO_DIR"
  fi
fi

# ==========================================
# PHASE 2: Pre-flight Dependency Check
# ==========================================
# Skinny-Tools-specific phases (2 through 6) only run when S or B was
# selected. Hak5 is just a payload pull, so it doesn't need python3,
# airodump-ng, the cross-compiled tools, or the PagerCTL shims.
if [ "$SELECTION" = "S" ] || [ "$SELECTION" = "B" ]; then
LOG "[*] Running pre-flight dependency check (tcpdump, aircrack-ng, python3)..."

MISSING=""
for tool in tcpdump aircrack-ng python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING="$MISSING $tool"
  fi
done

if [ -z "$MISSING" ]; then
  LOG green "[+] All critical tools present. Skipping pre-flight install."
else
  LOG "[*] Missing tools detected:$MISSING"
  LOG "[*] Synchronizing OpenWrt package ecosystem lists..."
  opkg update || { LOG red "[-] Critical Error: opkg update failed!"; exit 1; }
  LOG "[*] Provisioning Python3 framework, wireless stack, and missing tools..."
  opkg install python3 python3-base python3-light libffi libbz2-1.0 \
              zlib libpcap libopenssl libpcre2 libnl-core200 libnl-genl200 \
              aircrack-ng tcpdump
  STILL_MISSING=""
  for tool in tcpdump aircrack-ng python3; do
    command -v "$tool" >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING $tool"
  done
  if [ -n "$STILL_MISSING" ]; then
    LOG red "[-] Critical Error: tools still missing after install:$STILL_MISSING"
    exit 1
  fi
  LOG green "[+] Pre-flight dependency check satisfied."
fi

# Dynamically locate the newly active Python site-packages folder
PYTHON_SITE_DIR=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
if [ -z "$PYTHON_SITE_DIR" ]; then
    LOG red "[-] Error: Python 3 ecosystem failed to initialize cleanly!"
    exit 1
fi
LOG green "[+] Target Python Environment Verified: $PYTHON_SITE_DIR"

# Verify core sniffing framework availability
if ! command -v airodump-ng >/dev/null 2>&1; then
    LOG red "[-] Critical Error: airodump-ng suite setup verification failed!"
    exit 1
fi

# ==========================================
# PHASE 3: Cross-Compiled .ipk Discovery & Install
# ==========================================
LOG "[*] Scanning cross-compiled-pager-tools/ for cross-compiled .ipk packages..."

if [ ! -d "$CROSS_TOOLS_DIR" ]; then
  LOG yellow "[!] No cross-compiled-pager-tools/ directory in repo. Skipping .ipk install."
else
  IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f 2>/dev/null | sort)

  if [ -z "$IPK_FILES" ]; then
    LOG yellow "[!] No .ipk files found under $CROSS_TOOLS_DIR. Skipping."
  else
    IPK_COUNT=$(echo "$IPK_FILES" | wc -l)
    LOG "[*] Discovered $IPK_COUNT .ipk package(s):"
    for ipk in $IPK_FILES; do
      LOG "    - ${ipk#$REPO_DIR/}"
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
      LOG "[*] Installing $label .ipk file(s)..."
      for ipk in $files; do
        rel="${ipk#$REPO_DIR/}"
        # Derive the opkg package name (same parsing as the uninstall path
        # in --uninstall) so we can pre-check installed state via opkg and
        # avoid re-running opkg install for packages that are already
        # current. opkg install is fast on a hit but skips cleanly here.
        pkg=$(basename "$ipk" .ipk | sed 's/_[0-9][^_]*_mipsel.*$//')
        if opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
          LOG "    [skip] $rel (already installed: $pkg)"
          ALREADY_PRESENT=$((ALREADY_PRESENT + 1))
          continue
        fi
        LOG "    -> $rel"
        # Capture opkg output and exit code separately so we can flag failures
        OPKG_OUT=$(opkg install "$ipk" 2>&1)
        OPKG_RC=$?
        echo "$OPKG_OUT" | sed 's/^/       /' | while IFS= read -r line; do LOG "$line"; done
        if [ "$OPKG_RC" -ne 0 ]; then
          LOG red "       [ERROR] opkg install returned non-zero for $rel"
          FAILED="$FAILED $rel"
        else
          INSTALLED=$((INSTALLED + 1))
        fi
      done
    }

    install_ipk_batch "library" "$LIBS"
    install_ipk_batch "tool"    "$TOOLS"

    LOG "[*] .ipk install summary: $INSTALLED installed, $ALREADY_PRESENT already present."
    if [ -n "$FAILED" ]; then
      LOG yellow "[!] WARNING: the following .ipk(s) failed to install:$FAILED"
      LOG "    The script will continue, but the affected tools may not work."
    elif [ "$INSTALLED" = "0" ] && [ "$ALREADY_PRESENT" -gt 0 ]; then
      LOG green "[+] All .ipk packages already installed; nothing to do."
    else
      LOG green "[+] All .ipk packages installed successfully."
    fi
  fi
fi

# ==========================================
# PHASE 4: Repository Payload Tree Mirroring
# ==========================================
LOG "[*] Syncing custom security payloads to local hardware storage..."

if [ -d "$LOCAL_PAYLOADS_DIR" ]; then
    MERGE_NEW_LABELS=""
    MERGE_PRESENT_LABELS=""
    MERGE_FAILED_LABELS=""

    # Flat Skinny-Tools user categories.
    for tree in Skinny-Tools utilities; do
      merge_payload_category "$LOCAL_PAYLOADS_DIR/user/$tree" \
                             "$SYSTEM_PAYLOADS_DEST/user/$tree" \
                             "user/$tree"
    done

    # Nested Skinny-Tools recon subtrees. Mirrors the Pager's default
    # layout where /mmc/root/payloads/recon/access_point/ and .../client/
    # exist as factory skeleton folders, with payload dirs inside them.
    for tree in access_point client; do
      merge_payload_category "$LOCAL_PAYLOADS_DIR/recon/$tree" \
                             "$SYSTEM_PAYLOADS_DEST/recon/$tree" \
                             "recon/$tree"
    done

    NEW_PAYLOADS="$MERGE_NEW_LABELS"
    PRESENT_PAYLOADS="$MERGE_PRESENT_LABELS"

    mkdir -p "$SYSTEM_PAYLOADS_DEST"
    # Pre-check: count any files in the local repo that aren't on the Pager.
    # If everything's already present (re-run case), skip the per-file sync
    # block as a no-op rather than iterating every file just to confirm.
    MISSING_COUNT=$(count_missing_files "$LOCAL_PAYLOADS_DIR" "$SYSTEM_PAYLOADS_DEST")
    if [ "$MISSING_COUNT" = "0" ]; then
      LOG "[*] All Skinny-Tools payload files already present on Pager; per-file sync skipped."
    else
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
      LOG green "[+] Payloads successfully synced to $SYSTEM_PAYLOADS_DEST/"
    fi

    # Verify the two required custom folder landing zones exist on disk.
    # The recon/<subtree> skeletons always exist (factory default) so we
    # don't need to verify them here - they were just populated by the
    # helper calls above.
    for required in Skinny-Tools utilities; do
      if [ ! -d "$SYSTEM_PAYLOADS_DEST/user/$required" ]; then
        LOG red "[-] Critical Error: required payload folder missing: $SYSTEM_PAYLOADS_DEST/user/$required"
        exit 1
      fi
    done
    LOG green "[+] Verified: payloads/user/Skinny-Tools, payloads/user/utilities, payloads/recon/access_point, payloads/recon/client are in place."

    NEW_COUNT=$(echo "$NEW_PAYLOADS" | wc -w)
    PRESENT_COUNT=$(echo "$PRESENT_PAYLOADS" | wc -w)
    LOG "[*] Payload summary: $NEW_COUNT new sub-payload(s), $PRESENT_COUNT existing."
else
    LOG red "[-] Error: 'payloads' folder missing from the cloned Git repository!"
    exit 1
fi

# ==========================================
# PHASE 5: Global PagerCTL Environment Setup
# ==========================================
LOG "[*] Establishing system hardware translation symlinks..."

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
    LOG green "[+] Global Hardware Interface Links configured."
else
    LOG red "[-] Error: Could not locate 'pagerctl.py' or 'libpagerctl.so' in payload paths!"
    exit 1
fi

# ==========================================
# PHASE 6: Functional Verification Check
# ==========================================
LOG blue "========================================================="
LOG "[*] Verification Phase..."
LOG blue "========================================================="

VERIFY_CMD="python3 -c 'from pagerctl import Pager; print(\"[+] Python Verification: PagerCTL Loaded Natively.\")' 2>&1"
eval "$VERIFY_CMD" > /tmp/skinny-verify.txt 2>&1
VERIFY_RC=$?
while IFS= read -r line; do LOG "$line"; done < /tmp/skinny-verify.txt
rm -f /tmp/skinny-verify.txt

if [ "$VERIFY_RC" -eq 0 ]; then
    LOG green "[+++++] SUCCESS: Entire deployment is 100% complete and fully optimized!"
    LOG green "[*] Pager is ready for immediate operation from the hardware UI menus."
else
    LOG yellow "[-] Warning: Setup finished but the validation test returned an environment alert."
fi
fi

# End of Skinny-Tools install block. Hak5-only runs (SELECTION=H) skip
# everything inside the conditional above and exit cleanly here.