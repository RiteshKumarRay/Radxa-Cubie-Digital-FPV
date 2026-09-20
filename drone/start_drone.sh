#!/bin/bash
# ==============================================================================
#  VTX — WFB-ng Drone Air Unit  |  Radxa Cubie A7S + BL-M8812EU2 + Brio 100
#  Ultra-Clean 720p @ 30 FPS High-Bitrate Video + Bidirectional MAVLink
#  Usage: sudo ./start_drone.sh   (or: sudo /path/to/wfb-ng/start_drone.sh)
#  Stop:  sudo ./stop_drone.sh
# ==============================================================================
export PATH="/sbin:/usr/sbin:/usr/local/sbin:$PATH"

# ── CONFIG ────────────────────────────────────────────────────────────────────
CHANNEL="149"          # 5.8 GHz (5745 MHz)
TXPOWER="2000"         # mBm  |  2000=20dBm (100mW - stable USB power without brownout)
MCS="2"                # 0=BPSK(6.5M)  1=QPSK(13M)  2=QPSK(19.5M - perfect balance of range & speed)
VIDEO_RES="1280x720"   # 720p (2x2 pixel binning = 4x light, solid 30fps, zero lag)
VIDEO_FPS="30"
VIDEO_BITRATE="3500k"  # 3.5 Mbps High-Fidelity CABAC (maximum safe sweet spot, razor sharp details)

# Auto-locate WFB-ng directory (or specify via: export WFB_DIR=/path/to/wfb-ng)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$WFB_DIR" ]; then
    if [ -f "$SCRIPT_DIR/wfb_tx" ]; then
        WFB_DIR="$SCRIPT_DIR"
    elif [ -f "$HOME/wfb-ng/wfb_tx" ]; then
        WFB_DIR="$HOME/wfb-ng"
    elif [ -d "/home" ] && [ -n "$(find /home -maxdepth 3 -name wfb_tx 2>/dev/null | head -1)" ]; then
        WFB_DIR="$(dirname "$(find /home -maxdepth 3 -name wfb_tx 2>/dev/null | head -1)")"
    else
        WFB_DIR="/usr/local/bin"
    fi
fi

KEY_FILE="${KEY_FILE:-$WFB_DIR/drone.key}"
MAV_CONF="${MAV_CONF:-$SCRIPT_DIR/mavlink-router.conf}"
[ ! -f "$MAV_CONF" ] && MAV_CONF="$WFB_DIR/mavlink-router.conf"

# Flight controller device (auto-detected if available)
FC_BAUD="${FC_BAUD:-115200}"
FC_DEVICE="${FC_DEVICE:-}"
if [ -z "$FC_DEVICE" ] || [ ! -c "$FC_DEVICE" ]; then
    for dev in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0 /dev/ttyUSB1; do
        [ -c "$dev" ] && FC_DEVICE="$dev" && break
    done
fi
FC_DEVICE="${FC_DEVICE:-/dev/ttyACM0}"
# ─────────────────────────────────────────────────────────────────────────────

[ "$EUID" -ne 0 ] && { echo "[-] Run as root: sudo $0"; exit 1; }
if [ ! -f "$KEY_FILE" ]; then
    echo "[-] drone.key missing at $KEY_FILE!"
    echo "    To generate encryption keys, run: wfb_keygen"
    echo "    Then copy drone.key to $KEY_FILE and gs.key to your Ground Station."
    exit 1
fi

echo "========================================================="
echo "  VTX — WFB-ng Air Unit (720p High-Bitrate + MAVLink)"
echo "  Video (P0) ↓  |  MAVLink (P1) ↑↓"
echo "========================================================="

# ── AUTO-DETECT: RTL8812EU by MAC prefix fc:37:6d ────────────────────────────
WLAN=""
for iface in $(ls /sys/class/net); do
    grep -q '^fc:37:6d' "/sys/class/net/$iface/address" 2>/dev/null && WLAN="$iface" && break
done
[ -z "$WLAN" ] && { echo "[-] RTL8812EU (MAC fc:37:6d:*) not found — check USB!"; exit 1; }
echo "[+] WiFi Module : $WLAN  ($(cat /sys/class/net/$WLAN/address))"

# ── AUTO-DETECT: Camera by USB VID:PID 046d:094c (Brio 100) ─────────────────
VIDEO_DEV=""
for dev in /dev/video*; do
    if udevadm info "$dev" 2>/dev/null | grep -q "ID_VENDOR_ID=046d"; then
        if udevadm info "$dev" 2>/dev/null | grep -q "ID_MODEL_ID=094c"; then
            v4l2-ctl --device="$dev" --info 2>/dev/null | grep -q "Video Capture" && VIDEO_DEV="$dev" && break
        fi
    fi
