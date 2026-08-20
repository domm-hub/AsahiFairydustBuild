#!/usr/bin/env bash
set -euo pipefail

# 1. Environment Configurations
TARGET_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
LOG_FILE="${TARGET_DIR}/fairydust_build.log"
REPO_URL="https://github.com/AsahiLinux/linux.git"
BRANCH="fairydust"

SAFE_JOBS=$(nproc)
if [ "$SAFE_JOBS" -gt 4 ]; then SAFE_JOBS=4; fi
export MAKEFLAGS="-j${SAFE_JOBS}"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== Build environment ==="
uname -a
free -h || true
ulimit -a || true

echo "=== [1/6] Starting Cloud Fairydust Kernel Build: $(date) ==="

cd "$TARGET_DIR"
rm -rf linux dist

echo "=== [2/6] Shallow cloning ${BRANCH} branch ==="
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" linux
cd linux

echo "=== [3/6] Preparing kernel configuration ==="
make defconfig

if ! make rustavailable; then
    echo "ERROR: Rust toolchain is not properly configured for kernel build!"
    exit 1
fi

scripts/config --enable CONFIG_RUST
scripts/config --enable CONFIG_DRM_APPLE
scripts/config --enable CONFIG_TYPEC_APPLE
scripts/config --enable CONFIG_TYPEC_DP_ALTMODE
scripts/config --enable CONFIG_TYPEC_NVIDIA_ALTMODE
scripts/config --enable CONFIG_TYPEC_TBT_ALTMODE
scripts/config --enable CONFIG_APPLE_MAILBOX

make olddefconfig

echo "=== [4/6] Building kernel image ==="
if command -v ld.lld >/dev/null 2>&1; then
  echo "Using lld as the linker (ld.lld detected)."
  export LD=ld.lld
fi

make V=1 KCFLAGS="-g0" Image.gz || { echo "Image build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }

echo "=== [5/6] Building DTBs and modules ==="
make V=1 KCFLAGS="-g0" dtbs || { echo "DTB build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }
make V=1 KCFLAGS="-g0" modules || { echo "Modules build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }

make V=1 KCFLAGS="-g0" vmlinux || { echo "vmlinux link failed"; tail -n 400 "${LOG_FILE}"; exit 1; }

echo "=== [6/6] Packaging build output ==="
mkdir -p "${TARGET_DIR}/dist/dtbs"
mkdir -p "${TARGET_DIR}/dist/modules"

cp arch/arm64/boot/Image.gz "${TARGET_DIR}/dist/"
cp arch/arm64/boot/dts/apple/*.dtb "${TARGET_DIR}/dist/dtbs/" 2>/dev/null || true
cp vmlinux "${TARGET_DIR}/dist/" 2>/dev/null || true
cp System.map "${TARGET_DIR}/dist/" 2>/dev/null || true
cp .config "${TARGET_DIR}/dist/config" 2>/dev/null || true
cp "${LOG_FILE}" "${TARGET_DIR}/dist/" 2>/dev/null || true

# Stage modules under dist/modules/lib/modules/<kernel-release>/ for RPM packaging.
KERNEL_RELEASE=$(make -s kernelrelease)
echo "Kernel release: ${KERNEL_RELEASE}"
make modules_install INSTALL_MOD_PATH="${TARGET_DIR}/dist/modules"

echo "Build output staged under ${TARGET_DIR}/dist"

echo "=========================================================================="
echo " SUCCESS: Fairydust cloud kernel build complete!                          "
echo " Build Finished: $(date)                                                  "
echo "=========================================================================="
