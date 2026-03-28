#!/bin/bash
# Uso: sudo ./nuevo_cliente.sh cli003
CLIENT_ID=$1

if [ -z "$CLIENT_ID" ]; then
    echo "Error: Debes proveer un ID (ej: cli003)"
    exit 1
fi

VOLUMES_PATH="/var/lib/docker/volumes"
PREFIX="adestock_$CLIENT_ID"

echo "🚀 Creando infraestructura para $CLIENT_ID..."

# 1. Crear carpetas y asignar permisos físicos
for folder in license logs media; do
    mkdir -p "$VOLUMES_PATH/${PREFIX}_$folder"
    chown -R 1000:1000 "$VOLUMES_PATH/${PREFIX}_$folder"
    chmod -R 755 "$VOLUMES_PATH/${PREFIX}_$folder"
done

# 2. Crear la base de datos lógica y el usuario
sudo -u postgres psql -c "CREATE DATABASE adestock_db_$CLIENT_ID;"
sudo -u postgres psql -c "CREATE USER user_adestock_$CLIENT_ID WITH PASSWORD 'clave_estandar_2026';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE adestock_db_$CLIENT_ID TO user_adestock_$CLIENT_ID;"

# 3. Asignar propiedad y permisos sobre el esquema público (Fix de Escalabilidad)
sudo -u postgres psql -d adestock_db_$CLIENT_ID -c "ALTER DATABASE adestock_db_$CLIENT_ID OWNER TO user_adestock_$CLIENT_ID;"
sudo -u postgres psql -d adestock_db_$CLIENT_ID -c "GRANT ALL ON SCHEMA public TO user_adestock_$CLIENT_ID;"

echo "✅ Infraestructura física y DB listas para $CLIENT_ID"
