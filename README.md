# Skinny Research & Development: Custom Pager Tools

Welcome to the official Skinny R&D payload and utility repository for the Hak5 WiFi Pineapple Pager. This suite contains custom wireless reconnaissance tools, active tracking, and automated installation of Skinny R&D custom payloads.

## Repository Overview

* **Skinny-Tools/**
* **online-install.sh** - Automated live network installation script
* **pagerctl.py** - (brainphreak) Python translation layer for Pager hardware UI
* **libpagerctl.so** - (brainphreak) Native shared library for hardware interface bindings
* **payloads/** - Staging directory for custom security utilities



### Credits & Dependencies

The hardware mapping utilities (`pagerctl.py` and `libpagerctl.so`) included in this repository are from the open-source work from the [pineapple_pager_pagerctl project](https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl) by brainphreak.

Skinny R&D utilizes this framework to drive direct Python interactions with the Pager's display buffers for several fox hunting payloads. This direct integration provides the reduced latency and faster screen refresh performance critical for real-time signal tracking and foxhunting operations. Pagerctl is not used for all payloads.

---

## Installation

This method is optimized for training environments where Pagers are temporarily granted an upstream internet connection (via client Wi-Fi mode or USB-C tethering). The installer automatically provisions Python 3, updates system dependencies, pulls the security packages natively via opkg, and maps the physical UI environment.

### 1. Prerequisites

Before deploying, ensure your Pager is internet connected. The installation script will automatically start the process by validation-pinging Google DNS (8.8.8.8) before altering system dependencies.

### 2. Streamlined Target Execution Sequence

SSH into your Pager as root, navigate to the persistent storage root directory, clone the repository, and execute the installer with this command sequence:

`cd /root && git clone [https://github.com/skinnyrad/Skinny-Tools.git](https://github.com/skinnyrad/Skinny-Tools.git) && cd Skinny-Tools && chmod +x online-install.sh && ./online-install.sh`

---

## Automated Payload Deployment & Safety

The `online-install.sh` script automatically deploys all custom tools into their required operational target paths across the internal storage system (`/mmc/root/payloads/`).

### Safe Merge Mapping

The deployment utilizes non-destructive recursive mirroring (`cp -r`). Running this installer safely merges the custom Skinny R&D utilities directly inside their designated functional menus (such as the Recon and User configurations).

This automation preserves all pre-existing factory modules and configuration layers. It will never purge, wipe, format, or overwrite unrelated operational tools already resident on the hardware. Additionally, the installer executes a global sweep to verify that all shell entry points and launchers retain proper executable flags (`chmod +x`) to allow immediate execution from the Pager's physical UI menus.

---

## Included Core Utilities

### Reconnaissance & Proximity Tracking

* **Recon Engine Foxhunt AP & Clients:** High-contrast tracking readouts mapped directly to the Pager’s LCD panel. Features dynamic proximity-color thresholds (Green/Yellow/Red) based on active, hardware-parsed RSSI decibel readings (dBm) directly from the airwaves.
* **Recon Engine Aireplay AP Deauth:** Targeted, script-driven wireless client deauthentication utilizing existing background monitor modes (wlan1mon) to audit access point stability.

### Skinny-Skim-Scanner - Bluetooth Card Skimmer Detector

An aggressive, dual-mode Bluetooth discovery radar that continuously processes substitution streams from the BlueZ kernel monitor (btmon).

* Intercepts and parses both Bluetooth Classic and Bluetooth Low Energy (BLE) advertising reports simultaneously.
* Cross-references captured packets against localized MAC configurations and hardware address matrices natively.
* Triggers tactile physical haptic feedback alerts via GPIO (`/sys/class/gpio/vibrator/value`), forces high-visibility flashing LED notification cycles, and locks the hardware display to isolate rogue skimmer signatures safely.

---
