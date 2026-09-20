#!/usr/bin/env python3
"""
Minimalist & Clean FPV OSD (DJI / OpenIPC / Betaflight Style)
=============================================================================
Pure High-Definition Digital FPV (720p / 1080p) + Bidirectional MAVLink Telemetry + WFB-ng RSSI
=============================================================================
"""

import os
import sys
import time
import math
import socket
import threading
from collections import deque

os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
import pygame
import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstApp', '1.0')
from gi.repository import Gst, GstApp
Gst.init(None)

try:
    from pymavlink import mavutil
    HAS_MAVLINK = True
except ImportError:
    HAS_MAVLINK = False

VIDEO_PORT   = int(sys.argv[1]) if len(sys.argv) > 1 else 5600
MAVLINK_PORT = 14551  # Fed by mavlink_gcs_proxy.py (or fallback to 14552 / 14550)

# ── MINIMALIST COLOR PALETTE ──────────────────────────────────────────────────
COLOR_WHITE        = (255, 255, 255)
COLOR_LIGHT_YELLOW = (255, 244, 163)   # Off-light warm yellow
COLOR_DIM_WHITE    = (190, 195, 205)   # Secondary info / units
COLOR_BLACK        = (0, 0, 0)         # Stroke outline for high contrast


# ── MAVLINK TELEMETRY THREAD ──────────────────────────────────────────────────
class MAVLinkRx(threading.Thread):
    def __init__(self, port=MAVLINK_PORT):
        super().__init__(daemon=True)
        self.port = port
        self._lock = threading.Lock()
        self.running = True
        self._ts = 0.0
        self.data = {
            "connected": False,
            "armed": False,
            "mode": "DISARMED",
            "voltage": 0.0,
            "cell_volt": 0.0,
            "heading": 0,
            "alt": 0.0,
            "speed": 0.0,
            "climb": 0.0,
            "throttle": 0,
            "sats": 0,
            "roll": 0.0,
            "pitch": 0.0,
            "arm_time": 0,
        }
        self.arm_start_ts = None

    def run(self):
        if not HAS_MAVLINK:
            return

        while self.running:
            try:
                mav = None
                for try_port in [self.port, 14552, 14550]:
                    try:
                        mav = mavutil.mavlink_connection(f"udpin:0.0.0.0:{try_port}")
                        break
                    except Exception:
                        continue

                if not mav:
                    time.sleep(1.0)
                    continue

                while self.running:
                    msg = mav.recv_match(blocking=True, timeout=0.5)
                    if not msg:
                        continue

                    mtype = msg.get_type()
                    t_now = time.time()

                    with self._lock:
                        self.data["connected"] = True
                        self._ts = t_now

                        if mtype == 'HEARTBEAT':
                            armed = bool(msg.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
                            if armed and not self.data["armed"]:
                                self.arm_start_ts = t_now
                            elif not armed:
                                self.arm_start_ts = None
                            self.data["armed"] = armed

                            try:
                                mode_name = mavutil.mode_string_v10(msg)
                            except Exception:
                                mode_name = f"MODE_{msg.custom_mode}"
                            self.data["mode"] = mode_name.upper()

                        elif mtype == 'ATTITUDE':
                            self.data["roll"]  = math.degrees(msg.roll)
                            self.data["pitch"] = math.degrees(msg.pitch)

                        elif mtype == 'VFR_HUD':
                            self.data["heading"]  = int(msg.heading)
                            self.data["alt"]      = round(msg.alt, 1)
                            self.data["speed"]    = round(msg.groundspeed * 3.6, 1)
                            self.data["climb"]    = round(msg.climb, 1)
                            self.data["throttle"] = int(msg.throttle)

                        elif mtype == 'SYS_STATUS':
                            if msg.voltage_battery > 0:
                                v = msg.voltage_battery / 1000.0
                                self.data["voltage"] = round(v, 2)
                                cells = 3 if v < 13.0 else (4 if v < 17.5 else 6)
                                self.data["cell_volt"] = round(v / cells, 2)

                        elif mtype == 'GPS_RAW_INT':
                            self.data["sats"] = msg.satellites_visible

                        elif mtype == 'GLOBAL_POSITION_INT':
                            rel_alt = round(msg.relative_alt / 1000.0, 1)
                            if rel_alt != 0:
                                self.data["alt"] = rel_alt

                        if self.arm_start_ts:
                            self.data["arm_time"] = int(t_now - self.arm_start_ts)

            except Exception:
                time.sleep(0.5)

    def get(self):
        with self._lock:
            stale = (time.time() - self._ts) > 2.0
            d = dict(self.data)
            if stale:
                d["connected"] = False
            return d, stale


# ── WFB-NG LINK STATS THREAD ──────────────────────────────────────────────────
class WFBRx(threading.Thread):
    def __init__(self, log_path="/tmp/wfb_rx_video.log"):
        super().__init__(daemon=True)
        self.log_path = log_path
        self._lock = threading.Lock()
        self.running = True
        self.stats = {"rssi": -26, "lost": 0, "pps": 0}

    def run(self):
        while self.running:
            try:
                if os.path.exists(self.log_path):
                    with open(self.log_path, "r") as f:
                        lines = deque(f, maxlen=15)
                    for line in reversed(lines):
                        if "RX_ANT" in line:
                            parts = line.strip().split("\t")
                            if len(parts) >= 5:
                                sub = parts[4].split(":")
                                if len(sub) >= 4:
                                    try:
                                        rssi = int(sub[1])
                                        with self._lock:
                                            self.stats["rssi"] = rssi
                                        break
                                    except ValueError:
                                        pass
                        elif "PKT" in line:
                            parts = line.strip().split("\t")
                            if len(parts) >= 3:
                                sub = parts[2].split(":")
                                if len(sub) >= 10:
                                    try:
                                        pps = int(sub[9])
                                        with self._lock:
                                            self.stats["pps"] = pps
                                    except ValueError:
                                        pass
            except Exception:
                pass
            time.sleep(0.5)

    def get(self):
        with self._lock:
            return dict(self.stats)


# ── CRISP OSD TEXT WITH 1PX BLACK STROKE ──────────────────────────────────────
def draw_osd_text(surf, font, text, color, x, y, align="left"):
    """Renders pure OSD text with a clean 1px black outline halo around each character."""
    for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)]:
        s_surf = font.render(text, True, COLOR_BLACK)
        if align == "left":
            rx = x + dx
        elif align == "center":
            rx = x - s_surf.get_width() // 2 + dx
        else: # right
            rx = x - s_surf.get_width() + dx
        surf.blit(s_surf, (rx, y + dy))

    t_surf = font.render(text, True, color)
    if align == "left":
        rx = x
    elif align == "center":
        rx = x - t_surf.get_width() // 2
    else: # right
        rx = x - t_surf.get_width()
    surf.blit(t_surf, (rx, y))
    return t_surf.get_width(), t_surf.get_height()


