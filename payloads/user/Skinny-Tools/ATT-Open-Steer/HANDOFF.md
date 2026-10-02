# ATT-Open-Steer — Handoff / Status Document

**Payload path:** `payloads/user/Skinny-Tools/ATT-Open-Steer/`
**Primary file:** `att-open-steer.py` (~911 lines)
**Launcher:** `payload.sh` (Pager-UI menu)
**Last updated:** 2026-10-02
**Status:** Core objective (pseudonym capture) **PROVEN WORKING**. Open-AP
persistence (iOS "connects then drops") **STILL BROKEN**.

---

## 1. Purpose

Find hidden AT&T iPhones in secure facilities by exploiting the carrier
profiles every AT&T iPhone already has, then turn a found phone into a
persistent, trackable target.

Two distinct capabilities are combined:

1. **Pseudonym capture (identity correlation).**
   An AT&T iPhone carries a **Hotspot 2.0 / Passpoint** carrier profile.
   When it encounters a matching network it performs **EAP-AKA'** and, before
   any real authentication, sends its **decorated carrier NAI** (an IMSI
   pseudonym) as the EAP outer identity to the RADIUS server. We stand up a
   fake Passpoint network with a local RADIUS that stalls the exchange. The
   phone keeps retrying and keeps giving us the **same pseudonym**. This lets
   us **correlate iOS "rotating private" MAC addresses to a single physical
   device** (each SSID gets a different randomized MAC, but the pseudonym is
   stable per SIM/eSIM).

2. **Persistent connection (RSSI tracking).**
   iOS also carries a **managed-OPEN** profile for the SSID `attwifi`. We
   advertise a truly-open `attwifi` BSS so the phone associates for real,
   gets an IP, and becomes pingable / RSSI-trackable. The original design
   also wanted to steer the phone from the Passpoint lure to the open twin
   via **802.11k neighbor reports + 802.11v BSS Transition Management (BTM)**.

The end goal is a hand-off: phone leaks pseudonym on the Passpoint BSS, then
is moved to the open BSS where it stays connected.

---

## 2. Ground-truth facts about the target (learned from the iPhone)

These were confirmed by examining the iPhone's Wi-Fi settings screenshots and
live behavior. **They drive the entire design — do not "simplify" them away.**

| Fact | Consequence |
|---|---|
| `attwifi` is a **Managed Network** with **no lock** = the phone's managed **OPEN** profile | The open twin must be named `attwifi` and must be open. |
| `AT&T Secure Wi-Fi` is a **separate Managed Network** with a lock = the Passpoint/enterprise profile that does EAP-AKA' | The **pseudonym lure must be `AT&T Secure Wi-Fi`**, NOT `attwifi`. |
| An AT&T SIM/eSIM is present (MCC 310 / MNC 280) | EAP-AKA' attempts occur only on the enterprise SSID. |
| iOS uses **per-SSID randomized MACs** (Private Wi-Fi Address = Rotating) | The same phone shows a different MAC on `attwifi` vs `AT&T Secure Wi-Fi`. Only the **pseudonym** ties them together. |
| iOS **silently filters locally-administered BSSIDs** (first octet bit 1 set, e.g. `0a:` / `0e:`) | Our BSSIDs MUST be universally-administered (`00:`). |
| iOS **collapses two same-SSID BSSs** of different security into one entry and prefers the secured one | Do not try to run open-`attwifi` and enterprise-`attwifi` as two same-SSID BSSs. |
| hostapd refuses `hs20=1` on an **open** BSS ("HS 2.0: WPA2-Enterprise/CCMP configuration is required") | Hotspot 2.0 can only live on the WPA2-Enterprise BSS. |
| iOS disconnects Wi-Fi it deems "no internet" | The phone's network MUST have real internet via the Pager's uplink. |

---

## 3. Current architecture (what the code does)

`att-open-steer.py` brings up **two BSSs on the 2.4 GHz radio (phy0)** and
runs a state machine:

### BSS 1 — `AT&T Secure Wi-Fi` (Passpoint lure) on `wlan0wpa`
- SSID: `AT&T Secure Wi-Fi`, WPA2-Enterprise (`WPA-EAP`), `eap_type=aka`,
  `auth_server=127.0.0.1:1812`, secret `testing123`.
