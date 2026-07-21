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
#   1B. Skinny-Tools source resolution (S or B only) - ALWAYS fetches the
#         latest from github.com/skinnyrad/Skinny-Pager-Payloads so Phase
#         3-5 operate on upstream HEAD, not on a possibly-stale local
#         clone. The fetched content is cached at
#         /mmc/root/.skinny-tools-cache/skinny-tools/ and refreshed on
#         every successful run. Fallbacks in order: cached snapshot,
#         then the local clone at $REPO_DIR (only if both the GitHub
#         fetch and the cache are unavailable, e.g. truly offline).
#         This means users who only downloaded online-install.sh (no
#         local clone) get the same updates as users who maintain a
#         full clone - and they no longer have to remember to
#         `git pull` between runs.
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
SELECTION=""
case "${1:-}" in
  --uninstall|-u) MODE="uninstall" ;;
  --help|-h)
    cat <<EOF
Usage: $0 [--uninstall] [--help] [--select S|H|B] [S|H|B]

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
  --select S|H|B:    Non-interactive mode: skip the prompt and use the
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
  --select)
    # --select S (space-separated): consume the value as $2.
    SELECTION="$2"
    shift 2
    # Validate now so callers fail fast with a clear error.
    case "$SELECTION" in
      [sS]) SELECTION="S" ;;
      [hH]) SELECTION="H" ;;
      [bB]) SELECTION="B" ;;
      *)
        echo "[-] --select requires S, H, or B (got: $SELECTION)"
        exit 1
        ;;
    esac
    ;;
  --select=*)
    SELECTION="${1#--select=}"
    case "$SELECTION" in
      [sS]) SELECTION="S" ;;
      [hH]) SELECTION="H" ;;
      [bB]) SELECTION="B" ;;
      *)
        echo "[-] --select requires S, H, or B (got: $SELECTION)"
        exit 1
        ;;
    esac
    shift
    ;;
  [sShHbB])
    # Positional: "$0 S" or "$0 H" or "$0 B" (case-insensitive).
    case "$1" in
      [sS]) SELECTION="S" ;;
      [hH]) SELECTION="H" ;;
      [bB]) SELECTION="B" ;;
    esac
    shift
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
    IPK_FILES=$(find "$CROSS_TOOLS_DIR" -name "*.ipk" -type f ! -name "._*" 2>/dev/null | sort)
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
if [ -z "$SELECTION" ]; then
  echo ""
  echo "Do you want to install:"
  echo "  [S] Skinny-Tools"
  echo "  [H] Hak5 Payloads"
  echo "  [B] Both"
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
else
  # Non-interactive mode: --select (or positional S/H/B) was supplied.
  echo "[+] Selected: $SELECTION (non-interactive)"
  echo ""
fi

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

