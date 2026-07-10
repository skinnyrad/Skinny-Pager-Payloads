# WiFi-Client-Tracker-Targeted

Real-time targeted client proximity tracker for the Hak5 WiFi Pineapple Pager's Evil WPA AP. Scans for clients associating with `wlan0wpa` (SSID `IceCreamBase`), lets you pick one from a list, then logs `CONNECT` / `DISCONNECT` events with live signal strength.

## Features

- **Targeted tracking.** Pick one client MAC and watch its `CONNECT` / `DISCONNECT` events with signal strength in dBm.
- **Discovery + selection.** If you don't know the MAC, scan for a configurable window and pick from a list.
- **Three launch modes.** Same script works from a Pager payload, an interactive SSH terminal, and a piped / non-TTY SSH session.
- **Mirror output to Pager screen and stdout.** Uses an `emit()` helper that calls `LOG` (payload log on the Pager UI) and `printf` (terminal) at the same time, so output is visible wherever you run it from.
- **Does not touch the AP.** Leaves `wlan0wpa` up across the entire run. The trap on Ctrl-C just prints a notice; you control the AP lifecycle with `WIFI_WPA_AP` / `WIFI_WPA_AP_DISABLE`.

## Requirements

- Hak5 WiFi Pineapple Pager with the Evil WPA AP feature
- The AP `wlan0wpa` brought up before running the script:
  ```sh
  WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222
  ```
- For Pager-screen launch: launched from the Pager UI as a payload (so the `LIST_PICKER` modal has a payload context to render in)
- For terminal launch: `bash` (the script uses `#!/bin/bash`)

## Installation

The payload is shipped as a single executable shell script. Drop it into a user payload directory on the Pager:

```sh
scp payload.sh root@172.16.52.1:/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh
ssh root@172.16.52.1 'chmod +x /mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh'
```

To verify:

```sh
ssh root@172.16.52.1 'ls -la /mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh'
# -rwxr-xr-x 1 root root 4189 ... payload.sh
```

## Usage

```sh
payload.sh [TARGET_MAC] [SCAN_SECONDS]
```

| Argument | Default | Description |
|---|---|---|
| `TARGET_MAC` | _(none)_ | If provided, skip the scan and track this MAC directly. Format `aa:bb:cc:dd:ee:ff`. |
| `SCAN_SECONDS` | `20` | When no `TARGET_MAC` is given, how long to scan for clients before showing the picker. |

### Launch mode 1 - terminal, target known

```sh
/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh 76:da:9f:b5:4e:e3
```

Output:
```
=================================================
  TARGET PROXIMITY TRACKER  (wlan0wpa / IceCreamBase)
  Started: 2026-07-10 01:42:35
=================================================
Interface:    wlan0wpa
Target:       76:da:9f:b5:4e:e3 (passed as arg)
Scan window:  skipped (target given)
-------------------------------------------------
[2026-07-10 01:42:35] AP is up.
-------------------------------------------------
[2026-07-10 01:42:38] CONNECT    MAC: 76:da:9f:b5:4e:e3  Signal: -30 dBm
[2026-07-10 01:43:12] DISCONNECT MAC: 76:da:9f:b5:4e:e3
[2026-07-10 01:43:20] CONNECT    MAC: 76:da:9f:b5:4e:e3  Signal: -67 dBm
```

### Launch mode 2 - terminal, scan and pick (interactive TTY)

```sh
/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh
```

Runs a 20-second scan printing every new client as it associates, then shows a bash `select` menu in your terminal:

```
[2026-07-10 01:41:23] NEW CLIENT  MAC: 68:13:f3:3b:3c:57  Signal: -50 dBm
  Scanning... (15s remaining, 1 client(s) found)
...
Found 1 client(s). Select a target to track:
1) 68:13:f3:3b:3c:57
Enter the number of the target: 1
[2026-07-10 01:41:44] Target selected: 68:13:f3:3b:3c:57
[2026-07-10 01:41:46] CONNECT    MAC: 68:13:f3:3b:3c:57  Signal: -54 dBm
```

### Launch mode 3 - Pager UI (launched as a payload)

From the Pager: **Payloads -> user -> Skinny-Tools -> WiFi-Client-Tracker-Targeted -> Run**

The 20-second scan output appears on the Pager's payload log screen, then a `LIST_PICKER` modal lets you tap the client you want to track. Output (CONNECT / DISCONNECT events) appears in real time on the Pager screen.

### Tuning the scan window

For a longer or shorter scan:

```sh
# 45-second scan before showing the picker
/mmc/root/payloads/user/Skinny-Tools/WiFi-Client-Tracker-Targeted/payload.sh "" 45
```

## Output

