#!/usr/bin/env bash
set -euo pipefail

# Log output directory
LOG_FILE="/mnt/SharedData2/fairydust_build.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== Starting Fairydust Kernel Build Prep: $(date) ==="

# Kill swayidle and niri if they are currently running
pkill -x swayidle || true
pkill -x niri || true

sleep 2

# Inhibit sleep, idle, and lid close events for the duration of the build script
systemd-inhibit --what=idle:sleep:handle-lid-switch \
                --who="KernelBuild" \
                --why="Building Fairydust Kernel Overnight" \
                /mnt/SharedData2/build.sh

echo "=== Build Process Finished: $(date) ==="
