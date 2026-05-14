#!/bin/bash
set -euo pipefail

ROOT_DIR="${ADEMA_NODE_ROOT:-/opt/adema-node}"
WEB_USER="${ADEMA_WEB_USER:-adema}"
WEB_GROUP="${ADEMA_WEB_GROUP:-adema}"

if ! id -u "$WEB_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$WEB_USER"
fi

chown root:root "$ROOT_DIR" 2>/dev/null || true
find "$ROOT_DIR" -type f \( -name '*.sh' -o -name 'adema-node' -o -name 'web_manager.py' \) -exec chown root:root {} \; 2>/dev/null || true
find "$ROOT_DIR" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null || true
chmod 755 "$ROOT_DIR/adema-node" 2>/dev/null || true
chmod 644 "$ROOT_DIR/web_manager.py" 2>/dev/null || true

mkdir -p "$ROOT_DIR/.web_jobs" /etc/adema/tenants /var/log/adema-node
chown "$WEB_USER:$WEB_GROUP" "$ROOT_DIR/.web_jobs"
chmod 750 "$ROOT_DIR/.web_jobs"
chown root:root /etc/adema/tenants /var/log/adema-node
chmod 700 /etc/adema/tenants
chmod 750 /var/log/adema-node

if [ -f "$ROOT_DIR/monitor/.monitor.env" ]; then
    chown root:root "$ROOT_DIR/monitor/.monitor.env"
    chmod 640 "$ROOT_DIR/monitor/.monitor.env"
fi

echo "Permisos configurados: scripts root-owned, .web_jobs aislado para $WEB_USER."