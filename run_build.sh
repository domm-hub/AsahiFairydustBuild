#!/usr/bin/env bash
set -euo pipefail

# 1. Environment Configurations
TARGET_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
LOG_FILE="${TARGET_DIR}/fairydust_build.log"
REPO_URL="https://github.com/AsahiLinux/linux.git"
BRANCH="fairydust"

# Use available virtual cloud cores but cap to avoid OOM during linking
SAFE_JOBS=$(nproc)
if [ "$SAFE_JOBS" -gt 4 ]; then
  SAFE_JOBS=4
fi

# Export MAKEFLAGS so recursive makes respect the cap
export MAKEFLAGS="-j${SAFE_JOBS}"

# Redirect output to log file while streaming to terminal console
exec > >(tee -a "${LOG_FILE}") 2>&1

# Helpful diagnostics
echo "=== Build environment ==="
uname -a
free -h || true
ulimit -a || true

echo "=== [1/6] Starting Cloud Fairydust Kernel Build: $(date) ==="

# 2. Workspace Setup
echo "=== [2/6] Cleaning workspace ==="
cd "$TARGET_DIR"
rm -rf linux dist

echo "=== [3/6] Shallow cloning ${BRANCH} branch ==="
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" linux
cd linux

# 3. Kernel Configuration Setup
echo "=== [4/6] Preparing kernel configuration ==="
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

# Enable Apple mailbox driver (required dependency for apple_rtkit)
scripts/config --enable CONFIG_APPLE_MAILBOX

make olddefconfig

# 4. Compilation Phase (split steps, verbose linking and use lld if available)
echo "=== [5/6] Building kernel image ==="
# Ensure lld is preferred if installed
if command -v ld.lld >/dev/null 2>&1; then
  echo "Using lld as the linker (ld.lld detected)."
  export LD=ld.lld
fi

# Build Image.gz first, then dtbs, then modules to reduce peak memory usage
make V=1 KCFLAGS="-g0" Image.gz || { echo "Image build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }

echo "=== [6/6] Building DTBs and modules ==="
make V=1 KCFLAGS="-g0" dtbs || { echo "DTB build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }
make V=1 KCFLAGS="-g0" modules || { echo "Modules build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }

# Link vmlinux separately (verbose) to capture linker errors clearly
make V=1 KCFLAGS="-g0" vmlinux || { echo "vmlinux link failed"; tail -n 400 "${LOG_FILE}"; exit 1; }

# 5. Package Artifacts
echo "Packaging build output..."
mkdir -p "${TARGET_DIR}/dist"
cp arch/arm64/boot/Image.gz "${TARGET_DIR}/dist/"
mkdir -p "${TARGET_DIR}/dist/dtbs"
cp arch/arm64/boot/dts/apple/*.dtb "${TARGET_DIR}/dist/dtbs/" 2>/dev/null || true

# Also collect the unstripped vmlinux for diagnostics
cp vmlinux "${TARGET_DIR}/dist/" 2>/dev/null || true

# 6. Success
echo ""
echo "=========================================================================="
echo " SUCCESS: Fairydust cloud kernel build complete!                          "
echo " Build Finished: $(date)                                                  "
echo "=========================================================================="
