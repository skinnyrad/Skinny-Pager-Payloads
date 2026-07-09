# rtl_433 for the Hak5 WiFi Pineapple Pager

Cross-compiled `rtl_433` `.ipk` packages (mipsel_24kc) for the Pineapple
Pager running OpenWrt 24.10.1. Built inside the `openwrt/sdk:ramips-mt7621`
Docker image against the Pager's actual SDK target (`ramips/mt76x8`,
OpenWrt 24.10.7), following the same build pattern as the sibling
`../ubertooth/openwrt-feed/build.sh` (gzip-tar `.ipk` format, not
Debian `ar`).

## What's in `build-output/`

| File | Size | Notes |
|---|---|---|
| `rtl_433_25.12-1_mipsel_24kc.ipk` | ~470 KB | The `rtl_433` binary, man page, and 58 decoder config files. Depends: `libc`, `librtlsdr`, `libusb-1.0`. |
| `librtlsdr_0.6.0-1_mipsel_24kc.ipk` | ~118 KB | `librtlsdr.so.0.0.5` + headers + pkg-config. Depends: `libc`, `libusb-1.0`. |

`libusb-1.0-0` is already installed on the Pager, so no `libusb` `.ipk` is
shipped.

## Prerequisites

- A Hak5 WiFi Pineapple Pager on the default `172.16.52.1` AP
  (or any reachable IP — replace accordingly)
- An RTL-SDR dongle (RTL2832U-based) plugged into the Pager's USB-A port
- `sshpass` on the host for non-interactive `scp`/`ssh` (the Pager's
  default root password is `password`)

## Install on the Pager

One-shot install — copy, install in the right order, clean up:

```bash
PKG_HOST=root@172.16.52.1
PKG_PASS=password

# 1. Copy the .ipks to the Pager's /tmp
sshpass -p "$PKG_PASS" scp -O \
  build-output/librtlsdr_0.6.0-1_mipsel_24kc.ipk \
  build-output/rtl_433_25.12-1_mipsel_24kc.ipk \
  "$PKG_HOST:/tmp/"

# 2. Install in dependency order (librtlsdr first, then rtl_433)
sshpass -p "$PKG_PASS" ssh -o StrictHostKeyChecking=no "$PKG_HOST" \
  'opkg install /tmp/librtlsdr_0.6.0-1_mipsel_24kc.ipk && \
   opkg install /tmp/rtl_433_25.12-1_mipsel_24kc.ipk'

# 3. Clean up the .ipks from /tmp
sshpass -p "$PKG_PASS" ssh -o StrictHostKeyChecking=no "$PKG_HOST" \
  'rm -f /tmp/librtlsdr_0.6.0-1_mipsel_24kc.ipk \
        /tmp/rtl_433_25.12-1_mipsel_24kc.ipk'
```

> The `-O` flag on `scp` is required on recent OpenSSH clients (it
> disables the SFTP fallback the Pager's dropbear doesn't support).

### Verify the install

```bash
sshpass -p password ssh root@172.16.52.1 \
  'opkg list-installed | grep -E "librtlsdr|rtl_433"; \
   rtl_433 -V; \
   ldd /usr/bin/rtl_433'
```

Expected output: `librtlsdr - 0.6.0-1`, `rtl_433 - 25.12-1`, and
`ldd` showing `librtlsdr.so.0` and `libusb-1.0.so.0` resolved.

## Uninstall

```bash
sshpass -p password ssh root@172.16.52.1 \
  'opkg remove rtl_433 && opkg remove librtlsdr'
```

## Basic rtl_433 commands

The binary is on PATH at `/usr/bin/rtl_433`. Configuration files for
flex decoders are in `/usr/share/rtl_433/`.

```bash
# Help
rtl_433 -h

# Version + supported decoders
rtl_433 -V
rtl_433 -R help 2>&1 | less

# Listen on the most common 433.92 MHz ISM band, default decoders
rtl_433 -f 433.92M -s 250k -g 40 -v

# Auto-gain instead of fixed
rtl_433 -f 433.92M -g auto -v

# Quiet JSON output to a file (good for capturing then pulling back)
rtl_433 -f 433.92M -M stats -F json > /tmp/rtl_433.json 2>/tmp/rtl_433.log
# Later, on the host:
# scp root@172.16.52.1:/tmp/rtl_433.json .
```

