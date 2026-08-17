#!/usr/bin/env bash
set -euo pipefail

# 1. Environment & Path Detection
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "--- Detected GitHub Actions Environment ---"
    TARGET_DIR="$GITHUB_WORKSPACE"
    # CI runners never sleep, so we bypass systemd-inhibit entirely
    IS_CI=true
else
    echo "--- Detected Local Machine Environment ---"
    TARGET_DIR="/mnt/SharedData2"
    IS_CI=false
fi

LOG_FILE="${TARGET_DIR}/fairydust_build.log"
SWAP_FILE="${TARGET_DIR}/swapfile"
REPO_URL="https://github.com"
BRANCH="fairydust"

# Redirect stdout and stderr to the log file while displaying it on screen
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== [1/6] Starting Fairydust Kernel Build: $(date) ==="

# 2. Local-Only Prep (Power management & System Hooks)
if [ "$IS_CI" = false ]; then
    # Kill local desktop idlers to prevent sleep interference
    pkill -x swayidle || true
    pkill -x niri || true
    sleep 2
fi

# 3. Swap Space Allocator (Only run if sudo privileges or real disks are present)
if [ "$IS_CI" = false ]; then
    echo "=== [2/6] Setting up emergency 4GB swap space ==="
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

    cleanup_swap() {
        echo "=== Cleaning up emergency swap ==="
        sudo swapoff "$SWAP_FILE" || true
    }
    trap cleanup_swap EXIT
else
    echo "=== [2/6] Skipping Swap allocation (Handled by GitHub Cloud VM) ==="
fi

# 4. Workspace Clean and Clone
echo "=== [3/6] Cleaning up old build directory ==="
cd "$TARGET_DIR"
if [ -d "linux" ]; then
    rm -rf linux
fi

echo "=== [4/6] Shallow cloning ${BRANCH} branch ==="
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" linux
cd linux

# 5. Kernel Configuration Setup
echo "=== [5/6] Preparing kernel configuration ==="
if [ "$IS_CI" = true ]; then
    # Use standard arm64 defconfig in the CI environment
    make defconfig
else
    # Use local host configuration on your local machine
    cp "/boot/config-$(uname -r)" .config
fi

# Enable DP Alt-Mode rules
scripts/config --enable CONFIG_TYPEC_DP_ALTMODE
scripts/config --enable CONFIG_TYPEC_NVIDIA_ALTMODE
scripts/config --enable CONFIG_TYPEC_TBT_ALTMODE
make olddefconfig

# 6. Safe Thread Compilation Strategy
if [ "$IS_CI" = true ]; then
    # On GitHub free tier runners, utilize all available cloud cores
    SAFE_JOBS=$(nproc)
    echo "=== [6/6] Launching Cloud compilation ==="
    make KCFLAGS="-g0" -j"${SAFE_JOBS}"
    make dtbs -j"${SAFE_JOBS}"
else
    # On local host machine, save 2 cores to keep the desktop responsive
    SAFE_JOBS=$(nproc --ignore=2)
    echo "=== [6/6] Launching Local inhibited compilation ==="
    
    # Internal compilation function to safely execute under systemd-inhibit
    compile_local() {
        nice -n 19 ionice -c 3 make KCFLAGS="-g0" -j"${SAFE_JOBS}"
        nice -n 19 ionice -c 3 make dtbs -j"${SAFE_JOBS}"
        
        sudo make modules_install
        sudo make dtbs_install
        sudo make install
        sudo depmod -a
        
        echo -e "typec_displayport\ntypec_thunderbolt" | sudo tee /etc/modules-load.d/fairydust.conf > /dev/null
    }

    # Run everything wrapped in systemd-inhibit to lock desktop state during build
    systemd-inhibit --what=idle:sleep:handle-lid-switch \
                    --who="KernelBuild" \
                    --why="Building Fairydust Kernel" \
                    bash -c "$(declare -f compile_local); compile_local"
fi

echo ""
echo "=========================================================================="
echo " SUCCESS: Fairydust kernel build operation complete!                      "
echo " Process Finished: $(date)                                               "
echo "=========================================================================="