# ── MINIMAL AIRCRAFT CENTER RETICLE ───────────────────────────────────────────
def draw_center_reticle(surf, cx, cy):
    """Subtle, professional aircraft center crosshair."""
    # Horizontal wings
    pygame.draw.line(surf, COLOR_BLACK, (cx - 18, cy), (cx - 6, cy), 3)
    pygame.draw.line(surf, COLOR_WHITE, (cx - 17, cy), (cx - 7, cy), 1)

    pygame.draw.line(surf, COLOR_BLACK, (cx + 6, cy), (cx + 18, cy), 3)
    pygame.draw.line(surf, COLOR_WHITE, (cx + 7, cy), (cx + 17, cy), 1)

    # Vertical ticks
    pygame.draw.line(surf, COLOR_BLACK, (cx, cy - 10), (cx, cy - 5), 3)
    pygame.draw.line(surf, COLOR_WHITE, (cx, cy - 9), (cx, cy - 6), 1)

    # Center reference point
    pygame.draw.circle(surf, COLOR_BLACK, (cx, cy), 3)
    pygame.draw.circle(surf, COLOR_WHITE, (cx, cy), 1)


def draw_openipc_level_bar(surf, cx, cy, roll, pitch, length=280):
    """
    Renders an authentic OpenIPC / Betaflight style 3-inch level horizon bar.
    - Moves vertically with pitch
    - Tilts with drone roll
    - Center notch gap for the fixed aircraft reference reticle
    """
    rad_roll = math.radians(-roll)
    cos_r = math.cos(rad_roll)
    sin_r = math.sin(rad_roll)

    pitch_px = max(-160, min(160, pitch * 2.5))

    half_len = length // 2
    center_gap = 26

    segments = [
        ((-half_len, pitch_px), (-center_gap, pitch_px)),
        ((center_gap, pitch_px), (half_len, pitch_px))
    ]

    for (x1, y1), (x2, y2) in segments:
        sx1 = int(cx + (x1 * cos_r - y1 * sin_r))
        sy1 = int(cy + (x1 * sin_r + y1 * cos_r))
        sx2 = int(cx + (x2 * cos_r - y2 * sin_r))
        sy2 = int(cy + (x2 * sin_r + y2 * cos_r))

        pygame.draw.line(surf, COLOR_BLACK, (sx1, sy1), (sx2, sy2), 3)
        pygame.draw.line(surf, COLOR_WHITE, (sx1, sy1), (sx2, sy2), 1)

    # End tick markers
    tick_len = 7
    for x_tip in [-half_len, half_len]:
        tx1 = int(cx + (x_tip * cos_r - pitch_px * sin_r))
        ty1 = int(cy + (x_tip * sin_r + pitch_px * cos_r))
        tx2 = int(cx + (x_tip * cos_r - (pitch_px + tick_len) * sin_r))
        ty2 = int(cy + (x_tip * sin_r + (pitch_px + tick_len) * cos_r))

        pygame.draw.line(surf, COLOR_BLACK, (tx1, ty1), (tx2, ty2), 3)
        pygame.draw.line(surf, COLOR_WHITE, (tx1, ty1), (tx2, ty2), 1)


