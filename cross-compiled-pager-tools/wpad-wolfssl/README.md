# wpad-wolfssl for the Hak5 WiFi Pineapple Pager

Pinned OpenWrt `wpad-wolfssl` + `libwolfssl` `.ipk` packages (mipsel_24kc)
for the Pager running OpenWrt 24.10.1 / `ramips/mt76x8`.

The Pager ships with Hak5's patched **`wpad-basic-mbedtls`** (790 KB, sha256
`810d224e...`). That build strips the **Passpoint / Hotspot 2.0 / Interworking /
EAP-AKA / EAP-SIM** features the ATT-Hotspot2 payloads need. The stock
`wpad-wolfssl` build (1.39 MB, sha256 `d958be65...`) has them compiled in.

These packages are **never installed with `opkg`** by the Skinny-Tools
installer. `opkg install wpad-wolfssl` would `opkg remove wpad-basic-mbedtls`
(it `Conflicts:` it), destroying the factory radio stack. Instead the
installer *extracts* the binaries and the `wpad-swap` engine bind-mounts them
over `/usr/sbin/wpad` only for the duration of a payload run.

## Contents

| File | Size | sha256 |
|---|---|---|
| `wpad-wolfssl_2024.09.15~5ace39b0-r3_mipsel_24kc.ipk` | 760 KB | `3ed3b333...` |
| `libwolfssl5.9.1.e624513f_5.9.1-r1_mipsel_24kc.ipk` | 605 KB | `5b7e1edf...` |

Extracted payloads (what the engine actually stages):

| Path | Size | sha256 |
|---|---|---|
| `usr/sbin/wpad` (also hostapd/wpa_supplicant, identical ELF) | 1394311 | `d958be658486bf0637aabbb859230895bae93aff22ec519bdd45c93e4c029f14` |
| `usr/lib/libwolfssl.so.5.9.1.e624513f` | 1388527 | `f3e25b79294dd3088f5aef716e89d9350be1552283d3ce2cae3593d7202ef5cd` |

`wpad`, `hostapd`, `wpa_supplicant`, and `hostapd-radius` are **the same
1.39 MB ELF** (`wpad` dispatches on `argv[0]`). The Pager resolves
`/usr/sbin/hostapd` and `/usr/sbin/wpa_supplicant` as **symlinks to
`/usr/sbin/wpad`**, so the engine must overlay all three paths -- overlaying
only `/usr/sbin/wpad` leaves hostapd/wpa_supplicant running the old binary
(that is exactly the "hostapd rejects new IEs as unknown config" failure the
v28 notes describe).

## Provenance

```
https://downloads.openwrt.org/releases/24.10.1/packages/mipsel_24kc/base/
    wpad-wolfssl_2024.09.15~5ace39b0-r3_mipsel_24kc.ipk
    libwolfssl5.9.1.e624513f_5.9.1-r1_mipsel_24kc.ipk
```

## ABI / dependency note

The 24.10.1 feed is at `r3`; the Pager's factory packages are `r2`. This does
**not** matter for the bind-mount approach because we never invoke `opkg`:

- Every `NEEDED` soname of the `r3` binary already exists on the Pager
  (`libubus.so.20250102`, `libucode.so.20230711`, `libblobmsg_json.so.20240329`,
  `libnl-tiny.so.1`, `libudebug.so`, `libc.so`, `libgcc_s.so.1`, `libubox.so.20240329`).
- Only `libwolfssl.so.5.9.1.` is new, and the `libwolfssl` `.ipk` provides it.

So the engine installs exactly one file to `/usr/lib` (the libwolfssl shared
object) and stages the rest in `/mmc/root/wpad-swap/`; the on-disk
`/usr/sbin/wpad` is never touched.

## Recovery

Bind mounts do not survive a reboot. If anything is ever left in a weird state,
**reboot the Pager** and it comes back on factory `wpad-basic-mbedtls`. The
`wpad-swap recover` subcommand also unmounts any stray overlays and restarts
the `wpad` service.
