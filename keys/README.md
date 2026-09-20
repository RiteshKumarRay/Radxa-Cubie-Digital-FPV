# WFB-ng Encryption Keys

WFB-ng uses libsodium / Curve25519 asymmetric public-private key cryptography for stream encryption.

## Files
- `drone.key`: Placed on the Air Unit (`/home/<DRONE_USER>/wfb-ng/drone.key`)
- `gs.key`: Placed on the Ground Control Station (`/home/<GCS_USER>/wfb-ng/gs.key`)
- `*.sample`: Sample keypair templates

## Generating New Keys
You can run the included helper script:

```bash
cd keys/
./generate_keys.sh
```

Or manually using the `wfb_keygen` utility:

```bash
wfb_keygen
# Generates drone.key and gs.key in the current directory
```

Copy `drone.key` to the drone Air Unit and `gs.key` to the Ground Station.

> [!CAUTION]
> Never share your private keys publicly if you want to keep your video stream and telemetry encrypted.