Every line is timestamped. The format is:

```
[YYYY-MM-DD HH:MM:SS] <EVENT>  MAC: <aa:bb:cc:dd:ee:ff>  [Signal: <NN> dBm]
```

| Color | Event | Meaning |
|---|---|---|
| green | `AP is up.` | Sanity check passed; the script is now tracking |
| green | `NEW CLIENT MAC: ... Signal: N dBm` | A previously unseen client just associated (discovery mode only) |
| green | `CONNECT MAC: ... Signal: N dBm` | The tracked client just associated |
| red | `DISCONNECT MAC: ...` | The tracked client just disassociated |
| red | `ERROR: wlan0wpa is DOWN.` | AP is not up; script exits with a hint to run `WIFI_WPA_AP` |
| red | `No clients found in Ns. Exiting.` | Discovery mode timed out with no clients; script exits cleanly |
| yellow | `Tracking stopped. AP left running on wlan0wpa.` | Ctrl-C or SIGTERM; the AP is **not** torn down |

## How the picker works

The script tries three interactive paths in order:

1. **`LIST_PICKER`** (Pager screen only). Calls the Hak5 hak5cmd that opens a modal list picker. Returns the chosen option string. Empty output if there's no active payload (raw SSH) or the user dismisses the modal.
2. **Bash `select`** (interactive TTY). Falls back to a numbered `select` menu if stdin is a terminal.
3. **Error + helpful re-run command** (no TTY, no payload). Prints the list of discovered MACs and tells the user how to re-run with one as an argument.

The first option in the picker is always `Rescan...` so the user can keep the scan going if the window was too short.

## Stopping

Ctrl-C. The trap handler just prints a notice and exits. **The AP is not torn down** - you control that with `WIFI_WPA_AP_DISABLE wlan0wpa` when you are done with all your Evil WPA tooling.

## Troubleshooting

### Nothing appears on the Pager screen
- The script must be launched **as a payload from the Pager UI** for `LOG` calls to reach the Pager's display.
- When run from a raw SSH terminal, `LOG` is a silent no-op. `printf` to stdout still works.

### "ERROR: wlan0wpa is DOWN"
The script refuses to run if the Evil WPA AP isn't up. Bring it up first:
```sh
WIFI_WPA_AP wlan0wpa IceCreamBase psk2 22222222
```

### "No clients found in 20s"
- The target device might not be in range, might have an invalid PSK, or might be configured not to auto-connect to `IceCreamBase`.
- Check that the AP is actually broadcasting:
  ```sh
  iw dev wlan0wpa info
  hostapd_cli -p /var/run/hostapd -i wlan0wpa status | grep -E "ssid\[2\]|state="
  ```
- Try scanning with a longer window: `payload.sh "" 60`.
- If you already know the MAC, skip the scan: `payload.sh aa:bb:cc:dd:ee:ff`.

### Script exits immediately in a payload
- You probably triggered the cleanup trap (Ctrl-C on the Pager screen). The script does **not** tear down the AP, so re-running it is safe.

### `printf: --: invalid option` errors
Should not happen with v15.2+. If you see them on an older version, update. The script uses an `emit()` helper that wraps `printf '%s\n'` to avoid BusyBox's misinterpretation of format strings starting with `--`.

## Related

- `knowledge/PINEAP_EVIL_WPA.md` - full reference on the Evil WPA AP control layers (Layer A wifi-iface, Layer B `pineape_*` sub-feature flag, why the HTTP API is a no-op). Section 8 of that doc is the original writeup of this payload.
- `knowledge/HAK5_CUSTOM_BINARIES.md` - reference for all `hak5cmd` binaries, including `WIFI_WPA_AP*` and `LOG`.
- `knowledge/PAGER_API_AND_RECON.md` - HTTP API and `_pineap` CLI references.

## Version history

| Version | Notes |
|---|---|
| 1 | Initial version - direct tracking with target arg only |
| 14.2 | Added discovery + `select` menu, no-arg mode. Bugs: silent `LOG` from terminal, `select` didn't work in payload context, cleanup trap tore down the AP. |
| 15.0 | Removed menu, added `printf` everywhere, removed `WIFI_WPA_AP_DISABLE` from trap. |
| 15.1 | Fixed `printf: --: invalid option` BusyBox bug. |
| 15.2 | Added `say()` helper to wrap literal `--` strings in `%s\n`. |
| 15.3 | Added `emit()` helper that mirrors every line to `LOG` + stdout. |
| 16.0 | Reintroduced discovery + selection with `LIST_PICKER` (Pager) -> `select` (TTY) -> error (no TTY) fallback chain. |

## Author

Jeff Benson (erg0Pr0xy) - Skinny Research & Development
