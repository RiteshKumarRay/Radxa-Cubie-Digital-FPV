#!/bin/bash
# Stop WFB-ng GCS processes and restore Wi-Fi
# Auto-detect RTL8812EU interface or specify via: WLAN=wlan1 ./stop_gs.sh
WLAN="${WLAN:-}"
if [ -z "$WLAN" ]; then
    for iface in $(ls /sys/class/net 2>/dev/null); do
        grep -q '^fc:37:6d' "/sys/class/net/$iface/address" 2>/dev/null && WLAN="$iface" && break
    done
fi

echo "[*] Stopping WFB-ng processes..."
sudo killall -9 wfb_rx wfb_tx 2>/dev/null || true
sudo pkill -f mavlink_gcs_proxy.py 2>/dev/null || true

echo "[*] Resetting $WLAN interface to Managed mode..."
sudo ip link set "$WLAN" down 2>/dev/null || true
sudo iw dev "$WLAN" set type managed 2>/dev/null || true
sudo ip link set "$WLAN" up 2>/dev/null || true
nmcli device set "$WLAN" managed yes 2>/dev/null || true

echo "[+] Done. $WLAN restored to standard Wi-Fi mode."
