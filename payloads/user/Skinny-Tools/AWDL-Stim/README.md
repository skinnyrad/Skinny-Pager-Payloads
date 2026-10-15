# AWDL Stim

**Version:** 2.3
**Author:** Skinny
**Category:** user / Skinny-Tools

---

## Bottom line up front (TSCM: AWDL as a second, complementary discovery surface)

**Probe-request hunting is not bad, and this does not replace it — ideally you run
both.** Probe hunting is a direct signal whenever a device is actively probing, but
it is user-data-driven: the phone only probes for SSIDs it already remembers, it
throttles probing when idle or locked, and iOS blanks/truncates the Preferred
Network List — so an idle, locked phone can be quiet on the probe channel.

**AWDL is simply a different discovery surface** on the same Wi-Fi radio, and it
often *chatters* more than probing does. Because AirDrop / AirPlay / Handoff /
Continuity / Instant Hotspot need peers to be findable, Apple devices periodically
emit AWDL presence frames that carry an (AWDL) MAC — no known SSID required, no user
interaction required, and independent of lock/screen state.

Two things to be clear about, because they're easy to overstate:

- AWDL is **not constant**. It duty-cycles — it comes and goes — so a device can be
  silent for stretches and then chatter for a while.
- We have **no control** over whether, how often, or when a device speaks. We are
  not making phones talk and we are not "hearing" them; we are watching a **different
  protocol** where they tend to be chattier *when they do*.

**Bottom line:** AWDL adds a second, often chattier place to look for Apple devices
(including idle/locked ones that probing can miss), alongside probe hunting. It is
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
- An iPhone runs AWDL alongside its infrastructure connection by **time-slicing its
  own radio** — the same chip alternates between infrastructure traffic and the AWDL
  peer schedule. So a phone that is connected to an AP, or idle/locked, can still
  emit AWDL — as long as its Wi-Fi radio is on and it takes part in the AWDL
  schedule.

The distinction for TSCM: you are not waiting for the phone to *ask* for a network;
you are observing a channel where Apple devices announce themselves to stay
discoverable to each other.

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
   Ties are broken by rank parameters; the election re-runs as nodes come and go.
3. **Synchronization & hopping.** The **master dictates the schedule**: it sends
   **synchronization frames** that define the timing of the availability windows
   and the **channel sequence**. Followers **align** their windows and **hop** to
   the master's channel at the master's times, so the whole cluster transmits on the
   same channel at the same moment and then hops together.

`owl` takes part in this loop: by emitting PSF/MIF it either **joins an existing
cluster** or (if it wins the election) becomes **master**, which gives nearby iPhones
a schedule they *may* choose to sync to. We don't control that choice — `owl` is just
another node on the channel; when a device is on the schedule, its presence frames
are simply easier to observe.

---

## L2 view: the MAC is always visible — the IPv6 only when they're actively using a service

There are two different things you can learn over AWDL, and they come from two
different places at layer 2:

**1. Presence ("awareness") — MAC + RSSI, always.** A device that is merely aware of
its surroundings still broadcasts AWDL management/sync frames (PSF/MIF) in its
availability windows. These are **broadcast L2 frames**, so any listener on the
social channel reads the source AWDL MAC and its RSSI. No IP is involved and no data
session is needed — this is what `owl` logs.

**2. Reachability — IPv6 link-local, only while a service is in use.** To actually
exchange IP (and therefore to `ping`/`nmap`) the device has to be running IP *over*
the AWDL link. That happens when it is **actively using an AWDL service** (AirDrop,
AirPlay, Handoff, …): it stands up `awdl0` as an IP link and auto-configures an IPv6
**link-local** address.

At L2 the two are tied together by the **EUI-64** rule: the link-local is built
straight from the AWDL MAC — flip the U/L bit and insert `ff:fe` in the middle:

```
AWDL MAC   4e:ae:35:c3:4d:9c
IPv6 LL    fe80::4cae:35ff:fec3:4d9c
```

So we can *derive* the expected `fe80::…` from the MAC we already see in presence.
But deriving it is not the same as reaching it: the address is only **live**
(assigned and answering) when the device has IP up on the AWDL link — i.e. when it is
actively using a service, not merely aware. Until then it is a presence MAC with no
answering address.

**Why "aware" alone isn't enough to ping/scan.** AWDL is time-scheduled: a device
only listens and transmits in its availability windows, and it takes part in the L3
data plane (mDNS, ICMP, TCP/UDP over `awdl0`) as part of an active AWDL session. A
device that is only beaconing presence may never process a unicast IP packet aimed at
its link-local. Once it is engaged in a service it is on-schedule and running IP, so
its `fe80::…` is reachable **on the AWDL link** — `ping6 -I awdl0 fe80::…`, or scan
it — because we share that L2 link.

Two practical consequences:

- **The IPv6 is scoped to the AWDL link.** It is a link-local (`fe80::/64`) on
  `awdl0`; you can reach it only from an interface on that same AWDL link, and only
  while the device is participating. It is not globally routable.
- **Presence proves the device exists; an active session is what makes it
  addressable.** "I see the MAC/RSSI" does **not** mean "I can ping it." You get the
  second only when the iPhone is actually *using* AWDL services.

---

## How this payload stimulates AWDL chatter

AWDL devices are only observable while they take part in a synchronized cluster, and
that participation is under **the device's** control, not ours. What this payload can
do is keep **something present on the AWDL channel to interact with**, so that
whenever an iPhone does engage AWDL it is more likely to be seen:

- **`owl` provides a live AWDL peer.** It advertises presence so a cluster exists on
  the social channel; nearby iPhones that choose to sync have a peer to sync to, and
  while they're on that schedule their own presence frames are easier to catch.
- **`avahi` presents an AirPlay 2 / AirPlay / companion-link lure** on `awdl0`. An
  AirPlay-capable iPhone that notices a nearby receiver may resolve/answer it (mDNS),
  which adds a little data-plane traffic and, when it answers, can expose Bonjour
  names / service types / TXT records.
- **Channel 6 by default** (the 2.4 GHz social channel) — the most universally
  supported meeting point, so the widest set of devices can join.
- **A supervised rig.** `awdl_supervisor.sh` restarts any dropped component so the
  peer/lure stays present. That doesn't make phones talk — it just means *we* aren't
  the reason a session gets missed.
- **Passive capture, zero cooperation from the target.** The observer only listens to
  the PSF/MIF + neighbor table + mDNS that devices happen to emit.

Net effect: alongside probe hunting, the payload keeps an AWDL peer and a lure on the
air so iPhones that use AWDL (including idle/locked ones) are more likely to surface
on this second channel.

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
