# README: Installing Ubertooth Utilities on Hak5 WiFi Pineapple

This archive contains the Ubertooth binaries cross-compiled for the `mipsel_24kc` architecture, specifically configured to run on the **Hak5 WiFi Pineapple (Mark VII / Enterprise)** architecture.

## Package Manifest

* `libbtbb_2020-12-R1-1_mipsel_24kc.ipk` (Bluetooth Baseband Library - **Dependency 1**)
* `libubertooth_2020-12-R1-1_mipsel_24kc.ipk` (Ubertooth Core Library - **Dependency 2**)
* `ubertooth-utils_2020-12-R1-1_mipsel_24kc.ipk` (Ubertooth Command Line Tools)

---

## Installation Instructions

### Step 1: Transfer the Packages to the Pineapple

Use `scp` to copy all three `.ipk` files from your host machine into the volatile `/tmp` directory on the WiFi Pineapple.

Open your local terminal, navigate to the folder containing the files, and run:

```bash
scp *.ipk root@172.16.52.1:/tmp/

```

### Step 2: SSH into the WiFi Pineapple

Establish an SSH session to get terminal access to the device:

```bash
ssh root@172.16.52.1

```

### Step 3: Install the IPK Files via OPKG

On OpenWrt, the command to install a local package file is `opkg install <filename>`.

Because `ubertooth-utils` relies on `libubertooth`, which in turn relies on `libbtbb`, you must install them in order, or use a wildcard to let `opkg` handle the dependency loop automatically.

**Option A: Install all at once (Recommended)**

```bash
cd /tmp
opkg install libbtbb_*.ipk libubertooth_*.ipk ubertooth-utils_*.ipk

```

**Option B: Install sequentially**

```bash
cd /tmp
opkg install libbtbb_2020-12-R1-1_mipsel_24kc.ipk
opkg install libubertooth_2020-12-R1-1_mipsel_24kc.ipk
opkg install ubertooth-utils_2020-12-R1-1_mipsel_24kc.ipk

```

### Step 4: Clean Up the `/tmp` Directory

Once the installation finishes successfully, remove the installer files from the device's RAM to free up memory:

```bash
rm /tmp/*.ipk

```

---

## Verifying the Installation

To ensure the binaries are installed and tracking correctly, plugin your Ubertooth One to the Pineapple's USB port and run:

```bash
ubertooth-util -v

```

If it returns the firmware version of your connected hardware, the installation was successful.
