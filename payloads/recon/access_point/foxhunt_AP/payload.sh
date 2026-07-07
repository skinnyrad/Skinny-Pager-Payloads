#!/usr/bin/env bash
# Title: Foxhunt_AP
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
# Credit: brainphreak pagerctl (https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl)

# --- FIX: Hardcode the absolute persistent path on the MMC storage ---
REAL_PAYLOAD_DIR="/mmc/root/payloads/recon/access_point/foxhunt_AP"

# Force explicit environment assignment so non-interactive shells inherit them
export _RECON_SELECTED_AP_BSSID="${_RECON_SELECTED_AP_BSSID}"
export _RECON_SELECTED_AP_CHANNEL="${_RECON_SELECTED_AP_CHANNEL}"

# Ensure standard system library paths are referenced for libpagerctl.so
export LD_LIBRARY_PATH="/usr/lib:/lib:$LD_LIBRARY_PATH"

# Move directly into the true payload folder and execute safely
cd "$REAL_PAYLOAD_DIR"
python3 "${REAL_PAYLOAD_DIR}/foxhunt_ap.py" > /mmc/root/crash.log 2>&1
