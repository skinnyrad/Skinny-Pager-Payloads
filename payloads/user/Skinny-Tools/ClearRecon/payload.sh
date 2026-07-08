#!/bin/bash
# Title: Clear Recon
# Description: Clears the recon.db database and resets the recon service
# Author: Skinny
# Version: 1.0

#remove the recon database
rm /root/recon/recon.db

sleep 2

#restart the recon service
/etc/init.d/pineapd restart
