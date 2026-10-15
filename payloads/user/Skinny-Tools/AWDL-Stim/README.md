# AWDL Stim

**Version:** 2.3
**Author:** Skinny
**Category:** user / Skinny-Tools

---

## Bottom line up front (TSCM: why this beats Wi-Fi probes for iPhone hunting)

Infrastructure **probe requests** are a bad way to hunt modern iPhones: the phone
only probes for SSIDs it already remembers, it throttles probes heavily when it is
idle or locked, and iOS blanks/truncates the Preferred Network List so the probes
carry almost no identifying information. An idle phone in a pocket is often
**silent** on the probe channel.

**AWDL is the opposite.** It is a *scheduled presence protocol*, not a
user-activity-driven one. To remain reachable for AirDrop / AirPlay / Handoff /
Continuity / Instant Hotspot, an iPhone continuously (duty-cycled, several times a
second) broadcasts AWDL presence frames that carry its AWDL MAC in the clear — no
known SSID required, no user interaction required, and *independent of lock/screen
state*. That makes AWDL a **near-continuous** "is there a powered Apple device here,
and how close is it (RSSI)" sensor, where probing is intermittent at best.

**Bottom line:** for *detecting and ranging* an iPhone, AWDL presence is a more
reliable, always-on signal than Wi-Fi probing; probing is a weak fallback. AWDL is
weaker at *naming* the device (that needs mDNS/Bonjour enrichment, see caveats).

---

## What this payload is

A four-part "AWDL rig" that **stimulates and observes** nearby Apple AWDL activity,
then logs and (optionally) alerts on it:

| File | Role |
|---|---|
| `owl` (mipsel binary) | A genuine **AWDL peer**. Joins/leads the AWDL cluster, sends PSF/MIF presence, logs peers + RSSI to `/tmp/owl.log`. |
| `avahi-daemon` | Advertises **fake AirPlay 2 / AirPlay / companion-link service records** over `awdl0` — the "lure" that draws iPhones to respond. |
| `awdl_log.py` | Passive observer (scapy). Correlates MAC ↔ IPv6 ↔ RSSI ↔ mDNS/Bonjour names → `/root/loot/awdl/YYYYMMDD-awdl.log`. |
| `awdl_alert.sh` | Tails the observer log; for each new device raises a timestamped Pager `ALERT` (optional) and mirrors to `/root/loot/awdl-alerts/`. |
| `awdl_supervisor.sh` | Keeps the four components alive (restarts any that die). |
| `awdl_wake.sh` | Start/stop wrapper that launches the supervisor. |
| `bonjour_awdl.py` | Standalone recursive DNS-SD (Bonjour) enumerator over an AWDL interface (manual/advanced use). |
| `payload.sh` | Menu entry point: pick radio, choose alerts on/off, start; run again to stop. |

---

## This is Wi-Fi **Direct (peer-to-peer)** — NOT infrastructure mode

AWDL (**Apple Wireless Direct Link**) is Apple's peer-to-peer Wi-Fi protocol — an
Apple, ad-hoc-style "Wi-Fi Direct"-class transport. It is **not** the normal
infrastructure (AP/client) mode and **not** Wi-Fi scanning:

- It runs on a **dedicated AWDL interface with its own randomized MAC**, separate
  from the phone's infrastructure (STA) MAC and from Bluetooth.
- It is **completely independent of any access point or SSID.** The payload does
  **not** connect to, associate with, or depend on any infrastructure network. It
  needs **no known SSIDs** and no PNL.
- An iPhone keeps AWDL running by **time-slicing its own radio** — the same chip
  alternates between infrastructure traffic and the AWDL peer schedule. So a phone
  that is happily connected to some AP still emits AWDL, and an idle/locked phone
  still emits AWDL, as long as its Wi-Fi radio is on.

That is the key TSCM distinction: you are not waiting for the phone to *ask* for a
network; you are listening on a channel where Apple devices *must* periodically
announce themselves to stay discoverable to each other.

---

## Clusters & frequency hopping

AWDL devices organise into **clusters** (peer groups) that share one common
**time grid and channel schedule**:

- Time is sliced into **Availability Windows (AWs)** — fixed, short windows
  (on the order of 16 ms) grouped into a repeating sequence. Between windows a
  node may sleep; it wakes for its scheduled windows to transmit/receive.
- **Social channels:** AWDL uses a small set of dedicated channels — commonly
  **channel 6 (2.4 GHz)** plus **channels 44 and 149 (5 GHz)**. These are the
  "meeting places" where Apple devices look for each other.
- **Frequency hopping:** a cluster does **not** stay parked on one channel. It
  follows a **channel sequence** defined by the cluster's master, hopping between
  the social channels on the shared schedule. All nodes in the cluster hop
  **together**, so they stay in contact. This is entirely different from
  infrastructure mode, where the client just sits on the AP's fixed channel.
- A device is only discoverable while it is aligned to a cluster's schedule. If no
  cluster exists, a device either **becomes the master** or **follows** one it hears.

Because everyone hops on the same grid, a listener that participates in the
schedule sees the whole cluster — which is exactly what `owl` does.

---

## Master election, synchronization, and hopping

AWDL is master-driven, and the three mechanisms below are one loop:

1. **Presence/announcement.** Nodes broadcast presence frames — **PSF** (Presence
   Synchronization Frame) and **MIF** (Master Indication Frame). These carry the
   sender's AWDL MAC, its master metric, and its sync parameters.
