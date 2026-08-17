#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/mnt/SharedData2"
SWAP_FILE="${TARGET_DIR}/swapfile"
REPO_URL="https://github.com/AsahiLinux/linux.git"
BRANCH="fairydust"

# Automatically ignore 2 cores to keep system responsive
SAFE_JOBS=$(nproc --ignore=2)

echo "=== [1/6] Setting up emergency 4GB swap space ==="
if [ ! -f "$SWAP_FILE" ]; then
    echo "Creating 4GB swapfile..."
    sudo fallocate -l 4G "$SWAP_FILE" || sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096
    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
fi

if ! swapon --show | grep -q "$SWAP_FILE"; then
    echo "Activating emergency swap..."
    sudo swapon "$SWAP_FILE"
fi

# Ensure swap is cleanly turned off when script exits (even on error)
cleanup_swap() {
    echo "=== Cleaning up emergency swap ==="
    sudo swapoff "$SWAP_FILE" || true
}
trap cleanup_swap EXIT

echo "=== [2/6] Cleaning up old build directory ==="
cd "$TARGET_DIR"
if [ -d "linux" ]; then
    rm -rf linux
fi

echo "=== [3/6] Shallow cloning ${BRANCH} branch ==="
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" linux
cd linux

echo "=== [4/6] Preparing kernel configuration ==="
cp "/boot/config-$(uname -r)" .config

# Ensure DP Alt-Mode options are active in .config
scripts/config --enable CONFIG_TYPEC_DP_ALTMODE
scripts/config --enable CONFIG_TYPEC_NVIDIA_ALTMODE
scripts/config --enable CONFIG_TYPEC_TBT_ALTMODE

make olddefconfig

echo "=== [5/6] Launching safe compilation ==="
echo "Building kernel and DTBs using ${SAFE_JOBS} cores..."
nice -n 19 ionice -c 3 make KCFLAGS="-g0" -j"${SAFE_JOBS}"
nice -n 19 ionice -c 3 make dtbs -j"${SAFE_JOBS}"

echo "=== [6/6] Installing modules, DTBs, and kernel ==="
sudo make modules_install
sudo make dtbs_install
sudo make install
sudo depmod -a

# Automatically configure typec modules to load on boot
echo -e "typec_displayport\ntypec_thunderbolt" | sudo tee /etc/modules-load.d/fairydust.conf > /dev/null

echo ""
echo "=========================================================================="
echo " SUCCESS: Fairydust kernel build complete!                                "
echo " Reboot into the new kernel in GRUB to enable USB-C DisplayPort testing.  "
echo " (Note: Plug external monitor into the front-most USB-C port).            "
echo "=========================================================================="
