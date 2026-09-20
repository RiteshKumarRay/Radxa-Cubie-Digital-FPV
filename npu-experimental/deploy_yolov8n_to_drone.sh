#!/bin/bash
# ==============================================================================
# Deploy YOLOv8n (640x384) Model & Tracker to Radxa Air Unit
# Run this as soon as the Radxa drone unit is connected to WiFi/network.
# ==============================================================================
set -e

DRONE_IP="10.107.1.186"
DRONE_USER="radxa"
DRONE_PASS="radxa"

echo "========================================================="
echo "  Deploying YOLOv8n (640x384) to Radxa Drone ($DRONE_IP)"
echo "========================================================="

# Check connection
echo "[*] Checking connection to $DRONE_IP..."
if ! ping -c 1 -W 2 "$DRONE_IP" >/dev/null 2>&1; then
    echo "[-] Cannot reach Radxa at $DRONE_IP. Please check connection and try again."
    exit 1
fi
echo "[+] Radxa is online!"

# Copy compiled models, C++ source, and tracker scripts
echo "[*] Transferring YOLOv8n models, C++ tracker, and scripts..."
scp -o StrictHostKeyChecking=no \
    /home/ritesh/wfb-ng/yolov8n_384x640_t527.nb \
    /home/ritesh/wfb-ng/yolov8n_384x640_a733.nb \
    /home/ritesh/wfb-ng/drone_yolov8n_tracker.cpp \
    /home/ritesh/wfb-ng/build_tracker_cpp.sh \
    /home/ritesh/wfb-ng/drone_yolov8n_tracker.py \
    "${DRONE_USER}@${DRONE_IP}:/home/radxa/npu/"

echo "[+] Files transferred successfully."

# Build C++ native binary on the Radxa and configure start_drone.sh
echo "[*] Building native C++ Tracker on Radxa and configuring start_drone.sh..."
ssh -o StrictHostKeyChecking=no "${DRONE_USER}@${DRONE_IP}" "bash -s" << 'REMOTE_SCRIPT'
cd /home/radxa/npu
chmod +x build_tracker_cpp.sh drone_yolov8n_tracker.py
bash ./build_tracker_cpp.sh

# Update start_drone.sh on Radxa to use the native C++ tracker binary
sed -i 's|/home/radxa/yolo_env/bin/python3 "\$NPU_SCRIPT"|/home/radxa/npu/drone_yolov8n_tracker|' /home/radxa/wfb-ng/start_drone.sh
sed -i 's|NPU_SCRIPT=.*|NPU_SCRIPT="/home/radxa/npu/drone_yolov8n_tracker"|' /home/radxa/wfb-ng/start_drone.sh

# Set videorate to 30 for smooth 30fps NPU feed
sed -i 's|videorate max-rate=10|videorate max-rate=30|' /home/radxa/wfb-ng/start_drone.sh

echo "[+] start_drone.sh updated to Native C++ YOLOv8n Tracker @ 30fps!"
REMOTE_SCRIPT

echo "========================================================="
echo "  Deployment Complete! "
echo "  You can now type 'vtx' on the drone to start."
echo "========================================================="
