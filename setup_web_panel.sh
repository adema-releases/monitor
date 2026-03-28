#!/bin/bash
set -euo pipefail
# Adema Core - Web panel installer
# Repo oficial: https://github.com/adema-releases/adema-core

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
    apt-get install -y python3 python3-venv python3-pip sudo ufw
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
"$VENV_DIR/bin/pip" install flask flask-limiter waitress

if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status | head -n1 || true)
    if echo "$UFW_STATUS" | grep -qi "inactive"; then
        ufw allow OpenSSH >/dev/null 2>&1 || true
        ufw --force enable >/dev/null
    fi

    add_ufw_rule_if_missing() {
        local expected="$1"
        shift
        if ! ufw status | grep -Fq "$expected"; then
            ufw "$@" >/dev/null
        fi
    }

    remove_ufw_open_5432_anywhere() {
        local line_num
        while true; do
            line_num=$(ufw status numbered | awk '/5432\/tcp/ && /ALLOW IN/ && /Anywhere/ {gsub(/\[|\]/, "", $1); print $1; exit}')
            [ -n "$line_num" ] || break
            ufw --force delete "$line_num" >/dev/null
        done
    }

    remove_ufw_open_5432_anywhere

    add_ufw_rule_if_missing "5432/tcp                   ALLOW IN    10.0.0.0/8" allow from 10.0.0.0/8 to any port 5432 proto tcp
    add_ufw_rule_if_missing "5432/tcp                   ALLOW IN    172.16.0.0/12" allow from 172.16.0.0/12 to any port 5432 proto tcp
    add_ufw_rule_if_missing "5432/tcp                   ALLOW IN    192.168.0.0/16" allow from 192.168.0.0/16 to any port 5432 proto tcp
    add_ufw_rule_if_missing "5432/tcp                   DENY IN     Anywhere" deny in to any port 5432 proto tcp
fi

chown -R "$WEB_USER":"$WEB_GROUP" "$VENV_DIR"
chown "$WEB_USER":"$WEB_GROUP" "$ROOT_DIR/web_manager.py"
mkdir -p "$ROOT_DIR/.web_jobs"
chown -R "$WEB_USER":"$WEB_GROUP" "$ROOT_DIR/.web_jobs"

CREATE_SCRIPT="$ROOT_DIR/monitor/create_tenant.sh"
TEST_SCRIPT="$ROOT_DIR/monitor/test_tenant_db.sh"
BACKUP_SCRIPT="$ROOT_DIR/monitor/backup_project.sh"
STATUS_SCRIPT="$ROOT_DIR/monitor/status_snapshot.sh"
DELETE_SCRIPT="$ROOT_DIR/monitor/delete_tenant.sh"

cat > "$SUDOERS_FILE" <<EOF
# Adema Core Web Panel - sudoers (autogenerado)
# SOLO permite ejecutar scripts especificos como root.
# El wildcard (*) permite argumentos pero NO subcomandos.
Defaults:$WEB_USER !requiretty
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $STATUS_SCRIPT
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $CREATE_SCRIPT *
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $TEST_SCRIPT *
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $BACKUP_SCRIPT
$WEB_USER ALL=(root) NOPASSWD: /bin/bash $DELETE_SCRIPT *
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Adema Core - Web Control Panel
After=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_GROUP
WorkingDirectory=$ROOT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/waitress-serve --listen=0.0.0.0:$WEB_PORT web_manager:app
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
echo "Adema Core - Control Center instalado correctamente"
echo "Servicio: adema-web-panel.service"
echo "URL: ${PANEL_URL}"
echo "URL (acceso directo): ${PANEL_URL_WITH_TOKEN}"
echo "Token: ${PANEL_TOKEN}"
echo "=================================================="
