#!/bin/bash
# ==============================================================================
# Build Native C++ YOLOv8n Tracker on Radxa Cubie A7S / T527
# Links with OpenCV 4, awnn_shim.o, and NPU driver libraries
# ==============================================================================
set -e

cd /home/radxa/npu

echo "[*] Compiling C++ YOLOv8n Tracker (drone_yolov8n_tracker)..."

# Ensure awnn_shim.o is fresh
gcc -c -fPIC awnn_shim.c -o awnn_shim.o -I.

# Compile and link tracker with rpath set to /home/radxa/npu
g++ -O3 -std=c++14 drone_yolov8n_tracker.cpp awnn_shim.o \
    -o drone_yolov8n_tracker \
    -I. \
    $(pkg-config --cflags --libs opencv4) \
    -L. -lNBGlinker -lVIPhal -lpthread \
    -Wl,-rpath,/home/radxa/npu

chmod +x drone_yolov8n_tracker

echo "[+] Successfully built /home/radxa/npu/drone_yolov8n_tracker!"
