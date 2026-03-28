#!/bin/bash
# ==============================================================================
# Script de Restauración B2B - Adema Sistemas
# Uso: sudo ./restaurar_cliente.sh
# ==============================================================================

# 1. Captura de Parámetros
echo "--- 🛠️ INICIANDO PROTOCOLO DE RESTAURACIÓN ---"
read -p "🆔 Ingrese el ID del cliente (ej: cli005): " CLIENT_ID
read -p "📅 Ingrese la fecha del backup (YYYY-MM-DD): " FECHA
read -p "📦 Ingrese el nombre exacto del archivo .sql.gz: " FILE_NAME

# Definición de variables internas
DB_NAME="adestock_db_${CLIENT_ID}"
DB_USER="user_adestock_${CLIENT_ID}"
REMOTE_PATH="r2:adestock-demo-backups/databases/${FECHA}/${FILE_NAME}"

# 2. Validación de existencia en la Nube
echo "🔍 Verificando archivo en DigitalOcean..."
if ! rclone ls "$REMOTE_PATH" > /dev/null 2>&1; then
    echo "❌ Error: El archivo no existe en la ruta especificada."
    exit 1
fi

# 3. Descarga y Descompresión
echo "📥 Descargando backup lógico..."
rclone copy "$REMOTE_PATH" /tmp/ --progress
gunzip -f "/tmp/${FILE_NAME}"
SQL_FILE="/tmp/${FILE_NAME%.gz}"

# 4. Restauración de Base de Datos (PostgreSQL)
echo "🐘 Restaurando base de datos $DB_NAME..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${DB_NAME};"
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
sudo -u postgres psql "$DB_NAME" < "$SQL_FILE"


# 5. Restauración Física de Volúmenes (Ajustado para evitar anidación)
echo "📁 Sincronizando volúmenes persistentes..."
rclone sync "r2:adestock-demo-backups/volumes/adestock_${CLIENT_ID}_license/" "/var/lib/docker/volumes/adestock_${CLIENT_ID}_license/" --progress
rclone sync "r2:adestock-demo-backups/volumes/adestock_${CLIENT_ID}_media/" "/var/lib/docker/volumes/adestock_${CLIENT_ID}_media/" --progress


# 6. Ajuste de Permisos y Limpieza
echo "🔐 Aplicando higiene de permisos (UID 1000)..."
sudo chown -R 1000:1000 "/var/lib/docker/volumes/adestock_${CLIENT_ID}_license"
sudo chown -R 1000:1000 "/var/lib/docker/volumes/adestock_${CLIENT_ID}_media"
rm -f "$SQL_FILE"

echo "=================================================="
echo "✅ RESTAURACIÓN COMPLETADA PARA $CLIENT_ID"
echo "🚀 Acción: Reinicia el contenedor en Coolify para aplicar cambios."
echo "=================================================="
