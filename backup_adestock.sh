#!/bin/bash
# Variables de Entorno
BACKUP_DIR="/var/lib/adestock/backups_locales"
DATE_FOLDER=$(date +%Y-%m-%d)
DATE_FILE=$(date +%H-%M)
RETENTION_DAYS=7

# Crear carpetas si no existen
mkdir -p $BACKUP_DIR

echo "--- Iniciando Backup Lógico de Bases de Datos (Auto-descubrimiento) ---"

# Consulta dinámica: Extrae todas las bases de datos que comiencen con adestock_db_
DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE 'adestock_db_%';")

for DB in $DATABASES
do
    echo "Respaldando: $DB"
    # 1. Generamos el archivo histórico con fecha y hora
    FILENAME="${DB}_${DATE_FOLDER}_${DATE_FILE}.sql.gz"
    sudo -u postgres pg_dump $DB | gzip > "$BACKUP_DIR/$FILENAME"

    # 2. Creamos una copia que siempre se llame "latest" para tener acceso rápido
    cp "$BACKUP_DIR/$FILENAME" "$BACKUP_DIR/${DB}_latest.sql.gz"
done

echo "--- Sincronizando con DigitalOcean (Estructura Organizada) ---"

# Sincronizamos los históricos a carpetas por día (Orden corporativo)
rclone copy $BACKUP_DIR r2:adestock-demo-backups/databases/$DATE_FOLDER --progress --include "*.sql.gz" --exclude "*_latest.sql.gz"

# Sincronizamos solo los "latest" a la raíz de la carpeta databases
rclone sync $BACKUP_DIR r2:adestock-demo-backups/databases/current --progress --include "*_latest.sql.gz"

# Sincronizamos medios y licencias (Espejo físico idéntico)
# Sincronizamos volúmenes persistentes íntegros (Medios, Licencias, Logs)
rclone sync /var/lib/docker/volumes/ r2:adestock-demo-backups/volumes --progress

echo "--- Limpieza de archivos locales (Pruning) ---"
find $BACKUP_DIR -type f -mtime +$RETENTION_DAYS -delete

echo "¡Backup completado exitosamente!"
