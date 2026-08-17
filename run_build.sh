#!/usr/bin/env bash
set -euo pipefail

# 1. Environment Configurations
TARGET_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
LOG_FILE="${TARGET_DIR}/fairydust_build.log"
REPO_URL="https://github.com/AsahiLinux/linux.git"
BRANCH="fairydust"

# Use all available virtual cloud cores
SAFE_JOBS=$(nproc)

# Redirect output to log file while streaming to terminal console
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== [1/5] Starting Cloud Fairydust Kernel Build: $(date) ==="

# 2. Workspace Setup
echo "=== [2/5] Cleaning workspace ==="
cd "$TARGET_DIR"
rm -rf linux dist

echo "=== [3/5] Shallow cloning ${BRANCH} branch ==="
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" linux
cd linux

# 3. Kernel Configuration Setup
echo "=== [4/5] Preparing kernel configuration ==="
make defconfig

# Verify Rust environment for Apple AGX GPU drivers
if ! make rustavailable; then
    echo "ERROR: Rust toolchain is not properly configured for kernel build!"
    exit 1
fi

# Enable DP Alt-Mode & Apple Silicon support
scripts/config --enable CONFIG_RUST
scripts/config --enable CONFIG_DRM_APPLE
scripts/config --enable CONFIG_TYPEC_APPLE
scripts/config --enable CONFIG_TYPEC_DP_ALTMODE
scripts/config --enable CONFIG_TYPEC_NVIDIA_ALTMODE
scripts/config --enable CONFIG_TYPEC_TBT_ALTMODE
make olddefconfig

# 4. Compilation Phase
echo "=== [5/5] Building kernel, modules, and DTBs using ${SAFE_JOBS} cores ==="
make KCFLAGS="-g0" -j"${SAFE_JOBS}" Image.gz modules dtbs

# 5. Package Artifacts
echo "Packaging build output..."
mkdir -p "${TARGET_DIR}/dist"
cp arch/arm64/boot/Image.gz "${TARGET_DIR}/dist/"
mkdir -p "${TARGET_DIR}/dist/dtbs"
cp arch/arm64/boot/dts/apple/*.dtb "${TARGET_DIR}/dist/dtbs/" 2>/dev/null || true

echo ""
echo "=========================================================================="
echo " SUCCESS: Fairydust cloud kernel build complete!                          "
echo " Build Finished: $(date)                                                  "
echo "=========================================================================="
