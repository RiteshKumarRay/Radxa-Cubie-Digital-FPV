# RTL8812EU / BL-M8812EU2 Linux Driver Setup

This repository uses the RTL8812EU chipset (USB VID:PID `0bda:a81a`) in monitor mode with packet injection.

## Building the Driver

```bash
git clone https://github.com/morrownr/88x2eu-20210702.git rtl88x2eu
cd rtl88x2eu

# Install build essentials and kernel headers
sudo apt update
sudo apt install build-essential bc dkms linux-headers-$(uname -r)

# Compile and install via DKMS
sudo ./dkms-install.sh
```

## Recommended Driver Options (`/etc/modprobe.d/8812eu.conf`)

Copy `8812eu.conf` from this folder to `/etc/modprobe.d/8812eu.conf`:

```ini
options 8812eu rtw_power_mgnt=0 rtw_ips_mode=0 rtw_adaptivity_en=0 rtw_tx_pwr_lmt_enable=0 rtw_hwpdn_mode=0 rtw_tx_pwr_by_rate=0
```

### Explanation of Flags:
- `rtw_power_mgnt=0`: Disables driver power management (prevents packet stutter)
- `rtw_ips_mode=0`: Disables inactive power save
- `rtw_adaptivity_en=0`: Disables EDCCA carrier listen delay (ensures instant broadcast injection)
- `rtw_tx_pwr_lmt_enable=0`: Unlocks full transmit power (up to 20 dBm / 100mW)
- `rtw_hwpdn_mode=0`: Disables hardware power-down so the radio does not shut off during USB reconnections
