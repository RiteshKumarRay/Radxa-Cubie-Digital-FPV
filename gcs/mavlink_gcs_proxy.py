#!/usr/bin/env python3
"""
Zero-config bidirectional MAVLink proxy for QGroundControl + WFB-ng.
- Listens on 127.0.0.1:14552 for WFB-ng downlink packets (from wfb_rx)
  and forwards them to 127.0.0.1:14550 (QGroundControl).
- Because packets to QGC originate from 127.0.0.1:14552, QGC sends all
  its replies (heartbeats, commands, parameter queries) back to 14552.
- Any packet arriving from QGC (port 14550) is immediately forwarded
  to 127.0.0.1:14555 (wfb_tx uplink to drone).
"""
import socket
import sys

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(('127.0.0.1', 14552))
    except Exception as e:
        sys.stderr.write(f"Proxy bind failed on 14552: {e}\n")
        sys.exit(1)

    tx_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    qgc_addr = ('127.0.0.1', 14550)
    fpv_addr = ('127.0.0.1', 14551)
    wfb_tx_addr = ('127.0.0.1', 14555)

    while True:
        try:
            data, addr = sock.recvfrom(4096)
            if not data:
                continue
            if addr[1] == 14550:
                # Packet from QGC -> send to wfb_tx uplink
                tx_sock.sendto(data, wfb_tx_addr)
            else:
                # Packet from wfb_rx -> forward to QGC & FPV HUD
                try:
                    tx_sock.sendto(data, qgc_addr)
                except Exception:
                    pass
                try:
                    tx_sock.sendto(data, fpv_addr)
                except Exception:
                    pass
        except Exception:
            pass

if __name__ == "__main__":
    main()
