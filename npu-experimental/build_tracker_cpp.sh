#!/bin/bash
# ==============================================================================
# Build Native C++ YOLOv8n Tracker on Radxa Cubie A7S / T527
# Links with OpenCV 4, awnn_shim.o, and NPU driver libraries
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[*] Compiling C++ YOLOv8n Tracker (drone_yolov8n_tracker)..."

# Compile awnn_shim.o if source exists
[ -f awnn_shim.c ] && gcc -c -fPIC awnn_shim.c -o awnn_shim.o -I. || true

# Compile and link tracker with rpath set to origin directory
g++ -O3 -std=c++14 drone_yolov8n_tracker.cpp $([ -f awnn_shim.o ] && echo "awnn_shim.o") \
    -o drone_yolov8n_tracker \
    -I. \
    $(pkg-config --cflags --libs opencv4 2>/dev/null || true) \
    -L. -lNBGlinker -lVIPhal -lpthread \
    -Wl,-rpath,'$ORIGIN'

chmod +x drone_yolov8n_tracker

echo "[+] Successfully built drone_yolov8n_tracker!"
