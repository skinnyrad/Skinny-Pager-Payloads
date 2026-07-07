#!/bin/sh
# Title: Git Repository Live Online Installer (Python, Security Tools, & Payloads)
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Please run as root (SSH into the Pager)."
  exit 1
fi

# Get the directory where the cloned repository sits
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PAYLOADS_DIR="$REPO_DIR/payloads"
SYSTEM_PAYLOADS_DEST="/mmc/root/payloads"

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
# PHASE 2: Live Network Package Bootstrap
# ==========================================
echo "[*] Synchronizing OpenWrt package ecosystem lists..."
opkg update

echo "[*] Provisioning Python3 framework and system cryptography..."
opkg install python3-base python3-light libffi libbz2-1.0

echo "[*] Provisioning wireless sniffing stack components..."
opkg install zlib libpcap libopenssl libpcre2 libnl-core200 libnl-genl200 aircrack-ng

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
# PHASE 3: Repository Payload Tree Mirroring
# ==========================================
echo "[*] Syncing custom security payloads to local hardware storage..."

if [ -d "$LOCAL_PAYLOADS_DIR" ]; then
    mkdir -p "$SYSTEM_PAYLOADS_DEST"
    # Merges your Git tracking folders seamlessly with any existing payloads
    cp -r "$LOCAL_PAYLOADS_DIR"/* "$SYSTEM_PAYLOADS_DEST/"
    # Enforce global executable permissions across launcher scripts
    find "$SYSTEM_PAYLOADS_DEST" -name "*.sh" -exec chmod +x {} \;
    echo "[+] Payloads successfully synced to $SYSTEM_PAYLOADS_DEST/"
else
    echo "[-] Error: 'payloads' folder missing from the cloned Git repository!"
    exit 1
fi

# ==========================================
# PHASE 4: Global PagerCTL Environment Setup
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
# PHASE 5: Functional Verification Check
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
