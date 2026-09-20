#!/usr/bin/env python3
"""
High-Performance Dynamic MAVLink Bridge for ArduPilot FC on Radxa
Supports:
- Serial: /dev/ttyACM0 (auto-reconnect)
- TCP Server on port 5760 (Standard Mission Planner TCP)
- UDP Server on port 14550 (Standard Mission Planner UDP)
- Automatic dynamic subnet broadcast discovery + unicast forwarding
"""

import os
import sys
import time
import socket
import select
import serial
import subprocess

SERIAL_PORT = "/dev/ttyACM0"
BAUDRATE = 115200
TCP_PORT = 5760
UDP_PORT = 14550

def get_broadcast_addresses():
    broadcasts = set()
    broadcasts.add("255.255.255.255")
    try:
        out = subprocess.check_output(["ip", "-4", "addr", "show"]).decode()
        for line in out.splitlines():
            line = line.strip()
            if "brd" in line:
                parts = line.split()
                if "brd" in parts:
                    idx = parts.index("brd")
                    if idx + 1 < len(parts):
                        broadcasts.add(parts[idx + 1])
    except Exception as e:
        print(f"[-] Error detecting broadcast: {e}")
    return broadcasts

def open_serial():
    while True:
        try:
            if os.path.exists(SERIAL_PORT):
                ser = serial.Serial(SERIAL_PORT, BAUDRATE, timeout=0)
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                print(f"[+] Connected to serial port {SERIAL_PORT} @ {BAUDRATE}")
                return ser
        except Exception as e:
            print(f"[-] Waiting for serial {SERIAL_PORT}: {e}")
        time.sleep(2)

def run_bridge():
    # TCP Server
    tcp_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_server.bind(("0.0.0.0", TCP_PORT))
    tcp_server.listen(5)
    tcp_server.setblocking(False)
    print(f"[+] TCP server listening on 0.0.0.0:{TCP_PORT}")

    # UDP Server
    udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    udp_socket.bind(("0.0.0.0", UDP_PORT))
    udp_socket.setblocking(False)
    print(f"[+] UDP server listening on 0.0.0.0:{UDP_PORT}")

    active_tcp_clients = []
    
    # Initialize UDP targets with current known client and all detected broadcasts
    known_targets = set()
    known_targets.add(("10.107.1.198", UDP_PORT))
    for brd in get_broadcast_addresses():
        known_targets.add((brd, UDP_PORT))
        print(f"[+] Added broadcast target: {brd}:{UDP_PORT}")

    ser = open_serial()
    print("[+] Bridge active. Ready for Mission Planner connection via TCP:5760 or UDP:14550")

    last_broadcast_scan = time.time()

    while True:
        try:
            # Periodically re-scan broadcasts in case network changed
            if time.time() - last_broadcast_scan > 30.0:
                last_broadcast_scan = time.time()
                for brd in get_broadcast_addresses():
                    known_targets.add((brd, UDP_PORT))

            # Check serial connection
            if ser is None or not ser.is_open:
                ser = open_serial()

            rlist = [tcp_server, udp_socket]
            if ser:
                rlist.append(ser)
            rlist.extend(active_tcp_clients)

            readable, _, exceptional = select.select(rlist, [], rlist, 0.05)

            for s in exceptional:
                if s in active_tcp_clients:
                    active_tcp_clients.remove(s)
                    try:
                        s.close()
                    except:
                        pass

            for s in readable:
                if s is tcp_server:
                    client_sock, client_addr = tcp_server.accept()
                    client_sock.setblocking(False)
                    active_tcp_clients.append(client_sock)
                    print(f"[+] New TCP Client connected: {client_addr}")

                elif s is udp_socket:
                    try:
                        data, addr = udp_socket.recvfrom(4096)
                        if addr not in known_targets:
                            known_targets.add(addr)
                            print(f"[+] New UDP Client registered: {addr}")
                        if ser and data:
                            ser.write(data)
                    except Exception:
                        pass

                elif s is ser:
                    try:
                        data = ser.read(ser.in_waiting or 1024)
                        if not data:
                            continue

                        # Forward to all TCP clients
                        dead_clients = []
                        for client in active_tcp_clients:
                            try:
                                client.sendall(data)
                            except Exception:
                                dead_clients.append(client)
                        for d in dead_clients:
                            active_tcp_clients.remove(d)
                            try:
                                d.close()
                            except:
                                pass
                            print("[-] TCP Client disconnected")

                        # Forward to all UDP targets
                        for target in list(known_targets):
                            try:
                                udp_socket.sendto(data, target)
                            except Exception:
                                pass

                    except Exception as e:
                        print(f"[-] Serial read error: {e}")
                        try:
                            ser.close()
                        except:
                            pass
                        ser = None

                elif s in active_tcp_clients:
                    try:
                        data = s.recv(4096)
                        if data:
                            if ser:
                                ser.write(data)
                        else:
                            active_tcp_clients.remove(s)
                            s.close()
                            print("[-] TCP Client disconnected")
                    except Exception:
                        if s in active_tcp_clients:
                            active_tcp_clients.remove(s)
                            try:
                                s.close()
                            except:
                                pass
                            print("[-] TCP Client error/disconnected")

        except KeyboardInterrupt:
            print("[*] Exiting bridge...")
            break
        except Exception as e:
            print(f"[-] Bridge loop error: {e}")
            time.sleep(1)

    if ser:
        ser.close()
    tcp_server.close()
    udp_socket.close()

if __name__ == "__main__":
    run_bridge()
