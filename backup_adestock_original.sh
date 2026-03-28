#!/bin/bash
# Variables de Entorno
BACKUP_DIR="/var/lib/adestock/backups_locales"
DATE=$(date +%Y-%m-%d_%H-%M)
RETENTION_DAYS=7

# Crear carpetas si no existen
mkdir -p $BACKUP_DIR

echo "--- Iniciando Backup Lógico de Bases de Datos ---"
# Lista de DBs a respaldar (escalable)
DATABASES=("adestock_db_demo001" "adestock_db_cli001")

for DB in "${DATABASES[@]}"
do
    echo "Respaldando: $DB"
    sudo -u postgres pg_dump $DB | gzip > "$BACKUP_DIR/${DB}_$DATE.sql.gz"
done

echo "--- Sincronizando con la Nube (Cloudflare R2) ---"
# Sincroniza volcados y carpetas media de los volúmenes de Docker
rclone sync $BACKUP_DIR r2:adestock-demo-backups/databases --progress
rclone sync /var/lib/docker/volumes/ r2:adestock-demo-backups/media --progress
echo "--- Limpieza de archivos viejos (Pruning) ---"
find $BACKUP_DIR -type f -mtime +$RETENTION_DAYS -delete

echo "¡Backup completado exitosamente!"