- Full Hotspot 2.0 / 802.11u IEs: `interworking=1`, `hs20=1`,
  `roaming_consortium=310410 506F9A`, `nai_realm=…att.net…`,
  `anqp_3gpp_cell_net=310,410`, venue fields, `hs20_oper_friendly_name`, etc.
- `ieee80211k=1`, `bss_transition=1`, `rrm_neighbor_report=1`,
  `time_advertisement=1` (for steering).
- Points at the local `radius-reject.py` which **captures** the outer identity
  and (mode `broken`) replies with a malformed Access-Reject so the phone
  **stalls and keeps retrying** → dense pseudonym capture.

### BSS 2 — `attwifi` (open twin) on `wlan0open`
- SSID: `attwifi`, `encryption=none` (open), the connect/tracking target.
- IE-221 vendor OUIs injected (Cisco/Aruba/Ruckus) via the ATT
  `v28_ie221.py` helper so iOS sees a familiar legacy-hotspot signature.
- Captive portal via `v28_wispr.py` (`apple-success`) + `captive.apple.com`
  DNS override → `172.16.52.1`.

### Shared infrastructure
- **Non-destructive wpad:** the `WPAD-SWAP` engine
  (`payloads/user/utilities/WPAD-SWAP/wpad-swap.sh`) bind-mounts
  `wpad-wolfssl` over `/usr/sbin/{wpad,hostapd,wpa_supplicant}` only while
  active and always restores factory `wpad-basic-mbedtls` on exit. A reboot is
  a universal undo. This is required because Passpoint IEs + the
  `bss_transition`/`set_neighbor` control commands only exist in
  `wpad-wolfssl`.
- **RADIUS / WISPr / IE-221 / DHCP helpers are shared with the ATT payload**
  (`payloads/user/Skinny-Tools/ATT/`). `att-open-steer.py` resolves that dir
  via `ATT_DIR` env or the standard install path — it does **not** duplicate
  the ~1600 lines of helper logic.

### Universal BSSIDs
`set_radio_macs()` sets:
```
wireless.radio0.macaddr_base = 00:13:37:ac:af:24
wireless.radio0.num_global_macaddr = 4
```
This makes hostapd allocate sequential **universally-administered** MACs
(`00:13:37:ac:af:24/25/26/…`) instead of flipping the locally-administered bit
(`0a:`/`0e:`) on secondary BSSs. **Confirmed necessary** — iOS filters LA MACs.

### Internet routing (so the phone doesn't get dropped)
- `snapshot_uplink()` records the uplink (`wlan0cli`) IP/prefix/gateway
  **before** the radio is touched.
- Bringing up the APs shares phy0 with the client-StA uplink and **knocks
  `wlan0cli` off its DHCP lease**. `restore_uplink()` waits, nudges `udhcpc`,
  and falls back to re-applying the snapshotted **static** address.
- `ensure_internet_routing()` adds explicit nft **forward + masquerade** rules
  for the AP bridge (`br-lan`) → uplink. **Reason:** Hak5's fw4 generation
  omits the client-Wi-Fi uplink (`wlan0cli`) from the `wan` zone NAT, so
  downstream clients get an IP but no internet → iOS drops the network.
  Verified: `ping -I 172.16.52.250 8.8.8.8` (a fake br-lan client) succeeds.

### Steering (optional)
- `add_neighbor_for_open()` → `hostapd_cli -i wlan0wpa set_neighbor <mac>
  ssid=<hex> nr=<hex>` populates the 802.11k neighbor DB on the enterprise BSS
  with the open BSS (`00:13:37:ac:af:24`, op-class 81, channel, phy type).
- `send_btm()` → `hostapd_cli -i wlan0wpa bss_tm_req <mac> neighbor=<bssid>
  pref=1 disassoc_timer=N valid_int=30 abridged=1`.
- `deauth_ent()` → `hostapd_cli -i wlan0wpa deauthenticate <mac>`.
- `--steer-mode {btm,deauth,both,off}`; default `btm`.

### Idle-station hold
`inject_hold_station()` patches `ap_max_inactivity=0` into the generated
`/var/run/hostapd-phy0.conf` BSS block and HUP's hostapd. Attempts to stop the
"deauthenticated due to inactivity" drop of the idle captive-portal phone.

