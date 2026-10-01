#!/bin/bash
# Title: Auto-Kick
# Description: Toggle for CatchAndRelease (catch and release). While this
#              payload is ENABLED in the Pager's Alerts UI, CatchAndRelease
#              deauths the client right AFTER the alert is sent, once it has
#              finished gathering the device info. Disable this payload to
#              leave devices connected.
# Author: Skinny Research & Development
# Version: 1.0
#
# This payload is intentionally a no-op: it exists as the on/off switch that
# CatchAndRelease reads (it looks for its sibling "Auto-Kick" directory). The
# actual deauth is performed by CatchAndRelease after its alert, so the device
# is only kicked once the catch has been recorded.

exit 0
