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
  - Recommended hardware: rtl_sdr dongle plugged into USB-A 
* **Ubertooth-MIPS** - Installs cross-compiled Ubertooth tools and libraries for use in Bluetooth payloads
  - Recommended hardware: Ubertooth plugged into USB-A
* **Direct python output bypassing Pager UI** - Added python readouts to skip Pager UI. It seems to improve speed slightly for payloads that lag on UI readout. See brainphreak's repo at https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl.


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

> The usage summary below is informal; run `./online-install.sh --help` for the authoritative text emitted by the script itself.

The installer is interactive: when run with no flag it prompts for a payload source.

```
[S] Skinny-Tools   - Install / update the Skinny-Tools repo (default flow)
[H] Hak5 payloads  - Pull github.com/hak5/wifipineapplepager-payloads
                     and merge its library/ tree onto the Pager
[B] Both           - Skinny-Tools + Hak5 payloads
```

`S` and `B` require (or auto-fetch) the Skinny-Tools repo; `H` is self-contained and only needs internet access. Run it from inside the cloned `Skinny-Tools/` repository so it can discover `payloads/` and `cross-compiled-pager-tools/` directly. If a full local clone isn't present, `S`/`B` selections auto-fetch the GitHub tarball at runtime so a manual `git clone` is not strictly required.

```
./online-install.sh           # Install / update (interactive S/H/B prompt)
./online-install.sh --uninstall   # Remove all Skinny-Tools customizations
./online-install.sh --help        # Show authoritative usage text
```

Hak5 payload fetches are cached at `/mmc/root/.skinny-tools-cache/hak5-library/` so subsequent `H`/`B` runs skip the GitHub download and only diff the cached manifest against the Pager's filesystem. Delete that directory to force a fresh download on the next run.

All payload merges use **no-clobber semantics**: missing payloads are copied in, but nothing already on the Pager is ever overwritten or removed by the install path. The script preserves any local tweaks you have made to existing payload files.

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
* Tidy up by `rmdir`-ing `payloads/user/Skinny-Tools/` and `payloads/user/utilities/` if they end up empty after payload removal. Hak5 factory recon skeletons under `payloads/recon/` are never touched.

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

The deployment uses two layers of no-clobber merging so re-runs are safe and local tweaks to existing payload files are preserved:

* **Dir-level no-clobber** for new sub-payloads. Both the Hak5 library fetch (Phase 1A) and the Skinny-Tools mirror (Phase 4) walk the source tree one payload at a time and copy each subdir into the destination only if no folder of that name already exists. Hak5's `library/user/` is walked one factory folder deeper than the Skinny-Tools walk because Hak5 nests payloads inside factory roots (e.g. `user/evil_portal/<payload>/payload.sh`); walking just one level would see those factory roots as already-present and silently skip every payload inside them.
* **Per-file no-clobber** for Skinny-Tools payload files (Phase 4). A portable loop descends into existing destination directories and copies only files that aren't already present. This is needed because BusyBox's `cp -n` skips the entire copy when the destination dir already exists, which would silently break re-runs; the loop preserves any local edits to existing files.

For the cross-compiled `.ipk` packages under `cross-compiled-pager-tools/`, install ordering matters: **library `.ipk` files install first, then tool `.ipk` files**, so cross-package dependencies resolve cleanly. Already-installed packages are detected via `opkg list-installed` and skipped without re-running `opkg install`.

This automation preserves all pre-existing factory modules and configuration layers. It will never purge, wipe, format, or overwrite unrelated operational tools already resident on the hardware. Additionally, the installer executes a global sweep (`chmod +x` on `*.sh` files under `/mmc/root/payloads/`) to verify that all shell entry points and launchers retain proper executable flags for immediate execution from the Pager's physical UI menus.

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
