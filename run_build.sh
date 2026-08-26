#!/usr/bin/env bash
set -euo pipefail

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

echo "=== [3/6] Preparing Asahi + Fairydust kernel configuration ==="

# Start from the normal ARM64 baseline, then merge the Asahi configuration
# shipped by the exact Fairydust kernel branch being built.
cp "${TARGET_DIR}/base.config" .config
make olddefconfig

if ! make rustavailable; then
    echo "ERROR: Rust toolchain is not properly configured for kernel build!"
    exit 1
fi

# Fairydust DisplayPort/Type-C configuration. Keep these on top of the
# upstream Asahi configuration so DP/DSC support is not lost when the base
# configuration changes.
scripts/config --enable CONFIG_RUST
scripts/config --enable CONFIG_DRM_APPLE
scripts/config --enable CONFIG_TYPEC
scripts/config --enable CONFIG_TYPEC_APPLE
scripts/config --enable CONFIG_TYPEC_DP_ALTMODE
scripts/config --enable CONFIG_TYPEC_NVIDIA_ALTMODE
scripts/config --enable CONFIG_TYPEC_TBT_ALTMODE
scripts/config --enable CONFIG_APPLE_MAILBOX
scripts/config --disable CONFIG_DEBUG_INFO_BTF

# CONFIG_DRM_APPLE_AUDIO can only be 'y' or 'n' in this Kconfig (Kconfig
# rejected 'm' with: "symbol value 'm' invalid for DRM_APPLE_AUDIO").
# It needs CONFIG_SND/CONFIG_SND_PCM/CONFIG_SND_TIMER built in (not modules)
# to link successfully, so force all of them to 'y' together.
scripts/config --enable CONFIG_SND
scripts/config --enable CONFIG_SND_PCM
scripts/config --enable CONFIG_SND_TIMER
scripts/config --enable CONFIG_DRM_APPLE_AUDIO

make olddefconfig

echo "=== Selected Asahi/Fairydust configuration ==="
CONFIG_CHECK_FAILED=0
for CONFIG in \
  CONFIG_ARCH_APPLE \
  CONFIG_DRM_ASAHI \
  CONFIG_DRM_APPLE \
  CONFIG_DRM_APPLE_AUDIO \
  CONFIG_DRM_ADP \
  CONFIG_PHY_APPLE_DPTX \
  CONFIG_MUX_APPLE_DPXBAR \
  CONFIG_TYPEC_APPLE \
  CONFIG_TYPEC_DP_ALTMODE \
  CONFIG_TYPEC_NVIDIA_ALTMODE \
  CONFIG_TYPEC_TBT_ALTMODE \
  CONFIG_USB_DWC3_APPLE \
  CONFIG_USB_XHCI_PCI_ASMEDIA \
  CONFIG_PCIE_APPLE \
  CONFIG_NVME_APPLE \
  CONFIG_BRCMFMAC \
  CONFIG_BT_HCIBCM4377 \
  CONFIG_HID_APPLE \
  CONFIG_HID_MAGICMOUSE; do
  if grep -qE "^(${CONFIG}=|# ${CONFIG} is not set)" .config; then
    grep -E "^(${CONFIG}=|# ${CONFIG} is not set)" .config
  else
    echo "WARNING: ${CONFIG} is not present"
    CONFIG_CHECK_FAILED=1
  fi
done

if [ "$CONFIG_CHECK_FAILED" -ne 0 ]; then
  echo "ERROR: one or more required configs are missing from .config (see WARNING lines above). Aborting before build."
  exit 1
fi

