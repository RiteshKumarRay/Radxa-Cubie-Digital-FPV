#!/bin/bash
# ==============================================================================
# Deploy YOLOv8n (640x384) Model & Tracker to Radxa Air Unit
# Run this as soon as the Radxa drone unit is connected to WiFi/network.
# ==============================================================================
set -e

# Enter your Drone SBC connection details here (or pass as env vars):
DRONE_IP="${1:-${DRONE_IP:-192.168.1.100}}"  # Replace with your Radxa board IP (e.g. run 'ip a' on drone)
DRONE_USER="${DRONE_USER:-radxa}"             # Default user on Radxa

echo "========================================================="
echo "  Deploying YOLOv8n (640x384) to Radxa Drone ($DRONE_IP)"
echo "========================================================="

# Check connection
echo "[*] Checking connection to $DRONE_IP..."
if ! ping -c 1 -W 2 "$DRONE_IP" >/dev/null 2>&1; then
    echo "[-] Cannot reach Radxa at $DRONE_IP. Please check connection and try again."
    echo "    Usage: $0 <DRONE_IP>"
    exit 1
fi
echo "[+] Radxa is online!"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy compiled models, C++ source, and tracker scripts
echo "[*] Transferring YOLOv8n models, C++ tracker, and scripts..."
ssh -o StrictHostKeyChecking=no "${DRONE_USER}@${DRONE_IP}" "mkdir -p /home/${DRONE_USER}/npu"
scp -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/yolov8n_384x640_t527.nb" \
    "$SCRIPT_DIR/yolov8n_384x640_a733.nb" \
    "$SCRIPT_DIR/drone_yolov8n_tracker.cpp" \
    "$SCRIPT_DIR/build_tracker_cpp.sh" \
    "$SCRIPT_DIR/drone_yolov8n_tracker.py" \
    "${DRONE_USER}@${DRONE_IP}:/home/${DRONE_USER}/npu/"

echo "[+] Files transferred successfully."

# Build C++ native binary on the Radxa and configure start_drone.sh
echo "[*] Building native C++ Tracker on Radxa and configuring start_drone.sh..."
ssh -o StrictHostKeyChecking=no "${DRONE_USER}@${DRONE_IP}" "bash -s" << REMOTE_SCRIPT
cd "/home/${DRONE_USER}/npu"
chmod +x build_tracker_cpp.sh drone_yolov8n_tracker.py
bash ./build_tracker_cpp.sh

# Update start_drone.sh on Radxa to use the native C++ tracker binary
if [ -f "/home/${DRONE_USER}/wfb-ng/start_drone.sh" ]; then
    sed -i "s|/home/.*/drone_yolov8n_tracker|/home/${DRONE_USER}/npu/drone_yolov8n_tracker|" "/home/${DRONE_USER}/wfb-ng/start_drone.sh"
fi
REMOTE_SCRIPT

echo "========================================================="
echo "  Deployment Complete! "
echo "  You can now type 'vtx' on the drone to start."
echo "========================================================="
