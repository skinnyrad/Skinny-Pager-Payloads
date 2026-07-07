#!/bin/sh
# Title: Foxhunt_Clients
# Author: Jeff Benson (erg0Pr0xy) - Skinny Research & Development
# Credit: brainphreak pagerctl (https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl)

# 1. FIX: Matches your exact system folder path completely
PAYLOAD_DIR="/mmc/root/payloads/recon/client/foxhunt_clients"

# 2. Clean environment pathing (System reads global symlinks natively now!)
export PATH="/mmc/usr/bin:$PATH"
export LD_LIBRARY_PATH="/usr/lib:/lib:$LD_LIBRARY_PATH"

# 3. Force explicit environment assignment using the verified Recon variables
export _RECON_SELECTED_AP_BSSID="${_RECON_SELECTED_AP_BSSID}"
export _RECON_SELECTED_AP_CHANNEL="${_RECON_SELECTED_AP_CHANNEL}"
export _RECON_SELECTED_CLIENT_MAC_ADDRESS="${_RECON_SELECTED_CLIENT_MAC_ADDRESS}"

# 4. Route output to the crash log if the background execution drops out
cd "$PAYLOAD_DIR"
python3 "${PAYLOAD_DIR}/foxhunt_clients.py" > /mmc/root/crash.log 2>&1