done
[ -z "$VIDEO_DEV" ] && { for dev in /dev/video*; do v4l2-ctl --device="$dev" --list-formats 2>/dev/null | grep -q "MJPG" && VIDEO_DEV="$dev" && break; done; }
[ -z "$VIDEO_DEV" ] && { echo "[-] Camera not found! Check USB."; exit 1; }
CAM_NAME=$(v4l2-ctl --device="$VIDEO_DEV" --info 2>/dev/null | awk -F': ' '/Card/{print $2}' | tr -d '\r')
echo "[+] Camera      : $VIDEO_DEV  ($CAM_NAME)"

# ── CHECK FC ─────────────────────────────────────────────────────────────────
if [ ! -c "$FC_DEVICE" ]; then
    echo "[-] Flight controller not found on $FC_DEVICE! Check USB."
    exit 1
fi
echo "[+] Flight Ctrl : $FC_DEVICE  @ ${FC_BAUD} baud"
echo "[+] Video       : ${VIDEO_RES}@${VIDEO_FPS}fps  ${VIDEO_BITRATE}bps [CedarX Hardware VPU CABAC]"
echo "[+] Radio       : Channel $CHANNEL | ${TXPOWER}mBm (20dBm / 100mW) | MCS $MCS"
echo "---------------------------------------------------------"

# ── STOP OLD PROCESSES ───────────────────────────────────────────────────────
killall -9 wfb_tx wfb_rx ffmpeg gst-launch-1.0 mavlink-routerd 2>/dev/null || true
pkill -9 -f drone_yolov8n_tracker 2>/dev/null || true
pkill -9 -f drone_npu_tracker 2>/dev/null || true
sleep 1

# ── MONITOR MODE SETUP ───────────────────────────────────────────────────────
echo "[*] Configuring $WLAN → Monitor Mode, Channel $CHANNEL, Max TX Power (${TXPOWER}mBm)..."
nmcli device set "$WLAN" managed no 2>/dev/null || true
pkill -f "wpa_supplicant.*$WLAN" 2>/dev/null || true
ip link set "$WLAN" down; sleep 0.5
/sbin/iw reg set BO 2>/dev/null || true
/sbin/iw dev "$WLAN" set monitor otherbss
ip link set "$WLAN" up; sleep 1
/sbin/iw dev "$WLAN" set channel "$CHANNEL" 2>/dev/null || /sbin/iwconfig "$WLAN" channel "$CHANNEL" 2>/dev/null || true
/sbin/iw dev "$WLAN" set txpower fixed "$TXPOWER" 2>/dev/null || /sbin/iwconfig "$WLAN" txpower 30 2>/dev/null || true

MODE=$(/sbin/iw dev "$WLAN" info | awk '/type/{print $2}')
CURR_CH=$(/sbin/iw dev "$WLAN" info | awk '/channel/{print $2}')
[ "$MODE" != "monitor" ] && { echo "[-] Failed to set monitor mode!"; exit 1; }
[ "$CURR_CH" != "$CHANNEL" ] && { echo "[-] Failed to set channel $CHANNEL!"; exit 1; }
echo "[+] Radio ready : type=$MODE  ch=$CURR_CH  txpower=$(/sbin/iw dev $WLAN info | awk '/txpower/{print $2}') dBm"
echo "---------------------------------------------------------"

cd "$WFB_DIR"

# ── START WFB-ng (Video Port 0 + Bidirectional MAVLink Port 1) ───────────────
# Port 0: Video downlink  ← encoder sends to UDP 5602 (k=8, n=14 absorbs any RF bursts)
"$WFB_DIR/wfb_tx" -p 0 -u 5602  -K "$KEY_FILE" -k 8 -n 14 -T 8 -R 2097152 -B 20 -M "$MCS" "$WLAN" > /tmp/wfb_drone_video.log   2>&1 & PID_VID=$!

# Port 1: MAVLink downlink (Drone→GCS)  ← mavlink-routerd sends FC data to UDP 14561
"$WFB_DIR/wfb_tx" -p 1 -u 14561 -K "$KEY_FILE" -k 1 -n 2  -B 20 -M "$MCS" "$WLAN" > /tmp/wfb_drone_mav_tx.log 2>&1 & PID_MAV_TX=$!

# Port 1: MAVLink uplink  (GCS→Drone)  → mavlink-routerd reads from UDP 14560
"$WFB_DIR/wfb_rx" -p 1 -u 14560 -K "$KEY_FILE" "$WLAN" > /tmp/wfb_drone_mav_rx.log 2>&1 & PID_MAV_RX=$!

echo "[+] WFB-ng started: Video P0 ($PID_VID) | MAVLink P1 (TX: $PID_MAV_TX / RX: $PID_MAV_RX)"

