#!/bin/bash
set -euo pipefail

ENV_FILE="${ADEMA_ENV_FILE:-/etc/adema/web_panel.env}"
SERVICE_NAME="${ADEMA_WEB_SERVICE_NAME:-adema-web-panel.service}"
NEW_TOKEN="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$ROOT_DIR/monitor/lib/common.sh" ]; then
    # shellcheck source=/dev/null
    . "$ROOT_DIR/monitor/lib/common.sh"
    load_monitor_env || true
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta con sudo para actualizar $ENV_FILE y reiniciar $SERVICE_NAME."
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: no existe $ENV_FILE"
    exit 1
fi

if [ -z "$NEW_TOKEN" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
        echo "Error: openssl no esta instalado."
        exit 1
    fi
    NEW_TOKEN="$(openssl rand -hex 32)"
fi

if [ "${#NEW_TOKEN}" -lt 32 ]; then
    echo "Error: el token debe tener al menos 32 caracteres."
    exit 1
fi

if echo "$NEW_TOKEN" | grep -q '[[:space:]]'; then
    echo "Error: el token no puede contener espacios."
    exit 1
fi

BACKUP_FILE="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$ENV_FILE" "$BACKUP_FILE"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v token="$NEW_TOKEN" '
BEGIN { updated = 0 }
/^ADEMA_WEB_TOKEN=/ {
    print "ADEMA_WEB_TOKEN=" token
    updated = 1
    next
}
{ print }
END {
    if (!updated) {
        print "ADEMA_WEB_TOKEN=" token
    }
}
' "$ENV_FILE" > "$tmp_file"

chmod --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || true
chown --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || true
mv "$tmp_file" "$ENV_FILE"

systemctl restart "$SERVICE_NAME"
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Error: $SERVICE_NAME no quedo activo despues del reinicio."
    echo "Puedes restaurar el backup con: cp -a $BACKUP_FILE $ENV_FILE"
    exit 1
fi

if declare -F audit_event >/dev/null 2>&1; then
    audit_event "rotate_token" "" "success" "service=$SERVICE_NAME env_file=$ENV_FILE"
fi

WEB_HOST="$(grep '^ADEMA_WEB_HOST=' "$ENV_FILE" | cut -d'=' -f2- || true)"
WEB_PORT="$(grep '^ADEMA_WEB_PORT=' "$ENV_FILE" | cut -d'=' -f2- || true)"
WEB_PORT="${WEB_PORT:-5000}"

if [ -z "$WEB_HOST" ] || [ "$WEB_HOST" = "0.0.0.0" ]; then
    WEB_HOST="$(hostname -I | awk '{print $1}')"
fi

echo "=================================================="
echo "Token regenerado correctamente"
echo "Servicio reiniciado: $SERVICE_NAME"
echo "Backup env: $BACKUP_FILE"
echo "Nuevo token: $NEW_TOKEN"
echo "URL: http://${WEB_HOST}:${WEB_PORT}/"
echo "Acceso recomendado: abrir la URL y pegar el token en el login"
echo "API: Authorization: Bearer <token> o X-ADEMA-TOKEN: <token>"
echo "=================================================="
