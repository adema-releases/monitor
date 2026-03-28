#!/bin/bash
# Uso: sudo ./nuevo_cliente.sh cli003
CLIENT_ID=$1

if [ -z "$CLIENT_ID" ]; then
    echo "Error: Debes proveer un ID (ej: cli003)"
    exit 1
fi

VOLUMES_PATH="/var/lib/docker/volumes"
PREFIX="adestock_$CLIENT_ID"

# Generación de contraseña alfanumérica segura (16 caracteres)
DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)

echo "🚀 Creando infraestructura Zero-Trust para $CLIENT_ID..."

# 1. Crear carpetas y asignar permisos físicos
for folder in license logs media; do
    mkdir -p "$VOLUMES_PATH/${PREFIX}_$folder"
    chown -R 1000:1000 "$VOLUMES_PATH/${PREFIX}_$folder"
    chmod -R 755 "$VOLUMES_PATH/${PREFIX}_$folder"
done

# 2. Crear la base de datos lógica y el usuario con clave dinámica
sudo -u postgres psql -c "CREATE DATABASE adestock_db_$CLIENT_ID;"
sudo -u postgres psql -c "CREATE USER user_adestock_$CLIENT_ID WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE adestock_db_$CLIENT_ID TO user_adestock_$CLIENT_ID;"

# 3. Asignar propiedad y permisos sobre el esquema público
sudo -u postgres psql -d adestock_db_$CLIENT_ID -c "ALTER DATABASE adestock_db_$CLIENT_ID OWNER TO user_adestock_$CLIENT_ID;"
sudo -u postgres psql -d adestock_db_$CLIENT_ID -c "GRANT ALL ON SCHEMA public TO user_adestock_$CLIENT_ID;"

echo "=================================================="
echo "✅ Infraestructura física y DB listas para $CLIENT_ID"
echo "🔐 CREDENCIALES DE BASE DE DATOS GENERADAS:"
echo "DB_NAME: adestock_db_$CLIENT_ID"
echo "DB_USER: user_adestock_$CLIENT_ID"
echo "DB_PASSWORD: $DB_PASSWORD"
echo "=================================================="
echo "⚠️ IMPORTANTE: Copia esta DB_PASSWORD e ingrésala en la configuración de secretos de Coolify para este inquilino."
