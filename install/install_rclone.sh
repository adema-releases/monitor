#!/bin/bash
set -euo pipefail

if command -v rclone >/dev/null 2>&1; then
    echo "rclone ya esta instalado."
    exit 0
fi

apt-get update
apt-get install -y rclone
echo "rclone instalado. Configura el remote con: sudo rclone config --config /root/.config/rclone/rclone.conf"