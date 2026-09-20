#!/bin/bash
# ==============================================================================
#  Generate WFB-ng Encryption Keys Pair
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if command -v wfb_keygen >/dev/null 2>&1; then
    KEYGEN_CMD="wfb_keygen"
elif [ -f "$SCRIPT_DIR/../wfb-ng/wfb_keygen" ]; then
    KEYGEN_CMD="$SCRIPT_DIR/../wfb-ng/wfb_keygen"
elif [ -f "$HOME/wfb-ng/wfb_keygen" ]; then
    KEYGEN_CMD="$HOME/wfb-ng/wfb_keygen"
else
    echo "[-] wfb_keygen utility not found in PATH or ~/wfb-ng!"
    echo "    Please compile WFB-ng first: make"
    exit 1
fi

echo "[*] Generating keypair..."
"$KEYGEN_CMD"

echo "[+] Keys generated in $SCRIPT_DIR:"
echo "    - drone.key -> Copy this to your Drone Air Unit (/home/<USER>/wfb-ng/drone.key)"
echo "    - gs.key    -> Copy this to your Ground Station (/home/<USER>/wfb-ng/gs.key)"
chmod 600 drone.key gs.key 2>/dev/null || true
