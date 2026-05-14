#!/bin/bash
set -euo pipefail

ROOT_DIR="${ADEMA_NODE_ROOT:-/opt/adema-node}"
PROJECT_CODE="${PROJECT_CODE:-adema}"
LOG_DIR="/var/log/adema-node"
CRON_FILE="/etc/cron.d/adema-node"

mkdir -p "$LOG_DIR"
cat > "$CRON_FILE" <<EOF
# ADEMA Node Lite - backups gestionados por bootstrap
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 2 * * * root cd $ROOT_DIR && /bin/bash $ROOT_DIR/monitor/backup_project.sh >> $LOG_DIR/backup_project.log 2>&1
EOF
chmod 644 "$CRON_FILE"
echo "Cron de backup instalado: $CRON_FILE"