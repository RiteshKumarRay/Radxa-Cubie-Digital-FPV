#!/bin/bash
# Stop WFB-ng GCS processes and restore Wi-Fi
WLAN="wlxfc376d07d198"

echo "[*] Stopping WFB-ng processes..."
sudo killall -9 wfb_rx wfb_tx 2>/dev/null || true
sudo pkill -f mavlink_gcs_proxy.py 2>/dev/null || true

echo "[*] Resetting $WLAN interface to Managed mode..."
sudo ip link set "$WLAN" down 2>/dev/null || true
sudo iw dev "$WLAN" set type managed 2>/dev/null || true
sudo ip link set "$WLAN" up 2>/dev/null || true
nmcli device set "$WLAN" managed yes 2>/dev/null || true

echo "[+] Done. $WLAN restored to standard Wi-Fi mode."
