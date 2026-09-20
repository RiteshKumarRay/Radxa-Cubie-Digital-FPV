#!/usr/bin/env python3
import sys
import time
import json
from pymavlink import mavutil

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else '/dev/ttyACM0'
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
    print(f"[*] Connecting to {port} @ {baud} baud...")
    try:
        mav = mavutil.mavlink_connection(port, baud=baud)
    except Exception as e:
        print(f"[-] Error opening serial port {port}: {e}")
        return

    print("[*] Waiting for heartbeat...")
    hb = mav.wait_heartbeat(timeout=10)
    if not hb:
        print("[-] No heartbeat received from flight controller.")
        return

    print(f"[+] Heartbeat received from System {mav.target_system}, Component {mav.target_component}!")
    print(f"    Autopilot: {mavutil.mavlink.enums['MAV_AUTOPILOT'][hb.autopilot].name}")
    print(f"    Type: {mavutil.mavlink.enums['MAV_TYPE'][hb.type].name}")
    print(f"    System Status: {mavutil.mavlink.enums['MAV_STATE'][hb.system_status].name}")

    # Request data streams
    mav.mav.request_data_stream_send(
        mav.target_system, mav.target_component,
        mavutil.mavlink.MAV_DATA_STREAM_ALL, 4, 1
    )

    # Request autopilot version
    mav.mav.command_long_send(
        mav.target_system, mav.target_component,
        mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE,
        0,
        mavutil.mavlink.MAVLINK_MSG_ID_AUTOPILOT_VERSION,
        0, 0, 0, 0, 0, 0
    )

    # Request specific parameters
    params_to_read = [
        "INS_ACC_ID", "INS_GYR_ID", "INS_ACC2_ID", "INS_GYR2_ID",
        "BARO1_DEVID", "BARO2_DEVID", "BARO_PRIMARY",
        "COMPASS_DEV_ID", "COMPASS_DEV_ID2", "COMPASS_DEV_ID3",
        "FRAME_CLASS", "SYSID_THISMAV", "BATT_MONITOR"
    ]
    
    for p in params_to_read:
        mav.mav.param_request_read_send(
            mav.target_system, mav.target_component,
            p.encode('utf-8'), -1
        )

    sensors = {
        "heartbeat": {
            "autopilot": mavutil.mavlink.enums['MAV_AUTOPILOT'][hb.autopilot].name,
            "type": mavutil.mavlink.enums['MAV_TYPE'][hb.type].name,
            "base_mode": hb.base_mode,
            "system_status": mavutil.mavlink.enums['MAV_STATE'][hb.system_status].name
        },
        "autopilot_version": {},
        "sys_status": {},
        "imu": {},
        "pressure": {},
        "attitude": {},
        "gps": {},
        "battery": {},
        "parameters": {},
        "statustext": []
    }

    start = time.time()
    while time.time() - start < 6.0:
        msg = mav.recv_match(blocking=True, timeout=1.0)
        if not msg:
            continue
        mtype = msg.get_type()

        if mtype == "STATUSTEXT":
            text = msg.text
            if text not in sensors["statustext"]:
                sensors["statustext"].append(text)
                print(f"    [STATUSTEXT] {text}")

        elif mtype == "AUTOPILOT_VERSION":
            flight_sw = f"{msg.flight_sw_version >> 24}.{(msg.flight_sw_version >> 16) & 0xFF}.{(msg.flight_sw_version >> 8) & 0xFF}"
            sensors["autopilot_version"] = {
                "flight_sw_version": flight_sw,
                "os_sw_version": msg.os_sw_version,
                "board_version": msg.board_version,
                "flight_custom_version": bytes(msg.flight_custom_version).decode('ascii', errors='ignore').strip('\x00')
            }

        elif mtype == "PARAM_VALUE":
            param_id = msg.param_id
            if isinstance(param_id, bytes):
                param_id = param_id.decode('utf-8', errors='ignore').rstrip('\x00')
            sensors["parameters"][param_id] = msg.param_value

        elif mtype == "SYS_STATUS":
            sensors["sys_status"] = {
                "sensors_present": hex(msg.onboard_control_sensors_present),
                "sensors_enabled": hex(msg.onboard_control_sensors_enabled),
                "sensors_health": hex(msg.onboard_control_sensors_health),
                "voltage_battery_mv": msg.voltage_battery,
                "current_battery_ca": msg.current_battery,
                "load": msg.load / 10.0,
                "drop_rate_comm": msg.drop_rate_comm
            }

        elif mtype in ["RAW_IMU", "HIGHRES_IMU", "SCALED_IMU"]:
            sensors["imu"][mtype] = msg.to_dict()

        elif mtype in ["SCALED_PRESSURE", "SCALED_PRESSURE2"]:
            sensors["pressure"][mtype] = msg.to_dict()

        elif mtype == "ATTITUDE":
            sensors["attitude"] = {
                "roll_deg": round(msg.roll * 57.2958, 2),
                "pitch_deg": round(msg.pitch * 57.2958, 2),
                "yaw_deg": round(msg.yaw * 57.2958, 2),
                "rollspeed": round(msg.rollspeed, 4),
                "pitchspeed": round(msg.pitchspeed, 4),
                "yawspeed": round(msg.yawspeed, 4)
            }

        elif mtype == "GPS_RAW_INT":
            sensors["gps"] = {
                "fix_type": msg.fix_type,
                "lat": msg.lat / 1e7,
                "lon": msg.lon / 1e7,
                "alt_m": msg.alt / 1000.0,
                "satellites_visible": msg.satellites_visible
            }

        elif mtype == "BATTERY_STATUS":
            sensors["battery"] = msg.to_dict()

    print("\n" + "="*50)
    print("SENSOR AND TELEMETRY REPORT SUMMARY:")
    print("="*50)
    print(json.dumps(sensors, indent=2))

if __name__ == "__main__":
    main()
