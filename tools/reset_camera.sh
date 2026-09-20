#!/bin/bash
echo "Stopping all camera processes..."
sudo pkill -9 gst-launch-1.0 2>/dev/null
sudo pkill -9 mediamtx 2>/dev/null
sudo pkill -9 python3 2>/dev/null
sleep 1

echo "Clearing ISP cache..."
sudo rm -f /mnt/isp0_* /mnt/isp1_*

echo "Starting MediaMTX..."
cd /home/radxa
./mediamtx > /home/radxa/mediamtx.log 2>&1 &
sleep 2

echo "Starting 720p 30fps stream with SOFTWARE H264 encoder (zero VE conflicts)..."
sudo bash -c 'gst-launch-1.0 -e \
  v4l2src device=/dev/video0 en-awisp=1 en-largemode=0 do-timestamp=true ! \
  "video/x-raw,format=NV12,width=1280,height=720,framerate=30/1" ! \
  queue max-size-buffers=4 leaky=downstream ! \
  videoconvert ! \
  "video/x-raw,format=I420" ! \
  x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 ! \
  "video/x-h264,profile=baseline" ! \
  h264parse config-interval=1 ! \
  rtspclientsink location=rtsp://localhost:8554/camera > /home/radxa/gst.log 2>&1 &'

echo "Done! Camera streaming at 720p (software encoder = no VE timeouts = smooth stream)."
