import time, os, subprocess

def get_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp') as f:
            return float(f.read().strip()) / 1000.0
    except:
        return 0.0

def get_npu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone2/temp') as f:
            return float(f.read().strip()) / 1000.0
    except:
        return 0.0

def get_regulator_summary():
    rails = {}
    try:
        out = subprocess.check_output(['sudo', 'cat', '/sys/kernel/debug/regulator/regulator_summary'], text=True)
        for line in out.splitlines():
            for name in ['usb1-vbus', 'axp8191-dcdc1', 'axp8191-dcdc2', 'axp8191-dcdc3', 'axp8191-dcdc8']:
                if name in line:
                    parts = line.split()
                    for p in parts:
                        if 'mV' in p:
                            rails[name] = p
                            break
    except Exception as e:
        pass
    return rails

print('=' * 50)
print(' Radxa Cubie A7S Power & Thermal Monitor')
print('=' * 50)
rails = get_regulator_summary()
for r, v in rails.items():
    print(f'  {r:<18} : {v}')
print(f'  CPU Temp           : {get_temp():.1f} °C')
print(f'  NPU Temp           : {get_npu_temp():.1f} °C')
print('=' * 50)