### Cleanup
Signal (INT/TERM/HUP) + `atexit` guarded `cleanup()`: kills helper processes,
removes the dnsmasq captive override, tears down the isolate bridge, restores
radio MAC + `/etc/config/wireless`, reloads the firewall, restores **stock**
wpad, restarts pineapd. This is the same safety model as the ATT orchestrator.

### CLI
```
att-open-steer.py [--no-isolate] [--steer-mode btm|deauth|both|off]
                  [--steer-always] [--radius-mode broken|log-only|reject|accept|sweep]
                  [--steer-after N] [--steer-interval N] [--disassoc-timer N]
                  [--max-steer-attempts N] [--loot-dir DIR] [--force]
```
`--isolate` defaults **OFF** (phone on `br-lan` with the Pager's own dnsmasq).
The isolate path (`br-att`, `192.168.99.0/24`) exists but is flaky: subsequent
`wifi reload` re-bridges `wlan0open` back to `br-lan` and the phone then sees
no DHCP and spins forever. **Prefer `--no-isolate`.**

Loot: `/mmc/root/loot/att-open-steer/run-YYYYMMDD-HHMMSS/` containing
`run.log`, `radius.log`, `wispr.log`, `dhcpd.log`.

---

## 4. What is WORKING (proven live on the real Pager + iPhone)

1. **Pseudonym capture — the primary objective. WORKING.**
   Real capture from the iPhone on `AT&T Secure Wi-Fi`:
   ```
   username='2MVvyqMgsU4Czgq8irOcPyz@wlan.mnc280.mcc310.3gppnetwork.org'
   mac=86:72:30:69:49:4A   ap=00-13-37-AC-AF-25:AT&T Secure Wi-Fi
   ```
   - `mcc310/mnc280` = AT&T. The phone treated us as the carrier Passpoint
     network and leaked the carrier NAI.
   - Same pseudonym on every retry → MAC correlation works.
   - `radius-reject.py` mode `broken` produced ~11 RECV/min sustained retries.

2. **Non-destructive wpad coexistence.** `wpad-wolfssl` bind-mount works and
   factory wpad is restored on exit / reboot. Verified repeatedly.

3. **Universal BSSIDs** via `macaddr_base`/`num_global_macaddr`. Verified both
   BSSs can get `00:13:37:ac:af:xx` MACs (though not always stable — see §5).

4. **802.11k/v primitives exist and execute.** `set_neighbor` returns `OK`
   and shows in `show_neighbor`; `bss_tm_req` parses (returns `FAIL` only for
   a non-associated STA, which is expected); `deauthenticate` works.

5. **Internet routing** br-lan → uplink (NAT + forward) verified with a fake
   br-lan client.

6. **Uplink recovery** via DHCP nudge / static re-apply (works, though slow).

---

## 5. What is NOT working / open problems

### 5.1 PRIMARY OPEN PROBLEM — iOS connects to open `attwifi` then drops (~10s)
Observed repeatedly:
```
hostapd: wlan0open: STA <mac> IEEE 802.11: associated (aid 1)
hostapd: wlan0open: STA <mac> IEEE 802.11: disassociated
hostapd: wlan0open: STA <mac> IEEE 802.11: deauthenticated due to inactivity (timer DEAUTH/REMOVE)
```
The phone associates to open `attwifi`, then hostapd deauths it for
**inactivity** ~10s later. Suspected interacting causes:

- **(a) Inactivity deauth.** `inject_hold_station()` adds `ap_max_inactivity=0`
  but a later `wifi reload` **regenerates** `/var/run/hostapd-phy0.conf` and
  the injection is lost. Also `skip_inactivity_poll=1` / `disassoc_low_ack=0`
  did not fully prevent the deauth. Need to (re)inject after every reload, or
  find the correct hostapd option that truly disables the idle timer, or keep
  the phone non-idle by completing the captive flow quickly.
- **(b) BSSID instability across reloads.** The vif→MAC assignment is
  order-dependent. In some runs `wlan0open` (open `attwifi`) landed on a
  **locally-administered** MAC (`0e:` / `0a:`) while `wlan0wpa` got the
  universal one. iOS then ignores/filters the open BSS. `hostapd.sh` **ignores
  the UCI `bssid` for AP mode**; the MAC is derived by `hostapd.uc`. Editing
  the generated conf + HUP does not re-apply BSSID (it is set at vif creation).
- **(c) Possibly incomplete captive-portal completion.** WISPr does respond
  (`/hotspot-detect.html` returns Apple `Success`; A-record override for
  `captive.apple.com` → `172.16.52.1` verified) but the phone may bail before
  finishing the probe because of (a)/(b).

### 5.2 BTM steering rarely fires
`bss_tm_req` returns `FAIL` while the STA is mid-EAP (hostapd can only send to
a known/associated station). The `deauth` fallback "works" but causes iOS to
blacklist the network after repeated deauths. Steering is secondary to fixing
§5.1.

### 5.3 Isolate mode (`--isolate`) is broken
`wifi reload` re-bridges `wlan0open` back to `br-lan`, so the dedicated
`br-att` DHCP server never sees the phone. Use `--no-isolate`. If isolate is
wanted, bridge membership must be re-asserted **after** the radio fully
settles, and the DHCP server must bind the bridge's address only.

### 5.4 Uplink flap is slow
Every AP bring-up drops `wlan0cli`'s DHCP lease; recovery takes ~20–60s via
nudge/static re-apply. If the phone connects during the gap, iOS drops it.

### 5.5 Stale helper processes
Multiple `radius-reject.py` instances can stack (only the first bound to
:1812 receives UDP). Cleanup uses `pkill -f`, which on BusyBox sometimes fails
to match; kill by PID. Consider a robust PID-file approach and an SO_REUSEPORT
guard.

---

## 6. Failed / rejected approaches (do not repeat)

- **Two same-SSID `attwifi` BSSs (one open, one enterprise):** iOS collapses
  them and shows only the secured one. Abandoned.
- **Open `attwifi` + `hs20=1`:** hostapd refuses HS2.0 on an open BSS.
- **`eap_type=ttls` on the lure:** iOS showed a generic username/password
  prompt instead of doing AKA'. Must be `aka`.
- **Pinning BSSID via UCI `wireless.<iface>.bssid` for AP mode:** ignored by
  `hostapd.sh`.
- **Editing `/var/run/hostapd-phy0.conf` bssid + HUP:** BSSID not re-applied;
  `wifi reload` overwrites the file anyway.
- **Assuming `wlan0cli` stays up when APs come up:** it does not; must be
  restored.
- **Assuming fw4 NAT covers the client-Wi-Fi uplink:** it does not (only
  `eth1` in the generated rules); must add rules explicitly.

---

## 7. Environment / how to run

- **Pager:** Hak5 WiFi Pineapple Pager, OpenWrt 24.10.1, ramips/mt76x8,
  mipsel_24kc. SSH `root@172.16.52.1`, password `password` (via `sshpass`).
- **This host:** `sshpass` at `/opt/homebrew/bin/sshpass`; repo at
  `/Users/jeff/Documents/git/Skinny-Pager-Payloads`.
- **Radios:** phy0 = 2.4 GHz built-in (where both BSSs live; shared with the
  `wlan0cli` client uplink). phy1/phy2 = external 5 GHz USB (`wlan1mon`
  monitor). The 5 GHz radios cannot host the 2.4 GHz `attwifi` profile, so
  everything is on phy0.
- **IMPORTANT:** run over **USB-C Ethernet (`br-lan`)** or on-Pager tmux, never
  over Wi-Fi SSH. The orchestrator refuses if `SSH_CONNECTION` routes over a
  Wi-Fi iface unless `ATT_FORCE_WLAN0CLI=1`.
- **Deploy:**
  ```sh
  scp -O payloads/user/Skinny-Tools/ATT-Open-Steer/att-open-steer.py \
      root@172.16.52.1:/mmc/root/payloads/user/Skinny-Tools/ATT-Open-Steer/
  ```
- **Run (headless):**
  ```sh
  cd /mmc/root/payloads/user/Skinny-Tools/ATT-Open-Steer
  setsid sh -c "python3 att-open-steer.py --force --no-isolate --steer-mode both \
      >/tmp/aos.out 2>&1" &
  ```
- **Watch:** `radius.log` for `username=`, `hostapd_cli -i wlan0open all_sta`
  for the phone, `logread | grep hostapd` for deauth reasons.
- **Restore stock:** stop the payload (SIGTERM triggers cleanup), then
  `wpad-swap.sh recover`, clear `radio0.macaddr_base`/`num_global_macaddr`,
  set `wlan0open.ssid=pager-open`, `wlan0wpa.disabled=1`, `wifi reload`.
  A **reboot** is the universal reset.

---

## 8. Recommended next steps (priority order)

1. **Fix §5.1 (open-AP persistence).** Highest value. Options:
   - Re-inject `ap_max_inactivity=0` (and any other idle options) **after
     every `wifi reload`** and verify with `hostapd_cli -i wlan0open get_config`.
   - Investigate the exact hostapd option that disables the DEAUTH/REMOVE
     inactivity timer (candidate: `ap_max_inactivity=0` truly applied, or
     `disassoc_low_ack=0` plus `skip_inactivity_poll=1` plus ensuring the STA
     has traffic). Consider keeping the phone busy by ensuring the captive
     flow completes (fast WISPr response + working DNS/NAT).
   - Consider a **time-split** design: enterprise lure phase first (capture
     pseudonym), then **tear it down and bring up ONLY the open `attwifi`**
     so it is BSS0 and reliably gets the universal MAC, then hold it with a
     clean single-BSS config. This sidesteps the two-BSS BSSID ordering mess.

2. **Pin deterministic universal BSSIDs reliably.** After the time-split or
   single-BSS bring-up, confirm the open BSS always has `00:13:37:...`. If
   ordering still flips, investigate `hostapd.uc` `macaddr_next()` ordering or
   use a dedicated `num_global_macaddr` allocation and accept whichever
   universal MAC is assigned (log it; the neighbor/BTM target is computed at
   runtime anyway).

3. **Make steering meaningful only AFTER the phone is stable on the lure**, or
   drop steering entirely if the time-split works (turning the lure off is a
   stronger "steer" than BTM).

4. **Robust process management** (PID files; avoid stacked RADIUS).

5. **Once stable:** update `online-install.sh`/README to list the payload and
   commit.

---

## 9. Key file map

| File | Role |
|---|---|
| `payloads/user/Skinny-Tools/ATT-Open-Steer/att-open-steer.py` | Orchestrator (this payload) |
| `payloads/user/Skinny-Tools/ATT-Open-Steer/payload.sh` | Pager-UI launcher (stages wolfssl, picks steer mode, runs under engine `run`) |
| `payloads/user/utilities/WPAD-SWAP/wpad-swap.sh` | Non-destructive wpad-wolfssl bind-mount engine |
| `payloads/user/Skinny-Tools/ATT/radius-reject.py` | Fake RADIUS; captures `username=` (pseudonym), mode `broken` stalls |
| `payloads/user/Skinny-Tools/ATT/v28_wispr.py` | WISPr captive portal (`apple-success`) |
| `payloads/user/Skinny-Tools/ATT/v28_ie221.py` | Injects IE-221 OUIs into hostapd conf |
| `payloads/user/Skinny-Tools/ATT/v28_dhcpd.py` | Stdlib DHCP server (isolate mode only) |
| `payloads/user/Skinny-Tools/ATT/v28_isolate.sh` | br-att create/destroy |
| `payloads/user/Skinny-Tools/ATT/v28_run.py` | Sibling ATT orchestrator (reference for conventions) |

---

## 10. One-paragraph summary for a fresh session

The payload stands up a fake AT&T Passpoint network (`AT&T Secure Wi-Fi`) with
a local RADIUS to capture an AT&T iPhone's EAP-AKA' pseudonym (IMSI NAI) — this
**works and is the main win**. It simultaneously stands up an open `attwifi`
BSS (the phone's managed-open profile) as a persistent tracking target. The
open BSS currently works only briefly: iOS associates then hostapd deauths it
for inactivity (~10s), partly because the idle-timer disable gets wiped by
`wifi reload` and partly because BSSID assignment across reloads is unstable
(sometimes landing on a locally-administered MAC iOS filters). Internet routing
(NAT/forward br-lan→uplink) and uplink DHCP recovery are implemented and
verified when the phone is up. Steering via 802.11k neighbor reports + 802.11v
BTM is implemented but rarely lands because the STA is mid-EAP. The most
promising fix is a **time-split**: capture the pseudonym on the enterprise BSS,
then tear it down and run ONLY the open `attwifi` as the primary BSS so it gets
a stable universal MAC and can be held idle reliably.
