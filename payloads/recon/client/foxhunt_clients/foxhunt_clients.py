import os
import sys
import time
import select
import subprocess
from pagerctl import Pager

# --- Pull and Sanitize Hak5 Recon Environment Variables ---
CLIENT_MAC = os.getenv("_RECON_SELECTED_CLIENT_MAC_ADDRESS", "").strip().lower()
BSSID = os.getenv("_RECON_SELECTED_AP_BSSID", "").strip().lower()
CHANNEL_RAW = os.getenv("_RECON_SELECTED_AP_CHANNEL", "").strip()

def stop_ui():
    subprocess.run(["/etc/init.d/pineapplepager", "stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

def start_ui():
    subprocess.run(["/etc/init.d/pineapplepager", "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def start_airodump():
    """Launches backend airodump-ng locked ONLY to the channel to catch all client frames."""
    band = "g"
    try:
        if CHANNEL_RAW and int(CHANNEL_RAW) > 14:
            band = "a"
    except ValueError:
        pass

    print(f"[*] Sniffing Channel: {CHANNEL_RAW} for Client: {CLIENT_MAC}...")

    # OPTIMIZATION: Removed --bssid filter so we capture direct transmissions/probes from the client device
    cmd = ["/usr/sbin/airodump-ng", "-c", CHANNEL_RAW, "--band", band, "--output-format", "csv", "-w", "/tmp/clientpython", "wlan1mon"]
    process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return process

def parse_client_rssi():
    """Parses the Station section of the airodump CSV to extract client signal strength."""
    csv_path = "/tmp/clientpython-01.csv"
    if not os.path.exists(csv_path):
        return "[Waiting...]"

    try:
        with open(csv_path, "r") as f:
            lines = f.readlines()
            
        in_station_section = False
        for line in lines:
            line_lower = line.lower()
            
            if "station mac" in line_lower:
                in_station_section = True
                continue
                
            if in_station_section:
                parts = line_lower.split(",")
                if len(parts) > 5 and CLIENT_MAC in parts[0]:
                    rssi = parts[3].strip()
                    # Verify we have a real, valid power reading from the client hardware
                    if rssi and rssi != "-1" and rssi != "0":
                        return f"{rssi} dBm"
                    return "[Ping/Quiet...]"
    except Exception:
        pass
    return "[Syncing...]"

# --- Main Execution ---
if __name__ == "__main__":
    if not CLIENT_MAC or not CHANNEL_RAW:
        print("[-] Error: No Recon Client selected! Execute from the Client specific Recon menu.")
        sys.exit(1)

    # 1. Start the tracking engine
    airo_proc = start_airodump()
    time.sleep(1) 

    # 2. Take over the screen
    stop_ui()

    try:
        with Pager() as p:
            p.set_rotation(270) # Landscape view Orientation

            print("[+] Client Hunter Active. Press A/B on Pager or Enter in SSH to terminate.")

            while True:
                # 3. Parse client data from RAM
                current_signal = parse_client_rssi()

                # Dynamic color mapping based on proximity
                text_color = Pager.WHITE
                if "dBm" in current_signal:
                    try:
                        val = int(current_signal.split()[0])
                        if val >= -60: text_color = Pager.GREEN       # Very Close
                        elif val >= -75: text_color = Pager.YELLOW    # Approaching
                        else: text_color = Pager.RED                  # Far Away
                    except ValueError:
                        pass

                # 4. Render Layout to Pager
                p.clear(p.rgb(0, 0, 0))
                p.draw_text(10, 10, f"TARGET CLIENT:", Pager.WHITE, 1)
                p.draw_text(10, 22, f"{CLIENT_MAC.upper()}", Pager.YELLOW, 1)
                p.draw_text(10, 36, f"CH: {CHANNEL_RAW} | AP: {BSSID.upper()[:12]}...", Pager.WHITE, 1)

                # High-contrast tracking readout
                p.draw_text(10, 55, current_signal, text_color, 2)

                p.draw_text(10, 90, "[A/B] or [ENTER] to stop hunt", Pager.WHITE, 1)
                p.flip() 

                # 5. Non-blocking Input Checks
                current, pressed, released = p.poll_input()
                if pressed & (Pager.BTN_A | Pager.BTN_B):
                    print("[+] Exit triggered via hardware button.")
                    break

                if sys.stdin.isatty():
                    r, w, x = select.select([sys.stdin], [], [], 0.1)
                    if r:
                        sys.stdin.readline()
                        print("[+] Exit triggered via terminal input.")
                        break
                else:
                    time.sleep(0.1)

    finally:
        # 6. Cleanup
        print("[*] Terminating tracking engine...")
        try:
            airo_proc.terminate()
            airo_proc.wait()
        except Exception:
            pass

        subprocess.run("rm -f /tmp/clientpython*", shell=True)
        start_ui()
        print("[+] Tracker stopped safely.")