2. **Master election.** Every node advertises a **master rank** (primarily a link
   quality/metric — e.g. based on the best peer RSSI — plus a counter). The node
   with the strongest rank becomes **master**; the others become **followers**.
   Ties are broken by rank parameters, and the election is re-run continuously as
   nodes come and go.
3. **Synchronization & hopping.** The **master dictates the schedule**: it sends
   **synchronization frames** that define the timing of the availability windows
   and the **channel sequence**. Followers **align** their windows and **hop** to
   the master's channel at the master's times, so the whole cluster transmits on the
   same channel at the same moment and then hops together.

`owl` plays in this game deliberately: by emitting PSF/MIF it either **joins an
existing cluster** or **elects itself master**, which forces nearby iPhones onto its
schedule — and while they are aligned, they are audible and raisable.

---

## How this payload maximizes iPhone "chatter" (stimulation)

AWDL devices only reveal themselves while they are part of a synchronized cluster.
The payload works by **making sure a cluster exists, and making itself the most
attractive thing to talk to:**

- **`owl` provides a live AWDL peer / master.** It advertises presence so a cluster
  is always present on the social channel. Nearby iPhones must sync to it (and thus
  broadcast PSF/MIF + hop with it) to stay reachable — turning passive, quiet phones
  into responding, chatty ones.
- **`avahi` presents an AirPlay 2 / AirPlay / companion-link lure** on `awdl0`.
  An AirPlay-capable iPhone that sees a nearby receiver tends to resolve and answer
  (mDNS queries/responses), which adds *data-plane* traffic and, when it answers,
  exposes Bonjour names / service types / TXT records.
- **Channel 6 by default** (the 2.4 GHz social channel) — the most universally
  supported meeting point, so the widest set of devices can join.
- **Supervised, always-on rig.** `awdl_supervisor.sh` restarts any dropped component
  so the lure/presence never lapses — continuity is what keeps phones chatting.
- **Passive capture, zero cooperation from the target.** The observer just listens
  to the PSF/MIF + neighbor table + mDNS that the stimulation produces.

Net effect: instead of waiting for an occasional probe, the payload keeps a cluster
alive and a lure on the air so idle/locked iPhones keep surfacing.

---

## Usage

Launch **Payloads → Skinny-Tools → AWDL Stim**. It asks:

1. **Which radio?** External USB radio (default, keeps the Pager's own phy0 Wi-Fi
   untouched) or internal radio.
2. **Do you want alerts?** Yes = pop a Pager alert for every new device; No =
   log only.

**Run it again to STOP.**

### Loot / outputs

| Path | Contents |
|---|---|
| `/root/loot/awdl/YYYYMMDD-awdl.log` | `TS \| NAME \| MAC \| IPv6 \| RSSI \| SERVICES \| TXT` |
| `/root/loot/awdl-alerts/YYYYMMDD-awdl-alerts.log` | Same rows, for rows that raised an alert |
| `/tmp/owl.log` | Raw AWDL peer log (PSF/MIF, `add peer`) |
| `/tmp/awdl_supervisor.log` | Component restart history |
| `/tmp/awdl_log.out`, `/tmp/awdl_alert.out` | Observer / alert stderr+stdout |

### Alert format

```
AWDL - Apple Device
 2026-10-15 16:10:22        <- detection time, to the second

 MAC: 4e:ae:35:c3:4d:9c (R)  <- (R) = randomized / locally-administered
 IPv6: fe80::4cae:35ff:fec3:4d9c
 RSSI: -63 dBm
 Host: <name>                <- shown only when a real Bonjour name was resolved
```

The `Host:` line is **omitted** when no name is available (typical for privacy-MAC
devices until mDNS enrichment succeeds).

---

## Caveats / limitations

- **Randomized AWDL MAC.** Every hit is a locally-administered MAC (`(R)`). It is
  stable within a session (minutes → hours) but rotates over longer horizons and on
  events like reboot/radio changes — so it is good for presence + ranging in the
  moment, not for long-term identity.
- **No name by default.** Name/service attribution requires mDNS/Bonjour capture;
  Apple AWDL is often privacy-addressed, so `Host:` frequently stays empty until
  enrichment is improved (see `awdl_log.py` MAC↔IPv6 mapping).
- **Low Power Mode / battery saver** reduces background continuity → less AWDL
  chatter.
- **Wi-Fi off or Airplane mode** → no AWDL at all.
- The Pager UI can restart under memory pressure; alerts raised during a UI restart
  may fail (`Connection refused`) — the rig keeps running, alert display can lapse.

---

## Implementation notes (maintainers)

- **Do not derive the payload directory from `$0`.** The Pager UI stages
  `payload.sh` as `/tmp/payload-<rand>.sh`, so `dirname $0` resolves to `/tmp`, not
  this folder. Always use the framework variables `$_PAYLOAD_HOME` / `$PAYLOAD_HOME`
  (with a `$0` fallback only for direct CLI runs). This is the fix in v2.2 that made
  UI-launched runs work.
- The **observer** intentionally ignores `owl`'s Arpa name (a random UUID) — it is
  never a usable device name.
- The alert watcher de-dupes by re-logging an active device only every `COOLDOWN`
  seconds (`AWDL_COOLDOWN`, default 15).