### Frequency-hopping to cover more bands

```bash
# 315 MHz (US/Asia) + 433.92 MHz (EU/world) + 868.35 MHz (EU SRD)
rtl_433 -f 315M -f 433.92M -f 868.35M -H 10 -g 40 -M stats
```

### Limit to specific decoders (less noise)

Disable all decoders with `-R 0`, then whitelist:

```bash
# All TPMS decoders, 433.92 MHz
rtl_433 -R 0 \
  -R 145 -R 146 -R 147 -R 148 -R 149 -R 150 -R 151 -R 152 -R 153 \
  -R 154 -R 155 -R 156 -R 157 -R 158 -R 159 -R 160 -R 161 -R 162 \
  -R 174 -R 175 -R 176 \
  -f 433.92M -g 40 -v

# Just weather stations
rtl_433 -R 0 -R 19 -R 21 -R 35 -R 47 -R 71 -R 92 -f 433.92M -g 40

# Discovery mode - let rtl_433 figure out what's on the air
rtl_433 -f 433.92M -M stats 2>&1 | grep -iE "model|protocol"
```

`-M stats` prints a per-decoder hit summary when you Ctrl-C, which is
the fastest way to find out which protocol is actually in use in your
area. Use the printed decoder ID in subsequent `-R` runs to lock on.

### Long capture in the background

```bash
ssh root@172.16.52.1 'nohup rtl_433 -f 433.92M -H 10 -g 40 \
  -F json -M stats > /tmp/cap.json 2>/tmp/cap.log &'
# Pull the logs back later:
# scp root@172.16.52.1:/tmp/cap.{json,log} .
```

## Rebuild the .ipks

```bash
docker run --rm --platform linux/amd64 --user root \
  -v "$PWD/openwrt-feed:/feed" \
  -v "$PWD/rtl_433:/src" \
  -v "$PWD/build-output:/builder/output" \
  openwrt/sdk:ramips-mt7621 \
  bash -c "FEED_DIR=/feed SRC_DIR=/src /feed/build.sh"
```

This will (re)download the OpenWrt 24.10.7 SDK for `ramips/mt76x8`,
install build tools, build `libusb-1.0` for staging, build
`librtlsdr 0.6.0`, build `rtl_433` (commit `2965b011` of the cloned
`merbanan/rtl_433` master), strip, and overwrite the `.ipk` files in
`build-output/`.

To pin to a specific tag (e.g. the 25.12 release) instead of HEAD,
add `git -C /src checkout 25.12` before the build runs.

## Troubleshooting

**`scp` hangs on connection** — recent OpenSSH defaults to SFTP, which
the Pager's dropbear doesn't speak. Add `-O` to `scp` (already in the
command above) or pass `-o HostKeyAlgorithms=+ssh-rsa` if the host
key still won't verify.

**`ldd /usr/bin/rtl_433` reports `librtlsdr.so.0 => not found`** —
the `librtlsdr` `.ipk` wasn't installed (or got removed). Reinstall
it from `build-output/`.

**`rtl_433` errors `No supported devices found`** — the RTL-SDR
dongle isn't seen. Check `lsusb` on the Pager and that the kernel
modules `kmod-usb-core` and `kmod-usb2` are loaded (they are by
default on the Pager).

**No output at all** — wrong frequency or gain too low. Try
`-g auto -vv` to see raw pulses and confirm there's RF activity.

## Layout

```
rtl_433/
  README.md                        this file
  openwrt-feed/
    build.sh                       cross-compile build script
  rtl_433/                         upstream source (cloned from
                                   github.com/merbanan/rtl_433,
                                   commit 2965b011)
  build-output/
    rtl_433_25.12-1_mipsel_24kc.ipk
    librtlsdr_0.6.0-1_mipsel_24kc.ipk
    rtl_433_staging/               build intermediates
    pkgroot/                       build intermediates
```
