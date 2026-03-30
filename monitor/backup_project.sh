#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone no esta instalado o no esta en PATH."
    exit 1
fi

resolve_rclone_config() {
    if [ -n "${RCLONE_CONFIG:-}" ] && [ -f "$RCLONE_CONFIG" ]; then
        return 0
    fi

    if [ -f "/root/.config/rclone/rclone.conf" ]; then
        RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
        export RCLONE_CONFIG
        return 0
    fi

    local invoking_user="${SUDO_USER:-}"
    if [ -n "$invoking_user" ]; then
        local user_home
        user_home=$(getent passwd "$invoking_user" | cut -d: -f6)
        if [ -n "$user_home" ] && [ -f "$user_home/.config/rclone/rclone.conf" ]; then
            RCLONE_CONFIG="$user_home/.config/rclone/rclone.conf"
            export RCLONE_CONFIG
            return 0
        fi
    fi

    return 1
}

REMOTE_NAME="${BACKUP_REMOTE%%:*}"
if [ -z "$REMOTE_NAME" ] || [ "$REMOTE_NAME" = "$BACKUP_REMOTE" ]; then
    echo "ERROR: BACKUP_REMOTE invalido: '$BACKUP_REMOTE'. Debe tener formato remote:ruta"
    exit 1
fi

if ! resolve_rclone_config; then
    echo "ERROR: No se encontro rclone.conf."
    echo "Configura RCLONE_CONFIG en monitor/.monitor.env con la ruta correcta del archivo."
    exit 1
fi

if ! rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -Fxq "$REMOTE_NAME:"; then
    echo "ERROR: El remote '$REMOTE_NAME' no existe en $RCLONE_CONFIG"
    echo "Ejecuta: rclone config --config $RCLONE_CONFIG"
    exit 1
fi

# Verificar espacio en disco antes de continuar
MIN_FREE_MB="${ADEMA_MIN_BACKUP_FREE_MB:-500}"
mkdir -p "$BACKUP_DIR"
AVAIL_KB=$(df --output=avail "$BACKUP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo "0")
AVAIL_MB=$((AVAIL_KB / 1024))
if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
    echo "ERROR: Espacio insuficiente en $BACKUP_DIR (${AVAIL_MB}MB libres, minimo ${MIN_FREE_MB}MB)."
    exit 1
fi

DATE_FOLDER=$(date +%Y-%m-%d)
DATE_FILE=$(date +%H-%M)

echo "Iniciando backup de bases de datos para $PROJECT_CODE..."

DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE '${DB_NAME_PREFIX}_%';")

for DB in $DATABASES; do
    echo "Respaldando: $DB"
    FILENAME="${DB}_${DATE_FOLDER}_${DATE_FILE}.sql.gz"
    sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_DIR/$FILENAME"
    cp "$BACKUP_DIR/$FILENAME" "$BACKUP_DIR/${DB}_latest.sql.gz"
done

echo "Sincronizando bases a remoto: $BACKUP_REMOTE"
rclone copy "$BACKUP_DIR" "$BACKUP_REMOTE/databases/$DATE_FOLDER" --progress --filter "- *_latest.sql.gz" --filter "+ *.sql.gz" --filter "- *"
rclone sync "$BACKUP_DIR" "$BACKUP_REMOTE/databases/current" --progress --filter "+ *_latest.sql.gz" --filter "- *"

echo "Sincronizando volumenes del proyecto..."
for folder in $VOLUME_FOLDERS; do
    for vol_dir in "$VOLUME_BASE_PATH"/"${VOLUME_PREFIX}"_*_"$folder"; do
        [ -d "$vol_dir" ] || continue
        vol_name=$(basename "$vol_dir")
        rclone sync "$vol_dir/" "$BACKUP_REMOTE/volumes/$vol_name/" --progress
    done
done

echo "Limpieza de archivos locales"
find "$BACKUP_DIR" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete

echo "Backup completado"