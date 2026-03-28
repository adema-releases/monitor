#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

DATE_FOLDER=$(date +%Y-%m-%d)
DATE_FILE=$(date +%H-%M)

mkdir -p "$BACKUP_DIR"

echo "Iniciando backup de bases de datos para $PROJECT_CODE..."

DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE '${DB_NAME_PREFIX}_%';")

for DB in $DATABASES; do
    echo "Respaldando: $DB"
    FILENAME="${DB}_${DATE_FOLDER}_${DATE_FILE}.sql.gz"
    sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_DIR/$FILENAME"
    cp "$BACKUP_DIR/$FILENAME" "$BACKUP_DIR/${DB}_latest.sql.gz"
done

echo "Sincronizando bases a remoto: $BACKUP_REMOTE"
rclone copy "$BACKUP_DIR" "$BACKUP_REMOTE/databases/$DATE_FOLDER" --progress --include "*.sql.gz" --exclude "*_latest.sql.gz"
rclone sync "$BACKUP_DIR" "$BACKUP_REMOTE/databases/current" --progress --include "*_latest.sql.gz"

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