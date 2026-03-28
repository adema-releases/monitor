#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_USER="adema"
WEB_GROUP="adema"
WEB_PORT="${ADEMA_WEB_PORT:-5000}"
VENV_DIR="$ROOT_DIR/.venv_web_panel"
ENV_DIR="/etc/adema"
ENV_FILE="$ENV_DIR/web_panel.env"
SUDOERS_FILE="/etc/sudoers.d/adema-monitor-web"
SERVICE_FILE="/etc/systemd/system/adema-web-panel.service"

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta este instalador como root (sudo)."
    exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3 python3-venv python3-pip sudo
else
    echo "Error: este instalador soporta Debian/Ubuntu (apt-get)."
    exit 1
fi

if ! id -u "$WEB_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$WEB_USER"
fi

if ! id -nG "$WEB_USER" | grep -qw sudo; then
    usermod -aG sudo "$WEB_USER"
fi

mkdir -p "$ENV_DIR"

if [ ! -f "$ENV_FILE" ]; then
    TOKEN=$(openssl rand -hex 32)
    cat > "$ENV_FILE" <<EOF
ADEMA_WEB_TOKEN=$TOKEN
ADEMA_WEB_HOST=0.0.0.0
ADEMA_WEB_PORT=$WEB_PORT
ADEMA_MAX_JOBS=4
ADEMA_MIN_BACKUP_FREE_MB=500
ADEMA_ENV_FILE=$ENV_FILE
EOF
fi

chown root:"$WEB_GROUP" "$ENV_FILE"
chmod 640 "$ENV_FILE"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install flask

chown -R "$WEB_USER":"$WEB_GROUP" "$VENV_DIR"
chown "$WEB_USER":"$WEB_GROUP" "$ROOT_DIR/web_manager.py"
mkdir -p "$ROOT_DIR/.web_jobs"
chown -R "$WEB_USER":"$WEB_GROUP" "$ROOT_DIR/.web_jobs"

CREATE_SCRIPT="$ROOT_DIR/monitor/create_tenant.sh"
TEST_SCRIPT="$ROOT_DIR/monitor/test_tenant_db.sh"
BACKUP_SCRIPT="$ROOT_DIR/monitor/backup_project.sh"
STATUS_SCRIPT="$ROOT_DIR/monitor/status_snapshot.sh"

cat > "$SUDOERS_FILE" <<EOF
# Adema Monitor Web Panel - sudoers (autogenerado)
# SOLO permite ejecutar scripts especificos como root.
# El wildcard (*) permite argumentos pero NO subcomandos.
Defaults:$WEB_USER !requiretty
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $STATUS_SCRIPT
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $CREATE_SCRIPT *
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $TEST_SCRIPT *
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $BACKUP_SCRIPT
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Adema Web Control Panel
After=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_GROUP
WorkingDirectory=$ROOT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $ROOT_DIR/web_manager.py
Restart=on-failure
RestartSec=2
# Cambios de seguridad para permitir ejecucion en /home
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=$ROOT_DIR/.web_jobs

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now adema-web-panel.service

SERVER_IP=$(hostname -I | awk '{print $1}')
PANEL_TOKEN=$(grep '^ADEMA_WEB_TOKEN=' "$ENV_FILE" | cut -d'=' -f2-)
PANEL_URL="http://${SERVER_IP}:${WEB_PORT}/"
PANEL_URL_WITH_TOKEN="${PANEL_URL}?token=${PANEL_TOKEN}"

echo "=================================================="
echo "Adema Control Center instalado correctamente"
echo "Servicio: adema-web-panel.service"
echo "URL: ${PANEL_URL}"
echo "URL (acceso directo): ${PANEL_URL_WITH_TOKEN}"
echo "Token: ${PANEL_TOKEN}"
echo "=================================================="
