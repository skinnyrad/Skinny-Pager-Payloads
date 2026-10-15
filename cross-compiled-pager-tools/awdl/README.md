# AWDL-Stim dependency packages

Vendored OpenWrt **24.10.1** `mipsel_24kc` `.ipk`s that the **AWDL-Stim** payload
(`payloads/user/Skinny-Tools/AWDL-Stim/`) needs but that are **not part of the
stock Pager firmware**. They are stock OpenWrt feed packages (no cross-compiling
required) — vendored here so the *offline* installer can provision a field unit
with no internet.

| Package | Needed by |
|---|---|
| `iw` | monitor-vif creation in `payload.sh` (`iw phy … interface add`) |
| `libev` | `owl` (AWDL peer binary) links `libev.so.4` |
| `scapy` | observer `awdl_log.py` (and `bonjour_awdl.py`) |
| `avahi-nodbus-daemon` | AirPlay lure (`avahi-daemon`) |
| `libavahi-nodbus-support` | avahi support library |

## Install destination (important)

- `iw`, `libev`, `scapy` → **root overlay** (normal `opkg install`).
- `avahi-nodbus-daemon` + `libavahi-nodbus-support` → **`/mmc` dest**
  (`opkg install -d mmc …`), because the AWDL-Stim wake script invokes
  `/mmc/usr/sbin/avahi-daemon` by absolute path. Installing avahi to the root
  overlay will make the lure fail to start.

## Who installs these

- **Online** (`online-install.sh`): fetched from the OpenWrt feed — `iw libev
  scapy` via `REQUIRED_PKGS`, avahi via an explicit `opkg install -d mmc`. This
  directory is **excluded** from the online installer's cross-tool `.ipk` scan.
- **Offline** (`offline_install.sh`): installs the `.ipk`s from this directory
  (run from the repo root; it references `cross-compiled-pager-tools/awdl/`).

Source: `https://downloads.openwrt.org/releases/24.10.1/packages/mipsel_24kc/`
and `.../releases/24.10.1/packages/mipsel_24kc/base/` (for `iw`).