# Shared helper for payload tree-walking. Used by both Phase 1A (Hak5 fetch)
# and Phase 4 (Skinny-Tools mirror) so the two phases cannot drift in their
# iteration logic. For each payload subdir under $1 (src), installs it into
# $2 (dst root) using three-tier semantics:
#   - If the destination subdir doesn't exist: create it and copy the entire
#     payload contents (fresh install). Logs "[NEW PAYLOAD] <label>/<name>".
#   - If the destination subdir already exists: descend into it and for each
#     file compare content via sha256. Three sub-cases:
#       * File missing on dest: copy it. Logs
#         "[NEW FILE] <label>/<name>/<relpath>". The Pager ships empty
#         placeholder folders at /mmc/root/payloads/{alerts,recon/<subtree>,
#         user/<factory>}/<payload>/ that need to be populated with upstream
#         files on first run.
#       * File present but hash differs: overwrite with the upstream copy
#         (your latest repo push is the source of truth). Logs
#         "[UPDATED FILE] <label>/<name>/<relpath>".
#       * File present and hash matches: skip silently. Local tweaks are
#         preserved only as long as the upstream file content doesn't change.
#     If any file in the payload was added or changed, the whole label is
#     also logged once as "[UPDATED PAYLOAD] <label>/<name>".
# Updates the MERGE_NEW_LABELS, MERGE_UPDATED_LABELS, MERGE_PRESENT_LABELS,
# and MERGE_FAILED_LABELS globals (space-separated "<label>/<name>" strings
# for whole-payload rows; NEW, UPDATED, and PRESENT are mutually exclusive).
merge_payload_category() {
  src="$1"
  dst_root="$2"
  label="$3"
  [ -d "$src" ] || return 0
  # Lazily create a shared scratch dir for the per-payload updated flag.
  # The per-file loop below runs in a subshell so shell variables can't
  # escape it; we instead record "this payload had at least one change"
  # in a sentinel file under $MERGE_TMP that the parent shell inspects.
  if [ -z "$MERGE_TMP" ] || [ ! -d "$MERGE_TMP" ]; then
    MERGE_TMP="$(mktemp -d -t skinny-merge.XXXXXX)"
  fi
  for entry in "$src"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    full_label="$label/$name"
    dst="$dst_root/$name"
    if [ -d "$dst" ]; then
      flag="$MERGE_TMP/$name.updated"
      : > "$flag"
      ( cd "$entry" && find . -type f ) | while IFS= read -r f; do
        if [ ! -e "$dst/$f" ]; then
          mkdir -p "$dst/$(dirname "$f")"
          cp "$entry/$f" "$dst/$f"
          echo "[NEW FILE] $full_label/$f"
          echo x >> "$flag"
        elif [ "$(sha256_file "$entry/$f")" != "$(sha256_file "$dst/$f")" ]; then
          cp "$entry/$f" "$dst/$f"
          echo "[UPDATED FILE] $full_label/$f"
          echo x >> "$flag"
        fi
      done
      if [ -s "$flag" ]; then
        MERGE_UPDATED_LABELS="${MERGE_UPDATED_LABELS}${MERGE_UPDATED_LABELS:+ }$full_label"
        echo "[UPDATED PAYLOAD] $full_label"
      else
        MERGE_PRESENT_LABELS="${MERGE_PRESENT_LABELS}${MERGE_PRESENT_LABELS:+ }$full_label"
      fi
      rm -f "$flag"
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

# sha256_file: print the sha256 of a single file's contents. sha256sum ships
# in BusyBox on OpenWrt (including the Hak5 Pager), so no fallback is needed.
# If the file is unreadable or missing, the empty string is returned and any
# caller's hash comparison will naturally treat it as a mismatch.
sha256_file() {
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# count_missing_files: emits one line per file in $1 (src root) that does
# not exist at the corresponding path under $2 (dst root), and prints the
# total count on stdout. Used by Phase 4 to decide whether the per-file
# no-clobber sync is necessary or can be skipped as a no-op.
count_missing_files() {
  src_root="$1"
  dst_root="$2"
  [ -d "$src_root" ] || { echo 0; return 0; }
  # Strip a trailing slash so the prefix-strip below produces a clean
  # relative path (avoids "//foo" after substitution).
  src_root="${src_root%/}"
  # Use `find $src_root` rather than `cd $src_root && find .` so the
  # emitted paths are absolute and remain resolvable in the parent shell
  # after the pipeline fork. A subshell `cd` would leave the parent in
  # its original CWD, making the relative "./foo" paths unresolvable
  # by sha256_file below.
  find "$src_root" -type f | while IFS= read -r src; do
    rel="${src#"$src_root"/}"
    [ ! -e "$dst_root/$rel" ] && echo x
  done | wc -l
}

# count_updated_files: emits one line per file in $1 (src root) whose
# sha256 differs from the same path under $2 (dst root), and prints the
# total count on stdout. Pairs with count_missing_files so the Phase 4
# pre-check can short-circuit only when BOTH are zero (genuine no-op),
# not just when there are no missing files - otherwise divergent files
# would never be reached by the per-file loop below.
count_updated_files() {
  src_root="$1"
  dst_root="$2"
  [ -d "$src_root" ] || { echo 0; return 0; }
  src_root="${src_root%/}"
  # Absolute paths from `find $src_root` (see count_missing_files for
  # why we don't use a subshell cd here).
  find "$src_root" -type f | while IFS= read -r src; do
    rel="${src#"$src_root"/}"
    dst="$dst_root/$rel"
    [ -e "$dst" ] || continue
    [ "$(sha256_file "$src")" != "$(sha256_file "$dst")" ] && echo x
  done | wc -l
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
    echo "[*] Using cached Hak5 payload library at $HAK5_CACHE (delete to force refresh)"
    HAK5_SRC="$HAK5_CACHE"
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
# PHASE 1B: Skinny-Tools Source Resolution (S/B only)
# ==========================================
# Strategy: always use upstream HEAD as the source of truth. The local
# clone sitting next to the script is treated as a last-resort fallback
# only - users who don't maintain a local copy (e.g. downloaded just
# online-install.sh from GitHub) will still pick up the maintainer's
# latest pushes without having to remember to `git pull` first.
#
# Fetch order:
#   1. Try to download the GitHub tarball. On success, refresh the
#      cache at /mmc/root/.skinny-tools-cache/skinny-tools/ and use it.
#   2. On download failure: fall back to the existing cache (if any).
#   3. If no cache: fall back to the local clone at $REPO_DIR (if
#      complete). Mark the fallback in the log so the user knows
#      they're running on potentially stale content.
#   4. If none of the above: critical error, exit.
# ==========================================
if [ "$SELECTION" = "S" ] || [ "$SELECTION" = "B" ]; then
  SKINNY_CACHE_ROOT="/mmc/root/.skinny-tools-cache"
  SKINNY_CACHE="$SKINNY_CACHE_ROOT/skinny-tools"
  SKINNY_TARBALL_URL="https://github.com/skinnyrad/Skinny-Pager-Payloads/archive/refs/heads/master.tar.gz"

  SKINNY_SRC=""
  SKINNY_STAGE=""

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
    if [ -d "$SKINNY_CACHE/payloads" ] && [ -d "$SKINNY_CACHE/cross-compiled-pager-tools" ] && \
       [ -f "$SKINNY_CACHE/pagerctl.py" ] && [ -f "$SKINNY_CACHE/libpagerctl.so" ]; then
      echo "[*] Falling back to cached Skinny-Tools snapshot at $SKINNY_CACHE (may be stale)."
      SKINNY_SRC="$SKINNY_CACHE"
    elif [ -d "$LOCAL_PAYLOADS_DIR" ] && [ -d "$CROSS_TOOLS_DIR" ] && \
         [ -f "$REPO_DIR/pagerctl.py" ] && [ -f "$REPO_DIR/libpagerctl.so" ]; then
      echo "[!] No cache available; falling back to local clone at $REPO_DIR (may be stale)."
      SKINNY_SRC="$REPO_DIR"
    else
      echo "[-] Critical Error: no Skinny-Tools source available (no internet, no cache, no local clone)."
      exit 1
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

# ==========================================
# PHASE 4: Repository Payload Tree Mirroring
# ==========================================
echo "[*] Syncing custom security payloads to local hardware storage..."

if [ -d "$LOCAL_PAYLOADS_DIR" ]; then
    MERGE_NEW_LABELS=""
    MERGE_UPDATED_LABELS=""
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
    # Pre-check: count any files in the local repo that aren't on the Pager
    # AND any that have drifted from upstream. If both are zero (genuine
    # re-run no-op), skip the per-file sync block rather than iterating
    # every file just to confirm. The previous form of this check only
    # counted missing files, which would short-circuit the loop and miss
    # divergent files - that was a latent bug introduced when the
    # hash-compare was added inside the else branch.
    MISSING_COUNT=$(count_missing_files "$LOCAL_PAYLOADS_DIR" "$SYSTEM_PAYLOADS_DEST")
    UPDATED_COUNT=$(count_updated_files "$LOCAL_PAYLOADS_DIR" "$SYSTEM_PAYLOADS_DEST")
    if [ "$MISSING_COUNT" = "0" ] && [ "$UPDATED_COUNT" = "0" ]; then
      echo "[*] All Skinny-Tools payload files already present and up-to-date on Pager; per-file sync skipped."
    else
      # Portable "cp -rn" equivalent that actually descends into pre-existing
      # destination directories. BusyBox's cp -n skips the whole copy when the
      # destination dir already exists, which would silently break re-runs.
      # This loop creates all source directories in the destination (mkdir -p
      # is a no-op when they exist) and then copies only files that aren't
      # already present OR have changed upstream (sha256 differs from the
      # Pager file), preserving any local tweaks that still match upstream.
      # `find $LOCAL_PAYLOADS_DIR` (not `cd ... && find .`) so the emitted
      # paths are absolute and remain resolvable in the parent shell for
      # sha256_file - the subshell cd would orphan the relative paths.
      LOCAL_PAYLOADS_DIR="${LOCAL_PAYLOADS_DIR%/}"
      find "$LOCAL_PAYLOADS_DIR" -type d -exec mkdir -p "$SYSTEM_PAYLOADS_DEST/{}" \; 2>/dev/null
      find "$LOCAL_PAYLOADS_DIR" -type f | while IFS= read -r src; do
          rel="${src#"$LOCAL_PAYLOADS_DIR"/}"
          dst="$SYSTEM_PAYLOADS_DEST/$rel"
          if [ ! -e "$dst" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
          elif [ "$(sha256_file "$src")" != "$(sha256_file "$dst")" ]; then
            cp "$src" "$dst"
            echo "[UPDATED FILE] $rel"
          fi
        done
      # Enforce global executable permissions across launcher scripts
      find "$SYSTEM_PAYLOADS_DEST" -name "*.sh" -exec chmod +x {} \;
      echo "[+] Payloads successfully synced to $SYSTEM_PAYLOADS_DEST/"
    fi

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

    NEW_COUNT=$(echo "$NEW_PAYLOADS" | wc -w)
    UPDATED_COUNT=$(echo "$MERGE_UPDATED_LABELS" | wc -w)
    PRESENT_COUNT=$(echo "$PRESENT_PAYLOADS" | wc -w)
    echo "[*] Payload summary: $NEW_COUNT new, $UPDATED_COUNT updated, $PRESENT_COUNT unchanged."
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
