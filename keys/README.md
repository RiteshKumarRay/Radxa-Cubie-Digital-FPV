# WFB-ng Encryption Keys

WFB-ng uses libsodium / Curve25519 asymmetric public-private key cryptography for stream encryption.

## Files
- `drone.key`: Placed on the Air Unit (`/home/radxa/wfb-ng/drone.key`)
- `gs.key`: Placed on the Ground Control Station (`/home/ritesh/wfb-ng/gs.key`)

## Generating New Keys
To generate a new, unique key pair for your drone and ground station:

```bash
# On either machine:
wfb_keygen

# This generates two files in the current directory:
#   drone.key
#   gs.key
```

Copy `drone.key` to the drone Air Unit and `gs.key` to the Ground Station laptop.

> [!CAUTION]
> Never share your private keys publicly if you want to keep your video stream and telemetry encrypted.
