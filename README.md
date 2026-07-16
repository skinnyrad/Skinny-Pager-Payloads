# Skinny Research & Development: Custom Pager Tools

Welcome to the official Skinny R&D payload and utility repository for the Hak5 WiFi Pineapple Pager. This suite contains custom wireless reconnaissance tools, active tracking, and automated installation of Skinny R&D custom payloads.

## Repository Overview

* **Skinny-Tools/**
* **online-install.sh** - Automated live network installation script
* **pagerctl.py** - (brainphreak) Python translation layer for Pager hardware UI
* **libpagerctl.so** - (brainphreak) Native shared library for hardware interface bindings
* **payloads/** - Staging directory for custom security utilities



### Capabilities Added (Cross-compiled tools)
* **rtl_433_MIPS** - Write payloads to detect TPMS sensors and other RTL-SDR detections
* **Ubertooth-MIPS** - Installs cross-compiled Ubertooth tools and libraries for use in Bluetooth payloads

---

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

`opkg update && opkg install git-http && cd /root && git clone https://github.com/skinnyrad/Skinny-Tools.git && cd Skinny-Tools && chmod +x online-install.sh && ./online-install.sh`

### 3. Usage Modes

The installer supports two modes. Run it from inside the cloned `Skinny-Tools/` repository so it can discover `payloads/` and `cross-compiled-pager-tools/`.

```
./online-install.sh           # Install / update (default)
./online-install.sh --uninstall   # Remove all Skinny-Tools customizations
./online-install.sh --help        # Show usage
```

The default install/update flow is fully re-runnable: a second run after `git pull` will only install newly-added `.ipk` packages and copy any new payload files, leaving everything else alone. The script preserves any local tweaks you have made to existing payload files.

---

## Uninstalling

To return the Pager to its pre-Skinny-Tools state, run:

```
cd /root/Skinny-Tools && ./online-install.sh --uninstall
```

The uninstall will:

* Remove every cross-compiled **tool** `.ipk` package installed by this repo (under `cross-compiled-pager-tools/`, e.g. `rtl_433`, `ubertooth-utils`).
* Remove every custom payload directory staged under `payloads/user/Skinny-Tools/`, `payloads/user/utilities/`, and the `payloads/recon/` trees.
* Remove the `PagerCTL` hardware-interface symlinks at `/usr/lib/libpagerctl.so` and inside the Python `site-packages` directory.

The uninstall will **not** touch:

* Hak5 factory payloads (`payloads/alerts/*`, factory `payloads/recon/*`, factory `payloads/user/*` like `evil_portal`, `prank`, etc.).
* Cross-compiled **library** `.ipk` packages (`librtlsdr`, `libbtbb`, `libubertooth`, ...). These are general-purpose system libraries that other Pager workflows may rely on, so they are left in place.
* The system packages installed by the pre-flight phase (`python3`, `aircrack-ng`, `tcpdump`, `libpcap`, `libopenssl`, `libffi`, `libbz2`, `zlib`, `libpcre2`, `libnl-core200`, `libnl-genl200`). These are general-purpose tools that other Pager workflows may rely on, so they are left in place.

For a full factory reset, remove everything manually:

  ```
  opkg remove rtl_433 ubertooth-utils \
              librtlsdr libbtbb libubertooth \
              python3 aircrack-ng tcpdump libpcap libopenssl \
              libffi libbz2 zlib libpcre2 libnl-core200 libnl-genl200
  ```

---

## Automated Payload Deployment & Safety

The `online-install.sh` script automatically deploys all custom tools into their required operational target paths across the internal storage system (`/mmc/root/payloads/`).

### Safe Merge Mapping

The deployment uses a per-file no-clobber copy: only files that don't already exist at the destination are written, and any local tweaks to existing payload files are preserved across re-runs. This safely merges the custom Skinny R&D utilities directly inside their designated functional menus (such as the Recon and User configurations) without overwriting Hak5 factory modules that share the same parent directory.

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
