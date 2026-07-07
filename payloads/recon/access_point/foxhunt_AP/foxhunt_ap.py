import os
import sys
import time
import select
import subprocess
from pagerctl import Pager

# --- Pull and Sanitize Hak5 Recon Environment Variables ---
BSSID = os.getenv("_RECON_SELECTED_AP_BSSID", "").strip().lower()
CHANNEL_RAW = os.getenv("_RECON_SELECTED_AP_CHANNEL", "").strip()

def stop_ui():
    subprocess.run(["/etc/init.d/pineapplepager", "stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

def start_ui():
    subprocess.run(["/etc/init.d/pineapplepager", "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def start_airodump():
    """Launches backend airodump-ng cleanly using absolute pathing."""
    band = "g"
    try:
        if CHANNEL_RAW and int(CHANNEL_RAW) > 14:
            band = "a"
    except ValueError:
        pass
        
    print(f"[*] Locking Radio onto BSSID: {BSSID} on Channel: {CHANNEL_RAW}...")
    
    # Explicit absolute system path so the UI menu environment can locate the binary
    cmd = ["/usr/sbin/airodump-ng", "--bssid", BSSID, "-c", CHANNEL_RAW, "--band", band, "--output-format", "csv", "-w", "/tmp/foxpython", "wlan1mon"]
    process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return process

def parse_rssi():
    """Reads the volatile ramdisk CSV cleanly without creating a CPU storage bottleneck."""
    csv_path = "/tmp/foxpython-01.csv"
    if not os.path.exists(csv_path):
        return "[Waiting...]"
        
    try:
        with open(csv_path, "r") as f:
            lines = f.readlines()
            for line in lines:
                parts = line.lower().split(",")
                if len(parts) > 9 and BSSID in parts[0] and "station" not in line:
                    rssi = parts[8].strip()
                    if rssi and rssi != "-1":
                        return f"{rssi} dBm"
                    return "[Decoding...]"
    except Exception:
        pass
    return "[Syncing...]"

# --- Main Execution ---
if __name__ == "__main__":
    # SAFEGUARD: Exit status 0 prevents the UI manager from rendering a crash overlay
    if not BSSID or not CHANNEL_RAW:
        print("[-] Error: No Recon Access Point selected! Execute from the Recon menu.")
        sys.exit(0)

    # 1. Start the fast hardware data gatherer
    airo_proc = start_airodump()
    time.sleep(1) # Let the wireless card lock its target channel
    
    # 2. Clear native interface to prepare drawing space
    stop_ui()
    
    try:
        with Pager() as p:
            p.set_rotation(270) # Landscape view Orientation
            
            print("[+] Fox Hunter Active. Press A/B on Pager or Enter in SSH to terminate.")
            
            while True:
                # 3. Parse data from RAM
                current_signal = parse_rssi()
                
                # Assign colors dynamically based on target proximity using Pager class constants
                text_color = Pager.WHITE
                if "dBm" in current_signal:
                    try:
                        val = int(current_signal.split()[0])
                        if val >= -60: text_color = Pager.GREEN       # Hot (Very Close)
                        elif val >= -75: text_color = Pager.YELLOW    # Warm (Approaching)
                        else: text_color = Pager.RED                  # Cold (Far Away)
                    except ValueError:
                        pass

                # 4. Draw Layout Buffers
                p.clear(p.rgb(0, 0, 0))
                p.draw_text(10, 10, f"TARGET: {BSSID.upper()}", Pager.WHITE, 1)
                p.draw_text(10, 25, f"CHANNEL: {CHANNEL_RAW}", Pager.WHITE, 1)
                
                # Render high-contrast tracking readout
                p.draw_text(10, 45, current_signal, text_color, 2)
                
                p.draw_text(10, 90, "[A/B] or [ENTER] to stop hunt", Pager.WHITE, 1)
                p.flip() # Instantly swap the memory matrix to glass
                
                # 5. Non-blocking Multi-Input Kill Checks
                current, pressed, released = p.poll_input()
                if pressed & (Pager.BTN_A | Pager.BTN_B):
                    print("[+] Exit triggered via hardware button.")
                    break
                    
                # Only check terminal input if we are attached to a real interactive SSH terminal
                if sys.stdin.isatty():
                    r, w, x = select.select([sys.stdin], [], [], 0.1)
                    if r:
                        sys.stdin.readline()
                        print("[+] Exit triggered via terminal input.")
                        break
                else:
                    # Avoid CPU pinning when running headless in the background UI
                    time.sleep(0.1)
                    
    finally:
        # 6. Cleanup hardware processes and restore normal system state
        print("[*] Terminating tracking engine...")
        try:
            airo_proc.terminate()
            airo_proc.wait()
        except Exception:
            pass
        
        # Purge temporary files
        subprocess.run("rm -f /tmp/foxpython*", shell=True)
        
        # Bring factory UI back alive
        start_ui()
        print("[+] Tracker stopped safely.")
