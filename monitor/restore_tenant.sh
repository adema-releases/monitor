#!/bin/bash
set -euo pipefail
# Uso: sudo ./restore_tenant.sh [CLIENT_ID] [YYYY-MM-DD] [archivo.sql.gz]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="${1:-}"
FECHA="${2:-}"
FILE_NAME="${3:-}"

if [ -z "$CLIENT_ID" ]; then
    read -r -p "Ingrese CLIENT_ID (ej: cli005): " CLIENT_ID
fi
if [ -z "$FECHA" ]; then
    read -r -p "Ingrese fecha backup (YYYY-MM-DD): " FECHA
fi
if [ -z "$FILE_NAME" ]; then
    read -r -p "Ingrese archivo .sql.gz: " FILE_NAME
fi

if ! ensure_client_id "$CLIENT_ID"; then
    exit 1
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
PREFIX=$(volume_namespace "$CLIENT_ID")
REMOTE_PATH="$BACKUP_REMOTE/databases/${FECHA}/${FILE_NAME}"

echo "Verificando backup remoto..."
if ! rclone ls "$REMOTE_PATH" > /dev/null 2>&1; then
    echo "Error: el archivo no existe en la ruta remota indicada."
    exit 1
fi

echo "Descargando backup logico..."
rclone copy "$REMOTE_PATH" /tmp/ --progress
gunzip -f "/tmp/${FILE_NAME}"
SQL_FILE="/tmp/${FILE_NAME%.gz}"

echo "Restaurando base de datos $DB_NAME..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
sudo -u postgres psql "$DB_NAME" < "$SQL_FILE"

echo "Sincronizando volumenes persistentes..."
for folder in $VOLUME_FOLDERS; do
    rclone sync "$BACKUP_REMOTE/volumes/${PREFIX}_${folder}/" "$VOLUME_BASE_PATH/${PREFIX}_${folder}/" --progress
    sudo chown -R 1000:1000 "$VOLUME_BASE_PATH/${PREFIX}_${folder}"
done

rm -f "$SQL_FILE"
echo "Restauracion completada para $CLIENT_ID"