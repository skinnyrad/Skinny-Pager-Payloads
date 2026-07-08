#!/bin/sh

# 1. Fetch the current state of logrecon (default to 0 if not found)
CURRENT_STATE=$(uci -q get pineapd.@pineapd[0].logrecon)
[ -z "$CURRENT_STATE" ] && CURRENT_STATE="0"

# Determine the target state and a user-friendly label
if [ "$CURRENT_STATE" = "1" ]; then
    TARGET_STATE="0"
    LABEL="STOP"
else
    TARGET_STATE="1"
    LABEL="START"
fi

# 2. Prompt the user (Default is Yes)
printf "Do you want to toggle Recon? (Current status: %s, Target: %s) [Y/n]: " "$CURRENT_STATE" "$LABEL"
read -r response

# Normalize input (empty or starting with y/Y means Yes)
response=$(echo "$response" | tr '[:upper:]' '[:lower:]')
if [ -z "$response" ] || [ "$response" = "y" ] || [ "$response" = "yes" ]; then
    echo "Toggling Recon to $LABEL..."
    
    # 3. Update UCI configuration
    uci set pineapd.@pineapd[0].logrecon="$TARGET_STATE"
    uci commit pineapd
    
    # 4. Restart the service to apply changes
    /etc/init.d/pineapd restart
    echo "Recon is now $LABEL."
else
    echo "Action canceled. Recon remains unchanged."
fi
