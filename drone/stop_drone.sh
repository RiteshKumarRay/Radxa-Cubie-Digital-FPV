#!/bin/bash
export PATH="/sbin:/usr/sbin:/usr/local/sbin:$PATH"
echo "[*] Stopping WFB-ng and Camera processes on Drone..."
killall -9 wfb_tx wfb_rx ffmpeg gst-launch-1.0 mavlink-routerd 2>/dev/null || true
pkill -9 -f drone_npu_tracker.py 2>/dev/null || true ; pkill -9 drone_yolov8n_tracker

WLAN=""
for iface in $(ls /sys/class/net); do
    if grep -q '^fc:37:6d' "/sys/class/net/$iface/address" 2>/dev/null; then
        WLAN="$iface"
        break
    fi
done

if [ -n "$WLAN" ]; then
    echo "[*] Restoring $WLAN..."
    ip link set "$WLAN" down 2>/dev/null || true
    iwconfig "$WLAN" mode managed 2>/dev/null || iw dev "$WLAN" set type managed 2>/dev/null || true
    ip link set "$WLAN" up 2>/dev/null || true
fi
echo "[+] Drone services stopped."