def draw_rssi_widget(surf, x_right, y, rssi_val, font):
    """
    Clean FPV RSSI widget:
    - Small status indicator dot:
        * Green (>= -75 dBm): Strong / optimal link
        * Yellow (-76 to -84 dBm): Caution range
        * Red (<= -85 dBm): Fringe warning
    - 4-bar progressive signal meter in matching status color
    - Text: 'RSSI {rssi}dBm   1080p 30fps'
    """
    if rssi_val >= -75:
        stat_color = (0, 255, 136)       # Green (good)
    elif rssi_val >= -84:
        stat_color = (255, 235, 60)      # Yellow (caution)
    else:
        stat_color = (255, 65, 65)       # Red (critical)

    text_str = f"RSSI {rssi_val}dBm   720p 30fps"
    tw, th = font.size(text_str)

    text_x = x_right - tw
    text_y = y

    # Render RSSI text with 1px black outline
    draw_osd_text(surf, font, text_str, COLOR_WHITE, text_x, text_y, align="left")

    # 4-step vertical signal bar meter
    bar_w = 3
    bar_gap = 2
    bar_base_x = text_x - 24
    bar_base_y = y + th - 2

    bar_thresh = [-88, -80, -72, -60]
    bar_heights = [4, 7, 10, 13]

    for i in range(4):
        bx = bar_base_x + i * (bar_w + bar_gap)
        bh = bar_heights[i]
        by = bar_base_y - bh

        pygame.draw.rect(surf, COLOR_BLACK, (bx - 1, by - 1, bar_w + 2, bh + 2))
        if rssi_val >= bar_thresh[i]:
            pygame.draw.rect(surf, stat_color, (bx, by, bar_w, bh))
        else:
            pygame.draw.rect(surf, (80, 85, 95), (bx, by, bar_w, bh), 1)

    # Minor status indicator dot (shows pure status color)
    dot_x = bar_base_x - 10
    dot_y = bar_base_y - 6
    pygame.draw.circle(surf, COLOR_BLACK, (dot_x, dot_y), 4)
    pygame.draw.circle(surf, stat_color, (dot_x, dot_y), 3)


