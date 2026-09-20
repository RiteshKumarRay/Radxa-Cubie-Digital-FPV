#!/bin/bash
# ==============================================================================
#  Sensor Tuning Script for Logitech Brio 100 on Radxa Cubie A7S
# ==============================================================================
DEV="${1:-/dev/video0}"

if [ ! -e "$DEV" ]; then
    echo "[-] Video device $DEV not found!"
    exit 1
fi

echo "[*] Applying optimized aerial FPV tuning to $DEV..."
v4l2-ctl -d "$DEV" --set-ctrl=exposure_dynamic_framerate=0 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=auto_exposure=3 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=backlight_compensation=1 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=brightness=132 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=contrast=142 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=saturation=145 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=sharpness=165 2>/dev/null || true
v4l2-ctl -d "$DEV" --set-ctrl=power_line_frequency=1 2>/dev/null || true

echo "[+] Current controls:"
v4l2-ctl -d "$DEV" --get-ctrl=brightness,contrast,saturation,sharpness,backlight_compensation,power_line_frequency
