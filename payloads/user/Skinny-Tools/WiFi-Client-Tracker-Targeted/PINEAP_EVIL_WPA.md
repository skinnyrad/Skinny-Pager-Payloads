# WiFi Pineapple Pager - PineAP Evil WPA AP (pineape) Control

**Device:** Pineapple Pager v24.10.1 (r28597-0425664679)
**Tested:** July 2026 against firmware on `root@172.16.52.1`
**Related docs:** `HAK5_CUSTOM_BINARIES.md`, `PAGER_API_AND_RECON.md`
**Related payload:** `payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh` (see [section 8](#8-targeted-client-tracking---wi-fi-client-tracker-targeted-payload))

---

## TL;DR

There are **two independent control layers** for the "Evil WPA AP" feature on the Pager, and only one of them actually brings the BSS up or down. To enable or disable the Evil WPA AP from a terminal, use the `hak5cmd` `WIFI_WPA_AP` / `WIFI_WPA_AP_DISABLE` commands (or the equivalent UCI commands), **not** `hostapd_cli pineape_*` and **not** the `/api/pineap/hostapd/set_config` HTTP endpoint.

| Want to do this? | Use this |
|---|---|
| Actually start/stop the Evil WPA AP broadcast (what your iPhone sees) | `WIFI_WPA_AP` / `WIFI_WPA_AP_DISABLE` hak5cmd, or UCI on `wireless.wlan0wpa` |
| Toggle the PineAP-Enterprise sub-feature (auth passthrough / karma overlay on the BSS) | `hostapd_cli ... pineape_enable / pineape_disable` |
| Toggle the auth passthrough sub-feature specifically | `hostapd_cli ... pineape_auth_enable / pineape_auth_disable` |
| Toggle the main PineAP/Mimic (separate feature, not Evil WPA) | `hostapd_cli ... pineap_enable / pineap_disable` |
| Watch clients associate with the Evil WPA AP and pick one to track in real time | [`WiFi-Client-Tracker-Targeted` payload](#8-targeted-client-tracking---wi-fi-client-tracker-targeted-payload) |

The HTTP API endpoint `/api/pineap/hostapd/set_config` writes UCI but on this firmware does **not** reconfigure the running hostapd, so it appears to be a no-op for live state. The `pineape_*` hostapd_cli commands flip a sub-feature flag but leave the BSS broadcasting.

---

## Table of Contents

1. [The Two-Layer Architecture](#1-the-two-layer-architecture)
2. [Layer A - The wifi-iface (the BSS your iPhone sees)](#2-layer-a---the-wifi-iface-the-bss-your-iphone-sees)
3. [Layer B - The hostapd pineape_* sub-feature flag](#3-layer-b---the-hostapd-pineape_-sub-feature-flag)
4. [Why the HTTP API and UCI look like they work but don't](#4-why-the-http-api-and-uci-look-like-they-work-but-dont)
5. [How to verify state](#5-how-to-verify-state)
6. [End-to-end examples (enable, disable, reconfigure)](#6-end-to-end-examples)
7. [Common pitfalls](#7-common-pitfalls)
8. [Targeted client tracking - WiFi-Client-Tracker-Targeted payload](#8-targeted-client-tracking---wi-fi-client-tracker-targeted-payload)
   - 8.1 [What it does](#81-what-it-does)
   - 8.2 [Launch modes](#82-launch-modes)
   - 8.3 [The LIST_PICKER pattern for interactive scripts](#83-the-list_picker-pattern-for-interactive-scripts)
   - 8.4 [Output mirroring (LOG + printf)](#84-output-mirroring-log--printf)
   - 8.5 [Lessons baked into the payload](#85-lessons-baked-into-the-payload)
   - 8.6 [Putting it all together](#86-putting-it-all-together)
9. [Quick reference card](#9-quick-reference-card)

---

## 1. The Two-Layer Architecture

The "Evil WPA AP" feature on the Pager is composed of two independent pieces:

```
+--------------------------------------------------------------+
|  Layer A:  wireless.wlan0wpa  (a normal OpenWrt wifi-iface)  |
|  ---                                                          |
|  UCI:  /etc/config/wireless, section 'wireless.wlan0wpa'      |
|  Process:  hostapd BSS on phy0, ifname wlan0wpa              |
|  What it does:                                                |
|    - Brings up the AP interface (type AP, channel, txpower)   |
|    - Broadcasts beacons with SSID 'IceCreamBase' (or whatever |
|      you set)                                                 |
|    - Handles WPA2-PSK association                             |
|  ---                                                          |
|  This is what your phone actually sees in its Wi-Fi list.     |
+--------------------------------------------------------------+

+--------------------------------------------------------------+
|  Layer B:  hostapd pineape_* sub-feature flag                |
|  ---                                                          |
|  UCI:  /etc/config/pineapd, section '@hostapd[0]'            |
|        options pineap_disabled, pineape_disabled,            |
|                pineape_auth_pass                              |
|  Process:  runtime flag inside the hostapd process for BSS   |
|            wlan0wpa (toggled over the hostapd control socket |
|            at /var/run/hostapd/wlan0wpa)                      |
|  What it does:                                                |
|    - Enables/disables PineAP-Enterprise behavior overlay on  |
|      the BSS: opportunistic key caching, Enterprise auth    |
|      passthrough, and related karma-style behavior           |
|    - Does NOT touch the BSS, the SSID, the channel, or the  |
|      beacon                                                    |
+--------------------------------------------------------------+
```

Setting Layer B does **not** affect Layer A. This is why `pineape_disable` returning `OK` and `pineape_state` reporting `DISABLED` did not make the iPhone lose sight of `IceCreamBase`.

---

## 2. Layer A - The wifi-iface (the BSS your iPhone sees)

### 2.1 Where the config lives

`/etc/config/wireless`:

```
config wifi-iface 'wlan0wpa'
    option device   'radio0'
    option ifname   'wlan0wpa'
    option mode     'ap'
    option ssid     'IceCreamBase'
    option disabled '0'
    option hidden   '0'
    option encryption 'psk2'
    option key      '22222222'
```

This is a stock OpenWrt `wifi-iface` definition. The Pager's Go backend (`/pineapple/pineapple`) treats it as a managed BSS and exposes it through the hak5cmd `WIFI_WPA_AP*` command set (see `HAK5_CUSTOM_BINARIES.md` section 7).

### 2.2 How to disable Layer A

#### Method 1 - `hak5cmd` (recommended, persistent)

```sh
WIFI_WPA_AP_DISABLE wlan0wpa
```

This sets `wireless.wlan0wpa.disabled='1'`, commits, and reloads wifi. The BSS disappears from hostapd immediately. Verified on this device: `hostapd_cli ... status` `bssid[*]/ssid[*]` list shrinks by one entry, `iw dev wlan0wpa` reports the interface is gone.

Other useful commands from the same family:

```sh
WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222     # enable with explicit config
WIFI_WPA_AP_CLEAR wlan0wpa                          # remove the config entirely
WIFI_WPA_AP_HIDE wlan0wpa                           # keep broadcasting, hide SSID
```

#### Method 2 - Raw UCI (works the same way, no hak5cmd needed)

```sh
# Disable
uci set wireless.wlan0wpa.disabled='1'
uci commit wireless
wifi reload

# Enable
uci set wireless.wlan0wpa.disabled='0'
uci commit wireless
wifi reload
```

Use this when you don't want to depend on the hak5cmd symlink, e.g. in early boot scripts.

### 2.3 What this does NOT do

It does **not** touch the PineAP/Mimic feature (which lives in `pineapd`) and does **not** touch the PineAP-Enterprise sub-feature (Layer B). If you want to keep the BSS up but turn the PineAP behavior off, you want Layer B; if you want the BSS gone, you want Layer A.

---

## 3. Layer B - The hostapd pineape_* sub-feature flag

### 3.1 Where the config lives

`/etc/config/pineapd`:

```
config hostapd
    list mgmtiface 'wlan0mgmt'
    list wpaiface  'wlan0wpa'
    option pineap_disabled  '1'   # main PineAP/Mimic off
    option pineape_disabled '0'   # PineAP-Enterprise sub-feature ON
    option pineape_auth_pass '1'  # auth passthrough ON
```

UCI option naming is a bit misleading: `pineape_disabled='0'` means "PineAPE sub-feature is enabled". This is the only flag actually read by the hostapd process for runtime behavior; the other UCI options in this section are bookkeeping for the Go backend.

### 3.2 The Hak5-patched `hostapd_cli`

The Pager ships a Hak5 fork of `hostapd_cli` (version banner: `PineAP and Karma improvements ... by Mike Kershaw - mike@hak5.org`). It exposes custom commands that don't exist upstream:

```
pineap_state                     - Get current PineAP state
pineap_enable                    - Enable PineAP
pineap_disable                   - Disable PineAP
pineap_reload                    - Reload PineAP interface and filter config
pineap_default_ssid              - Get current PineAP default SSID
pineap_set_default_ssid <ssid>   - Set default PineAP SSID

pineape_state                    - Get current PineAPE (Enterprise) state
pineape_enable                   - Enable PineAPE (Enterprise)
pineape_disable                  - Disable PineAPE (Enterprise)

pineape_auth_state               - Get current PineAPE auth passthrough state
pineape_auth_enable              - Enable PineAPE auth passthrough
pineape_auth_disable             - Disable PineAPE auth passthrough
```

The Pager runs hostapd with a **global** control socket (`-g /var/run/hostapd/global`) plus per-BSS sockets (`/var/run/hostapd/wlan0mgmt`, `wlan0open`, `wlan0wpa`). Use `-p <dir> -i <iface>` to talk to a per-BSS socket.

### 3.3 How to toggle Layer B

```sh
# Get state
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_state
# -> ENABLED   or   DISABLED

# Toggle the PineAP-Enterprise sub-feature
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_disable

# Auth passthrough sub-toggle
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_disable

# Main PineAP/Mimic (separate feature)
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_state
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_disable
```

These run instantly with no service restart. The BSS keeps broadcasting through all of them.

### 3.4 What this does NOT do

It does **not** stop the BSS. The SSID, beacon, channel, encryption, and associated clients are all unaffected.

---

## 4. Why the HTTP API and UCI look like they work but don't

### 4.1 The HTTP API

The Go backend exposes:

```
GET   /api/pineap/hostapd/get_config
PUT   /api/pineap/hostapd/set_config       <- must be PUT, not POST
```

`set_config` accepts the full config object:

```sh
curl --unix-socket /tmp/api.sock -X PUT \
  -H 'Content-Type: application/json' \
  -d '{
    "mgmt_ifaces": ["wlan0mgmt"],
    "wpa_ifaces":  ["wlan0wpa"],
    "pineap_disabled":   true,
    "pineape_disabled":  false,
    "pineape_auth_pass": true
  }' \
  http://localhost/api/pineap/hostapd/set_config
# -> {"success": true}
```

`get_config` immediately reflects the new UCI state. **However**, hostapd does not pick up the change on this firmware - the BSS keeps broadcasting with the old config and the iPhone still sees `IceCreamBase`. There is no signal from the Go process to hostapd to reload. Treat this endpoint as UCI-write-only on the Pager.

To make the change take effect, you must additionally run one of:
- `WIFI_WPA_AP_DISABLE wlan0wpa` (Layer A)
- `hostapd_cli ... pineape_disable` (Layer B)
- `wifi reload` after editing UCI directly

### 4.2 Direct UCI edits

Editing `/etc/config/pineapd` `@hostapd[0]` options and committing has the same limitation as the HTTP API: it changes persistent config but does not push the change to the running hostapd process. You also need `wifi reload` (or restarting `pineapd` / `hostapd`) to make it take effect.

Editing `/etc/config/wireless` and running `wifi reload` **does** take effect, because that reloads hostapd config from scratch. This is why the raw-UCI method in section 2.2 actually works.

---

## 5. How to verify state

Do not trust the API or `pineape_state` alone. Verify all three:

### 5.1 Layer A is up - the BSS is alive

```sh
# Is the BSS registered in hostapd?
hostapd_cli -p /var/run/hostapd -i wlan0wpa status | grep -E "ssid|state="
# state=ENABLED
# bssid[0]=... ssid[0]=qwerty
# bssid[1]=... ssid[1]=pager-open
# bssid[2]=... ssid[2]=IceCreamBase     <-- present
# num_sta[2]=1                           <-- and a client is connected

# Is the interface up in the kernel?
iw dev wlan0wpa info
# Interface wlan0wpa
#     ifindex 25
#     addr 12:13:37:ac:af:24
#     ssid IceCreamBase
#     type AP
#     channel 1 (2412 MHz), width: 20 MHz, center1: 2412 MHz
#     txpower 23.00 dBm

# Is it actually broadcasting? (scan from a monitor interface)
iw dev wlan0mon scan | grep -B1 -A4 IceCreamBase
```

After `WIFI_WPA_AP_DISABLE wlan0wpa`, all three should show the BSS gone: `hostapd_cli status` no longer lists `ssid[2]`, `iw dev` says `command failed: No such device`, and the monitor scan finds nothing.

### 5.2 Layer B is what you want

```sh
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_state       # PineAP-Enterprise sub-feature
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_state  # auth passthrough sub-toggle
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_state        # main PineAP/Mimic
```

These return `ENABLED` / `DISABLED` directly. They report the in-process flag, not UCI.

### 5.3 UCI persistent state

```sh
uci show wireless.wlan0wpa                    # Layer A persistent state
uci show pineapd.@hostapd[0]                  # Layer B persistent state
```

---

## 6. End-to-end examples

### 6.1 "I want to disable Evil WPA AP right now"

```sh
# Pick one:
WIFI_WPA_AP_DISABLE wlan0wpa

# or equivalently:
uci set wireless.wlan0wpa.disabled='1'
uci commit wireless
wifi reload

# Verify:
hostapd_cli -p /var/run/hostapd -i wlan0wpa status | grep -E "ssid|state="
# should show only qwerty and pager-open
```

### 6.2 "I want to enable Evil WPA AP with a specific SSID and PSK"

```sh
WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222

# Verify:
iw dev wlan0wpa info | grep -E "ssid|type|channel"
# ssid IceCreamBase
# type AP
# channel 1 (2412 MHz)
```

### 6.3 "I want to keep the BSS but turn off PineAP-Enterprise behavior"

```sh
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_disable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_disable

# Verify:
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_state
# DISABLED
```

BSS keeps broadcasting, iPhone keeps seeing `IceCreamBase`, but the PineAP-Enterprise behavior is off.

### 6.4 "I want to fully nuke the Evil WPA config"

```sh
WIFI_WPA_AP_CLEAR wlan0wpa
uci commit wireless
wifi reload
```

This removes the `wireless.wlan0wpa` section entirely. To restore it, re-run `WIFI_WPA_AP` with the full config (the command recreates the section).

### 6.5 "I want to script this from a payload"

```sh
#!/bin/sh
# payload: disable Evil WPA
. /lib/hak5/commands.sh
HAK5_API_VERBOSE=1
HAK5_API_POST "pineap/hostapd/set_config" \
  '{"mgmt_ifaces":["wlan0mgmt"],"wpa_ifaces":["wlan0wpa"],"pineap_disabled":true,"pineape_disabled":true,"pineape_auth_pass":false}'
# Note: this only writes UCI; follow with a real disable:
WIFI_WPA_AP_DISABLE wlan0wpa
```

---

## 7. Common pitfalls

1. **POST vs PUT on `/api/pineap/hostapd/set_config`.** POST returns `405 Method Not Allowed`. You must use PUT with `Content-Type: application/json`.
2. **API writes UCI but doesn't reload hostapd.** Even on success (`{"success": true}`), the BSS keeps broadcasting. The API is a config write, not a live control plane.
3. **`pineape_state DISABLED` does not mean the AP is off.** It only means the PineAP-Enterprise sub-feature is off. The BSS is still up.
4. **`pineap_state` and `pineape_state` are different things.** `pineap` = main PineAP/Mimic. `pineape` = PineAP-Enterprise sub-feature. Don't conflate them.
5. **`wifi reload` re-creates the BSS even if `wireless.wlan0wpa.disabled='1'`.** That is the intended behavior - reloading wifi applies the current UCI state. If you want the BSS gone, set `disabled='1'` *and* run `wifi reload`.
6. **The mgmt AP and the open AP are on the same radio.** Toggling `wlan0wpa` does not affect `wlan0mgmt` or `wlan0open`. Be aware if you're scripting "disable all APs".
7. **Monitor interfaces (`wlan0mon`, `wlan1mon`, `wlan2mon`) are not APs.** `iw dev wlan0mon scan` will not see APs from the same radio while a BSS is up unless you specifically scan; use it for cross-radio verification only.

---

## 8. Targeted client tracking - WiFi-Client-Tracker-Targeted payload

**Payload:** `/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh`
**Current version:** 16.0
**Author:** Jeff Benson (erg0Pr0xy) - Skinny Research & Development

This is a small payload purpose-built around Layer A. It assumes the Evil WPA AP (`wlan0wpa`, SSID `IceCreamBase`) is already up and gives you a real-time view of every client that associates, then lets you pick one to track for CONNECT / DISCONNECT events with signal strength.

### 8.1 What it does

1. Sanity-checks that `wlan0wpa` is up. If not, prints the `WIFI_WPA_AP` command you need to run and exits.
2. **With a TARGET MAC passed as `$1`**: enters the tracking loop immediately, printing state changes for that MAC only.
3. **Without a TARGET MAC**: runs a discovery scan (default 20s, override with `$2`), printing every new MAC + first-seen signal. After the scan window, prompts the user to pick a target via the Pager's `LIST_PICKER` modal (or a terminal `select` menu in TTY context). Then tracks the chosen MAC.
4. Tracks forever in a `while true; do ... sleep 1; done` loop, printing `[timestamp] CONNECT/DISCONNECT MAC: ... Signal: NN dBm` on every state change.
5. **Does NOT bring up or tear down the AP.** AP lifecycle is the user's responsibility (see sections 2 and 8). The trap on `SIGINT`/`SIGTERM` just prints a "Tracking stopped" notice and exits.

### 8.2 Launch modes

| Launch context | How to launch | What you see |
|---|---|---|
| Terminal, target known | `payload.sh aa:bb:cc:dd:ee:ff` | Direct tracking, no scan |
| Terminal, scan + pick (TTY) | `payload.sh` | 20s scan with live `[timestamp] NEW CLIENT` lines, then bash `select` menu in your terminal |
| Terminal, scan + pick (no TTY) | `payload.sh </dev/null` | 20s scan, then a `LIST_PICKER` rejection followed by a "re-run with a MAC" error message |
| Pager UI (launched as a payload) | Payloads -> user -> Skinny-Tools -> WiFi-Client-Tracker-Targeted -> Run | 20s scan appearing on the Pager's payload log screen, then a `LIST_PICKER` modal; tap the MAC to track |

### 8.3 The LIST_PICKER pattern for interactive scripts

The Hak5-patched hak5cmd binary exposes a `LIST_PICKER` command that opens a modal list picker on the Pager's display and returns the user's selection. The basic pattern is:

```sh
SELECTED=$(LIST_PICKER "Title" "option1" "option2" "option3" "defaultIndex")
```

where `defaultIndex` is a string ("0", "1", "2"...) naming the option that should be pre-selected. The command blocks until the user picks, and the chosen option string is printed to stdout.

Key behaviors (verified against this firmware):

- **No payload context (e.g. raw SSH):** the picker is **rejected** - the command returns immediately with empty stdout, exit code 0. No error, no exception. Always check for empty stdout and have a fallback.
- **Active payload context (Pager UI):** the picker opens as a modal on the Pager's display. User dismisses -> `rejected: true, selected: ""` in the underlying API response (still empty stdout from the script's POV).
- **Direct API** (for debugging): `POST /api/payload/interact/list_picker` with `{"title":"...","options":[...],"default":"0"}` returns `{"selected":"...","rejected":false,"error":""}`. Note the `default` field expects a string, not an int.

Robust payload-friendly pattern used in the tracker:

```sh
# Try Pager LIST_PICKER first (works in payload context)
SELECTED=$(LIST_PICKER "Track which client?" "Rescan..." "${FOUND[@]}" "0" 2>/dev/null)

# Fall back to terminal select if TTY is available (interactive SSH)
if [ -z "$SELECTED" ] || [ "$SELECTED" = "Rescan..." ]; then
    if tty -s 2>/dev/null; then
        PS3="Enter the number of the target: "
        select CHOSEN in "${FOUND[@]}"; do
            [ -n "$CHOSEN" ] && { SELECTED="$CHOSEN"; break; }
        done
    else
        # No picker, no TTY: print the list and tell the user how to re-run
        echo "Re-run with: $0 ${FOUND[0]}"
        exit 1
    fi
fi
```

This makes the same script usable from both the Pager UI (where `LIST_PICKER` is the only viable prompt) and an interactive terminal SSH session (where bash `select` is the right tool). The "Rescan..." first option gives the user an out if the scan was too short.

### 8.4 Output mirroring (LOG + printf)

The `LOG` hak5cmd (see `HAK5_CUSTOM_BINARIES.md` section 1) sends data to the **currently running payload log** on the Pager's screen. When run from a payload launched from the Pager UI, the Go backend has a payload context and the LOG call renders on screen. When the same script is run from a raw SSH terminal, there's no payload context and `LOG` is a silent no-op.

To make a script work in both contexts, the tracker uses an `emit()` helper that fans output out to both:

```sh
emit() {
    local first="$1"
    case "$first" in
        red|green|yellow|blue|magenta|cyan|white)
            shift
            LOG "$first" "$*"
            printf '%s\n' "$*"
            ;;
        *)
            LOG "$*"
            printf '%s\n' "$*"
            ;;
    esac
}

# Usage
emit green "[$(ts)] CONNECT    MAC: $TARGET  Signal: $SIG dBm"
emit red   "[$(ts)] DISCONNECT MAC: $TARGET"
emit yellow "================================================="
```

`emit "msg"` (no color) and `emit red "msg"` (with color) are the two forms. Every other `printf`/`echo` in the script that should reach both surfaces is routed through `emit`.

### 8.5 Lessons baked into the payload

These are the specific bugs the payload was rewritten to avoid. If you adapt it, do not regress them:

1. **The cleanup trap must not tear down the AP.** Early versions had `trap cleanup SIGINT SIGTERM` where `cleanup` called `WIFI_WPA_AP_DISABLE wlan0wpa`. Combined with the non-interactive `select` menu (which exits immediately when stdin is closed in a payload context), the script would get SIGTERM, the trap would fire, and the Evil WPA AP would vanish mid-handshake - causing the very "device trying to connect errors out" symptom the payload is meant to diagnose. AP lifecycle is now the user's job, not the script's.
2. **`LOG` is silent from a terminal.** All status messages were originally `LOG red/green/yellow "..."`, which print nothing when there's no active payload. The terminal user sees only the raw `echo -ne "Scanning..."` countdown and the script's `exit 1`, with no idea why. Fix: every status message goes through `emit` so it hits both stdout and the payload log.
3. **Busybox `printf` misinterprets format strings starting with `--`.** `printf '-----'` returns "invalid option" because the busybox `printf` builtin sees the leading `--` and tries to parse it as the end-of-options marker. Fix: for literal separator/banner lines, use `say() { printf '%s\n' "$*"; }` (a format-string wrapper) or use `printf -- '...'`.
4. **`bash `select` needs a TTY.** In a payload context stdin is not a terminal, so `select` reads EOF and exits with `$?` set, even if the user actually wanted to make a choice. The script falls through to the tracking loop with `CHOSEN_TARGET` empty. Use `LIST_PICKER` for the Pager, and only use `select` in a `tty -s` branch.
5. **`/api/payload/interact/list_picker` `default` is a string, not an int.** Trivial but easy to miss - the Go struct has `Default string` so `"0"` works, `0` does not.

### 8.6 Putting it all together

The complete workflow is:

```sh
# 1. Bring the AP up
WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222

# 2. (Optional) Confirm the BSS is broadcasting
iw dev wlan0wpa info | grep -E "ssid|type|channel|txpower"
hostapd_cli -p /var/run/hostapd -i wlan0wpa status | grep -E "ssid\[2\]|state="

# 3. Track
#    Terminal with known target:
payload.sh 76:da:9f:b5:4e:e3
#    Or Pager UI (no args): scan, then pick from modal

# 4. (When done) leave the AP up for other tools, or:
WIFI_WPA_AP_DISABLE wlan0wpa
```

The tracker payload is the practical layer on top of the two-layer architecture in sections 1-3: it assumes Layer A is up and acts purely as a viewer / selector, never as a configurator. That separation is what makes it safe to run in the background while other tooling (deauth, handshakes, etc.) operates on the same BSS.

---

## 9. Quick reference card

```sh
# === Layer A: the BSS itself ===

# Enable / disable via hak5cmd
WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222
WIFI_WPA_AP_DISABLE wlan0wpa
WIFI_WPA_AP_CLEAR  wlan0wpa
WIFI_WPA_AP_HIDE   wlan0wpa

# Enable / disable via UCI
uci set wireless.wlan0wpa.disabled='0' ; uci commit wireless ; wifi reload
uci set wireless.wlan0wpa.disabled='1' ; uci commit wireless ; wifi reload

# Verify Layer A
hostapd_cli -p /var/run/hostapd -i wlan0wpa status | grep -E "ssid|state="
iw dev wlan0wpa info | grep -E "ssid|type|channel|txpower"
iw dev wlan0mon scan | grep -B1 -A4 IceCreamBase

# === Layer B: PineAP-Enterprise sub-feature ===

hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_state
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_disable

hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_state
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineape_auth_disable

# === Main PineAP/Mimic (separate feature) ===

hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_state
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_enable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_disable
hostapd_cli -p /var/run/hostapd -i wlan0wpa pineap_reload

# === HTTP API (writes UCI only; does not live-reload hostapd) ===

# Get
curl --unix-socket /tmp/api.sock http://localhost/api/pineap/hostapd/get_config

# Set (PUT, full body)
curl --unix-socket /tmp/api.sock -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"mgmt_ifaces":["wlan0mgmt"],"wpa_ifaces":["wlan0wpa"],"pineap_disabled":true,"pineape_disabled":true,"pineape_auth_pass":true}' \
  http://localhost/api/pineap/hostapd/set_config

# === Targeted client tracking (see section 8) ===

# Track a specific MAC (terminal)
/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh aa:bb:cc:dd:ee:ff

# Scan + pick (Pager UI launch, or interactive terminal)
/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh

# Watch all clients / signals in real time (terminal)
while true; do
  iw dev wlan0wpa station dump | awk '/^Station/{mac=$2} /signal:[ \t]+-/{gsub(/[^0-9-]/,"",$2); printf "  %s  %s dBm\n", mac, $2}'
  sleep 1
done

# Confirm a station is on IceCreamBase (not just on the radio)
iw dev wlan0wpa station dump | grep "^Station" | wc -l   # count
iw dev wlan0wpa station dump | grep -B1 -A6 IceCreamBase # via monitor scan
```