# ── START MAVLINK-ROUTER ──────────────────────────────────────────────────────
sleep 1
echo "[*] Starting mavlink-routerd  ($FC_DEVICE ↔ UDP 14561/14560)..."
mavlink-routerd -c "$MAV_CONF" > /tmp/mavlink_router.log 2>&1 &
PID_MAV_ROUTER=$!
sleep 1
if ! kill -0 "$PID_MAV_ROUTER" 2>/dev/null; then
    echo "[-] mavlink-routerd failed! Check: tail -20 /tmp/mavlink_router.log"
    tail -5 /tmp/mavlink_router.log
    exit 1
fi
echo "[+] mavlink-routerd running (PID $PID_MAV_ROUTER)"

# ── CAMERA TUNING & STRAIGHT-THROUGH 720p HARDWARE ENCODER ───────────────────
echo "[*] Tuning Brio 100 sensor for maximum visual clarity..."
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=exposure_dynamic_framerate=0 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=auto_exposure=3 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=backlight_compensation=1 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=brightness=132 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=contrast=142 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=saturation=145 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=sharpness=165 2>/dev/null || true
v4l2-ctl -d "$VIDEO_DEV" --set-ctrl=power_line_frequency=1 2>/dev/null || true

WIDTH=$(echo "$VIDEO_RES" | cut -dx -f1)
HEIGHT=$(echo "$VIDEO_RES" | cut -dx -f2)
BITRATE_BPS=$(echo "$VIDEO_BITRATE" | sed 's/M/000000/;s/k/000/')
FRAME_SIZE=$((WIDTH * HEIGHT * 3 / 2)) # 1,382,400 bytes per 720p NV12 frame

echo "[*] Starting 720p@30fps pure hardware pipeline (${VIDEO_BITRATE}bps)..."
export XDG_RUNTIME_DIR=/tmp

# Pure Zero-Latency 720p Pipeline:
# - fdsrc do-timestamp=true: stamps every frame with real-time clock (zero drift!)
# - blocksize=$FRAME_SIZE: reads entire 720p frame in 1 system call
# - entropy-mode=1: CABAC high-profile compression (crisp, artifact-free details)
# - queue leaky=downstream: locks latency to real-time (<35ms)
ffmpeg -threads 4 \
       -fflags nobuffer+fastseek+flush_packets -flags low_delay \
       -f v4l2 -input_format mjpeg \
       -video_size "$VIDEO_RES" -framerate "$VIDEO_FPS" -i "$VIDEO_DEV" \
       -vsync 0 -pix_fmt nv12 -f rawvideo - 2>/tmp/camera_stream.log | \
gst-launch-1.0 -q fdsrc do-timestamp=true blocksize="$FRAME_SIZE" ! \
  rawvideoparse format=nv12 width="$WIDTH" height="$HEIGHT" framerate="${VIDEO_FPS}/1" ! \
  queue max-size-buffers=1 max-size-time=0 max-size-bytes=0 leaky=downstream ! \
  omxh264videoenc target-bitrate="$BITRATE_BPS" control-rate=2 periodicity-idr=15 b-frames=0 entropy-mode=1 ! \
  video/x-h264,stream-format=byte-stream ! \
  h264parse ! \
  rtph264pay config-interval=1 pt=96 mtu=1400 ! \
  udpsink host=127.0.0.1 port=5602 sync=false buffer-size=2097152 >>/tmp/camera_stream.log 2>&1 &
PID_CAM=$!

sleep 2
if ! kill -0 "$PID_CAM" 2>/dev/null; then
    echo "[-] Camera pipeline failed! Check: tail -20 /tmp/camera_stream.log"
    tail -15 /tmp/camera_stream.log
    exit 1
fi
echo "[+] Camera & CedarX VPU Encoder running (PID $PID_CAM)"

echo "========================================================="
echo "  VTX LIVE on $WLAN"
echo "  Video (P0)  : ${VIDEO_RES}@${VIDEO_FPS}fps ${VIDEO_BITRATE} [CedarX VPU CABAC] → UDP 5600"
echo "  MAVLink (P1): $FC_DEVICE ↔ WFB-ng ↔ QGC UDP 14550"
echo "---------------------------------------------------------"
echo "  Logs:"
echo "    vtx-log    → WFB-ng video TX stats"
echo "    vtx-cam    → encoder / camera log"
echo "    vtx-mav    → mavlink-router log"
echo "  To stop: vtx-stop"
echo "========================================================="

trap "killall -9 wfb_tx wfb_rx ffmpeg gst-launch-1.0 mavlink-routerd 2>/dev/null; echo '[!] VTX stopped.'; exit 0" INT TERM
wait
