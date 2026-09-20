#!/bin/bash
trap "sudo pkill -9 gst-launch-1.0 2>/dev/null; exit 0" INT TERM EXIT

echo "Starting camera streaming..."
echo "radxa" | sudo -S pkill -9 gst-launch-1.0 2>/dev/null
echo "radxa" | sudo -S gst-launch-1.0 -q v4l2src device=/dev/video0 en-awisp=1 en-largemode=0 ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! fakesink >/dev/null 2>&1 &
GST_PID=$!
sleep 1.5

echo "=========================================================="
echo "  LIVE 31P 0.3mm MIPI CSI HARDWARE PIN MONITOR"
echo "  (Press Ctrl+C to stop)"
echo "=========================================================="

while kill -0 $GST_PID 2>/dev/null; do
    INFO=$(echo "radxa" | sudo -S cat /sys/kernel/debug/mpp/mipi 2>/dev/null)
    CLK=$(echo "$INFO" | grep "clk_lane:" | head -1 | awk "{print \$2, \$3}")
    L0=$(echo "$INFO" | grep "data_lane0:" | head -1 | awk "{print \$2, \$3}")
    L1=$(echo "$INFO" | grep "data_lane1:" | head -1 | awk "{print \$2, \$3}")
    BPS=$(echo "$INFO" | grep "mipi_bps:" | head -1 | awk "{print \$2}")
    
    printf "%-8s | CLK: %-15s | LANE0: %-15s | LANE1: %-15s\n" "${BPS}Mbps" "$CLK" "$L0" "$L1"
    sleep 0.5
done

sudo pkill -9 gst-launch-1.0 2>/dev/null
