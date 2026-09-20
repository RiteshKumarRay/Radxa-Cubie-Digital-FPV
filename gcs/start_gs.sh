#!/bin/bash
# ==============================================================================
#  GCS — WFB-ng Ground Control Station  |  BL-M8812EU2 (RTL8812EU)
#  Usage: gcs   (or: sudo /home/ritesh/wfb-ng/start_gs.sh)
#  Stop:  gcs-stop
# ==============================================================================

# ── CONFIG ────────────────────────────────────────────────────────────────────
CHANNEL="149"      # Must match VTX side (5745 MHz)
BANDWIDTH="HT20"
WFB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_FILE="$WFB_DIR/gs.key"
DRIVER_KO="/home/ritesh/rtl88x2eu/8812eu.ko"
# ─────────────────────────────────────────────────────────────────────────────

[ "$EUID" -ne 0 ] && { echo "[-] Run as root: sudo $0  (or just type: gcs)"; exit 1; }
[ ! -f "$KEY_FILE" ] && { echo "[-] gs.key missing in $WFB_DIR"; exit 1; }

echo "========================================================="
echo "  GCS — WFB-ng Ground Station Starting..."
echo "========================================================="

# ── AUTO-DETECT: RTL8812EU by MAC prefix fc:37:6d ────────────────────────────
find_wlan() {
    for iface in $(ls /sys/class/net 2>/dev/null); do
        grep -q '^fc:37:6d' "/sys/class/net/$iface/address" 2>/dev/null && echo "$iface" && return
    done
}

# Optional force-reset flag
RESET_CARD=false
if [ "$1" = "-r" ] || [ "$1" = "--reset" ] || [ "$2" = "-r" ] || [ "$2" = "--reset" ]; then
    RESET_CARD=true
fi

WLAN=$(find_wlan)

# Check if driver is in bad/SR/suspended state
if [ -n "$WLAN" ] && [ -f "/proc/net/rtl88x2eu/$WLAN/adapters_status" ]; then
    grep -q "SR" "/proc/net/rtl88x2eu/$WLAN/adapters_status" && RESET_CARD=true
elif [ -n "$WLAN" ] && [ ! -d "/proc/net/rtl88x2eu/$WLAN" ]; then
    RESET_CARD=true
fi

if [ -z "$WLAN" ] || [ "$RESET_CARD" = true ]; then
    echo "[!] Performing USB hardware reset & driver reload..."
    killall -9 wfb_rx wfb_tx 2>/dev/null || true
    rmmod 8812eu 2>/dev/null || true
    sleep 1
    usbreset 0bda:a81a 2>/dev/null || true
    sleep 2
    insmod "$DRIVER_KO" || { echo "[-] Failed to load 8812eu.ko"; exit 1; }
    sleep 2
    WLAN=$(find_wlan)
    [ -z "$WLAN" ] && { echo "[-] RTL8812EU not found — check USB connection!"; exit 1; }
    echo "[+] Driver reloaded and card ready."
fi

echo "[+] WiFi Module : $WLAN  ($(cat /sys/class/net/$WLAN/address))"

# ── STOP OLD PROCESSES ───────────────────────────────────────────────────────
killall -9 wfb_rx wfb_tx 2>/dev/null || true


# ── MONITOR MODE SETUP ───────────────────────────────────────────────────────
echo "[*] Configuring $WLAN → Monitor Mode, Channel $CHANNEL..."

# Kill NetworkManager control aggressively
nmcli device set "$WLAN" managed no 2>/dev/null || true
pkill -f "wpa_supplicant.*$WLAN" 2>/dev/null || true
sleep 1

ip link set "$WLAN" down
sleep 1.5
iw reg set BO 2>/dev/null || true
iw dev "$WLAN" set monitor otherbss
sleep 0.5
ip link set "$WLAN" up
sleep 1.5
iw dev "$WLAN" set channel "$CHANNEL" HT20 2>/dev/null || iw dev "$WLAN" set channel "$CHANNEL" 2>/dev/null || iwconfig "$WLAN" channel "$CHANNEL" 2>/dev/null || true

MODE=$(iw dev "$WLAN" info | awk '/type/{print $2}')
CURR_CH=$(iw dev "$WLAN" info | awk '/channel/{print $2}')
[ "$MODE" != "monitor" ] && { echo "[-] Failed to set monitor mode!"; exit 1; }
[ "$CURR_CH" != "$CHANNEL" ] && { echo "[-] Failed to set channel $CHANNEL!"; exit 1; }

echo "[+] Radio ready : type=$MODE  channel=$CURR_CH"
echo "---------------------------------------------------------"
echo "[+] Ports:"
echo "    Video stream    → UDP 127.0.0.1:5600  (720p HD FPV HUD / QGC)"
echo "    MAVLink telem   → UDP 127.0.0.1:14550 (QGroundControl)"
echo "    MAVLink OSD     → UDP 127.0.0.1:14551 (FPV HUD)"
echo "---------------------------------------------------------"

# ── START WFB-ng (Video + Bidirectional MAVLink) ─────────────────────────────
cd "$WFB_DIR"
# Port 0: Video downlink  → QGC / FPV HUD UDP 5600
"$WFB_DIR/wfb_rx" -p 0 -u 5600  -K "$KEY_FILE" -R 2097152 -l 2000 "$WLAN" > /tmp/wfb_rx_video.log   2>&1 & PID_VID=$!

# Kill any previous proxy
pkill -f mavlink_gcs_proxy.py 2>/dev/null || true
# Start transparent MAVLink proxy (bridges 14552 <-> QGC 14550 <-> FPV 14551 <-> wfb_tx 14555)
python3 "$WFB_DIR/mavlink_gcs_proxy.py" > /tmp/mavlink_proxy.log 2>&1 &
PID_PROXY=$!

# Port 1: MAVLink downlink (Drone→GCS)  → Proxy UDP 14552
"$WFB_DIR/wfb_rx" -p 1 -u 14552 -K "$KEY_FILE" -l 2000 "$WLAN" > /tmp/wfb_rx_mavlink.log 2>&1 & PID_MAV_RX=$!

# Port 1: MAVLink uplink (GCS→Drone) disabled on single-dongle GCS to prevent RTL8812EU RX lockup
# "$WFB_DIR/wfb_tx" -p 1 -u 14555 -K "$KEY_FILE" -k 1 -n 2 -B 20 -M 1 "$WLAN" > /tmp/wfb_tx_mavlink.log 2>&1 & PID_MAV_TX=$!
PID_MAV_TX=0


echo "[+] GCS is LIVE! Open QGroundControl or run 'fpv':"
echo "    Video   → UDP 5600   (720p HD | RX PID: $PID_VID)"
echo "    MAVLink → UDP 14550  (Bidirectional over WFB-ng)"
echo "========================================================="
echo "  Logs:  gcs-log (video) | gcs-mav (mavlink)"
echo "  To stop: gcs-stop  (or Ctrl+C)"
echo "========================================================="

# ── DAEMON OR FOREGROUND MODE ────────────────────────────────────────────────
if [ "$1" = "-d" ] || [ "$1" = "--daemon" ]; then
    echo "[+] Running in background mode. Use 'gcs-log' or 'gcs-mav' to view logs."
    echo "[+] Run 'gcs-stop' to terminate."
    exit 0
fi

trap "kill -9 $PID_VID $PID_MAV_RX $PID_MAV_TX $PID_PROXY 2>/dev/null; echo '[!] GCS stopped.'; exit 0" INT TERM

# Live packet counter in terminal
echo "[*] Monitoring signal (Ctrl+C to stop)..."
tail -f /tmp/wfb_rx_video.log