# Runs a make target with quiet, per-file compact output (CC/LD/AR/AS lines)
# instead of full V=1 command dumps, to keep log size down. A running count
# of processed files is printed so progress is still visible. Full detail
# is preserved in $LOG_FILE regardless, and the last N lines are dumped on
# failure by the caller.
run_make_quiet() {
  local target="$1"
  local count=0
  local start_ts
  start_ts=$(date +%s)

  set +e
  make KCFLAGS="-g0" "$target" 2>&1 | while IFS= read -r line; do
    echo "$line" >> "$LOG_FILE"
    if [[ "$line" =~ ^[[:space:]]*(CC|LD|AR|AS|CC\ \[M\]|LD\ \[M\])[[:space:]] ]]; then
      count=$((count + 1))
      if (( count % 25 == 0 )); then
        elapsed=$(( $(date +%s) - start_ts ))
        printf "  [%s] %d files processed (%ds elapsed)\n" "$target" "$count" "$elapsed"
      fi
    elif [[ "$line" =~ (error|Error|ERROR) ]]; then
      echo "$line"
    fi
  done
  local status=${PIPESTATUS[0]}
  set -e

  local total_elapsed=$(( $(date +%s) - start_ts ))
  printf "  [%s] done: %d files processed in %ds\n" "$target" "$count" "$total_elapsed"
  return "$status"
}

echo "=== [4/6] Building kernel image ==="
if command -v ld.lld >/dev/null 2>&1; then
  echo "Using lld as the linker (ld.lld detected)."
  export LD=ld.lld
fi

run_make_quiet Image.gz || { echo "Image build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }

echo "=== [5/6] Building DTBs and modules ==="
run_make_quiet dtbs || { echo "DTB build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }
run_make_quiet modules || { echo "Modules build failed"; tail -n 200 "${LOG_FILE}"; exit 1; }
run_make_quiet vmlinux || { echo "vmlinux link failed"; tail -n 400 "${LOG_FILE}"; exit 1; }

echo "=== [6/6] Packaging build output ==="
mkdir -p "${TARGET_DIR}/dist/dtbs"
mkdir -p "${TARGET_DIR}/dist/modules"

cp arch/arm64/boot/Image.gz "${TARGET_DIR}/dist/"
cp arch/arm64/boot/dts/apple/*.dtb "${TARGET_DIR}/dist/dtbs/" 2>/dev/null || true
cp vmlinux "${TARGET_DIR}/dist/" 2>/dev/null || true
cp System.map "${TARGET_DIR}/dist/" 2>/dev/null || true
cp .config "${TARGET_DIR}/dist/config" 2>/dev/null || true
cp "${LOG_FILE}" "${TARGET_DIR}/dist/" 2>/dev/null || true

KERNEL_RELEASE=$(make -s kernelrelease)
echo "Kernel release: ${KERNEL_RELEASE}"
make modules_install INSTALL_MOD_PATH="${TARGET_DIR}/dist/modules"

MODROOT="${TARGET_DIR}/dist/modules/lib/modules/${KERNEL_RELEASE}"
if [ ! -d "$MODROOT" ]; then
  echo "ERROR: module tree was not installed: $MODROOT"
  exit 1
fi

# These are generated by kbuild/modules_install and must be real files from
# this build, not placeholders.
for REQUIRED in modules.order modules.builtin modules.builtin.modinfo; do
  if [ ! -f "$MODROOT/$REQUIRED" ]; then
    echo "ERROR: missing required module metadata: $MODROOT/$REQUIRED"
    exit 1
  fi
done

KO_COUNT=$(find "$MODROOT/kernel" -type f -name '*.ko*' 2>/dev/null | wc -l)
if [ "$KO_COUNT" -eq 0 ]; then
  echo "ERROR: no kernel modules were installed under $MODROOT/kernel"
  exit 1
fi

# Generate dependency/alias metadata if available, matching a normal kernel
# module installation rather than shipping only modules.order/builtin files.
if command -v depmod >/dev/null 2>&1; then
  depmod -b "${TARGET_DIR}/dist/modules" -a "${KERNEL_RELEASE}"
fi

echo "Module tree: $MODROOT"
echo "Kernel modules installed: $KO_COUNT"
echo "Module metadata verified: modules.order modules.builtin modules.builtin.modinfo"

echo "Build output staged under ${TARGET_DIR}/dist"
echo "=========================================================================="
echo " SUCCESS: Fairydust cloud kernel build complete!                          "
echo " Build Finished: $(date)                                                  "
echo "=========================================================================="