# ── MAIN APPLICATION ─────────────────────────────────────────────────────────
def main():
    pygame.init()
    pygame.font.init()
    pygame.display.set_caption("FPV HUD — 720p HD")

    WIN_W, WIN_H = 1280, 720
    screen = pygame.display.set_mode((WIN_W, WIN_H), pygame.RESIZABLE)

    # Clean, sharp font (prefer monospace or clean system font)
    font_name = None
    for name in ["ubuntumono", "dejavusansmono", "liberationmono", "consolas", "monospace", "ubuntu"]:
        if name in pygame.font.get_fonts():
            font_name = name
            break

    fnt_lg = pygame.font.SysFont(font_name, 24, bold=True)
    fnt_md = pygame.font.SysFont(font_name, 18, bold=True)
    fnt_sm = pygame.font.SysFont(font_name, 14, bold=True)

    # Background threads
    mav_rx = MAVLinkRx()
    mav_rx.start()

    wfb_rx = WFBRx()
    wfb_rx.start()

    # GStreamer: H.264 UDP -> 25ms Low-Latency Jitter Buffer -> Error Concealing Decoder -> appsink RGB
    gst_pipe = (
        f"udpsrc port={VIDEO_PORT} buffer-size=2097152 ! "
        "application/x-rtp,media=video,clock-rate=90000,encoding-name=H264 ! "
        "rtpjitterbuffer latency=25 drop-on-latency=false ! "
        "rtph264depay ! h264parse ! "
        "avdec_h264 discard-corrupted-frames=true output-corrupt=false max-threads=4 ! "
        "videoconvert ! video/x-raw,format=RGB ! "
        "appsink name=sink emit-signals=false sync=false drop=true max-buffers=1"
    )

    pipeline = Gst.parse_launch(gst_pipe)
    sink     = pipeline.get_by_name("sink")
    pipeline.set_state(Gst.State.PLAYING)

    clock           = pygame.time.Clock()
    osd_mode        = 0    # 0 = Full OSD, 1 = Minimal OSD, 2 = Clean Video
    fullscreen      = False
    prev_win_size   = (WIN_W, WIN_H)
    last_click_time = 0.0
    fs_btn_rect     = pygame.Rect(0, 0, 0, 0)
    raw_surf        = None
    running         = True

    print("[FPV] 720p HD OSD Online. [O/H] OSD Mode | [F] Fullscreen | [Q] Quit")

    while running:
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.VIDEORESIZE:
                if not fullscreen:
                    screen = pygame.display.set_mode((ev.w, ev.h), pygame.RESIZABLE)
            elif ev.type in (getattr(pygame, 'WINDOWRESIZED', -1), getattr(pygame, 'WINDOWSIZECHANGED', -1), getattr(pygame, 'WINDOWMAXIMIZED', -1), getattr(pygame, 'WINDOWRESTORED', -1)):
                if not fullscreen:
                    cur_sz = pygame.display.get_window_size()
                    if cur_sz != screen.get_size() and cur_sz[0] > 0 and cur_sz[1] > 0:
                        screen = pygame.display.set_mode(cur_sz, pygame.RESIZABLE)
            elif ev.type == pygame.KEYDOWN:
                if ev.key in (pygame.K_q, pygame.K_ESCAPE):
                    if fullscreen:
                        fullscreen = False
                        screen = pygame.display.set_mode(prev_win_size, pygame.RESIZABLE)
                    else:
                        running = False
                elif ev.key in (pygame.K_h, pygame.K_o):
                    osd_mode = (osd_mode + 1) % 3
                elif ev.key in (pygame.K_f, pygame.K_F11):
                    fullscreen = not fullscreen
                    if fullscreen:
                        prev_win_size = screen.get_size()
                        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
                    else:
                        screen = pygame.display.set_mode(prev_win_size, pygame.RESIZABLE)
            elif ev.type == pygame.MOUSEBUTTONDOWN:
                if ev.button == 1:
                    if fs_btn_rect.collidepoint(ev.pos):
                        fullscreen = not fullscreen
                        if fullscreen:
                            prev_win_size = screen.get_size()
                            screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
                        else:
                            screen = pygame.display.set_mode(prev_win_size, pygame.RESIZABLE)
                    else:
                        now = time.time()
                        if (now - last_click_time) < 0.35:
                            fullscreen = not fullscreen
                            if fullscreen:
                                prev_win_size = screen.get_size()
                                screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
                            else:
                                screen = pygame.display.set_mode(prev_win_size, pygame.RESIZABLE)
                            last_click_time = 0.0
                        else:
                            last_click_time = now

        # Dynamic window size synchronization safety check
        if not fullscreen:
            win_sz = pygame.display.get_window_size()
            if win_sz != screen.get_size() and win_sz[0] > 0 and win_sz[1] > 0:
                screen = pygame.display.set_mode(win_sz, pygame.RESIZABLE)

        W, H = screen.get_size()

        # Aspect-ratio-preserving fit to window (locks strict 16:9, auto-fills fullscreen)
        V_W, V_H = 1280, 720
        scale = min(W / V_W, H / V_H)
        draw_w = max(1, int(V_W * scale))
        draw_h = max(1, int(V_H * scale))
        vx = (W - draw_w) // 2
        vy = (H - draw_h) // 2

        # ── Drain to Latest Video Frame (Zero Accumulated Latency) ────
        sample = sink.try_pull_sample(0)
        if sample:
            while True:
                next_sample = sink.try_pull_sample(0)
                if next_sample is None:
                    break
                sample = next_sample
            buf  = sample.get_buffer()
            caps = sample.get_caps().get_structure(0)
            fw   = caps.get_value("width")
            fh   = caps.get_value("height")
            ok, mi = buf.map(Gst.MapFlags.READ)
            if ok:
                raw_surf = pygame.image.frombuffer(mi.data, (fw, fh), "RGB")
                buf.unmap(mi)


        # ── Render Base Video (Aspect-Fit Centered) ───────────────────
        screen.fill(COLOR_BLACK)
        if raw_surf:
            if (draw_w, draw_h) == (fw, fh):
                screen.blit(raw_surf, (vx, vy))
            else:
                scaled_surf = pygame.transform.scale(raw_surf, (draw_w, draw_h))
                screen.blit(scaled_surf, (vx, vy))
        else:
            draw_osd_text(screen, fnt_md, f"WAITING FOR 1080p VIDEO [UDP {VIDEO_PORT}]", COLOR_WHITE, vx + draw_w // 2, vy + draw_h // 2, align="center")

        # Telemetry snapshots
        mav_data, mav_stale = mav_rx.get()
        wfb_data            = wfb_rx.get()

        # ── CLEAN & MINIMAL OSD OVERLAY (LOCKED TO VIDEO VIEWPORT) ────
        if osd_mode < 2:
            # 1. TOP-LEFT: Flight Mode, Arm State & Timer
            mode_str  = mav_data["mode"] if not mav_stale else "DISARMED"
            armed     = mav_data["armed"] and not mav_stale
            arm_color = COLOR_LIGHT_YELLOW if armed else COLOR_WHITE
            arm_str   = "ARMED" if armed else "DISARMED"

            flight_sec = mav_data.get("arm_time", 0)
            timer_str  = f"{flight_sec // 60:02d}:{flight_sec % 60:02d}"

            draw_osd_text(screen, fnt_md, f"{mode_str}  {arm_str}  {timer_str}", arm_color, vx + 24, vy + 20)

            # 2. TOP-RIGHT: GPS Satellites & Status
            sats = mav_data["sats"]
            gps_str = f"{sats} SAT" if not mav_stale else "-- SAT"
            mav_status = "MAVLINK OK" if not mav_stale else "NO TELEM"
            top_right_str = f"{gps_str}   {mav_status}"
            draw_osd_text(screen, fnt_md, top_right_str, COLOR_WHITE, vx + draw_w - 24, vy + 20, align="right")

            # Top-Right Fullscreen Button
            fs_text = "[ WINDOWED ]" if fullscreen else "[ FULLSCREEN ]"
            fs_tw, fs_th = fnt_sm.size(fs_text)
            fs_x = vx + draw_w - 24
            fs_btn_rect = pygame.Rect(fs_x - fs_tw - 4, vy + 44, fs_tw + 8, fs_th + 6)
            draw_osd_text(screen, fnt_sm, fs_text, COLOR_DIM_WHITE, fs_x, vy + 46, align="right")

            # 3. MID-LEFT: Altitude & Vertical Climb Rate
            alt_val = mav_data["alt"]
            climb_v = mav_data["climb"]
            draw_osd_text(screen, fnt_lg, f"{alt_val:.1f} m", COLOR_WHITE, vx + 24, vy + draw_h // 2 - 20)
            if abs(climb_v) > 0.1:
                climb_color = COLOR_LIGHT_YELLOW if climb_v > 0 else COLOR_WHITE
                draw_osd_text(screen, fnt_sm, f"{climb_v:+.1f} m/s", climb_color, vx + 24, vy + draw_h // 2 + 10)

            # 4. MID-RIGHT: Speed & Throttle (Right-aligned)
            spd_val = mav_data["speed"]
            thr_val = mav_data["throttle"]
            draw_osd_text(screen, fnt_lg, f"{spd_val:.0f} km/h", COLOR_WHITE, vx + draw_w - 24, vy + draw_h // 2 - 20, align="right")
            draw_osd_text(screen, fnt_sm, f"{thr_val}% THR", COLOR_DIM_WHITE, vx + draw_w - 24, vy + draw_h // 2 + 10, align="right")

            # 5. BOTTOM-LEFT: Battery Voltage & Per-Cell
            v_bat = mav_data["voltage"]
            c_bat = mav_data["cell_volt"]
            v_color = COLOR_LIGHT_YELLOW if (c_bat < 3.6 and c_bat > 0) else COLOR_WHITE
            if c_bat > 0:
                bat_str = f"{v_bat:.1f}V   {c_bat:.2f}V/C"
            else:
                bat_str = f"{v_bat:.1f}V"
            draw_osd_text(screen, fnt_md, bat_str, v_color, vx + 24, vy + draw_h - 36)

            # 6. BOTTOM-RIGHT: RSSI Widget with Status Dot, 4-Bar Meter & dBm
            rssi_val = wfb_data["rssi"]
            draw_rssi_widget(screen, vx + draw_w - 24, vy + draw_h - 36, rssi_val, fnt_md)

            # 7. CENTER RETICLE & OPENIPC HORIZON LEVEL BAR (Full OSD only)
            if osd_mode == 0:
                bar_len = int(280 * min(1.5, max(0.8, draw_w / 1280.0)))
                draw_center_reticle(screen, vx + draw_w // 2, vy + draw_h // 2)
                draw_openipc_level_bar(screen, vx + draw_w // 2, vy + draw_h // 2, mav_data["roll"], mav_data["pitch"], length=bar_len)

        pygame.display.flip()
        clock.tick(60)

    pipeline.set_state(Gst.State.NULL)
    mav_rx.running = False
    wfb_rx.running = False
    pygame.quit()


if __name__ == "__main__":
    main()
