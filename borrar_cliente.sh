#!/bin/bash
# Uso: sudo ./borrar_cliente.sh cli001
CLIENT_ID=$1

if [ -z "$CLIENT_ID" ]; then
    echo "Error: Debes proveer un ID de cliente (ej: cli001)"
    exit 1
fi

echo "⚠️  ADVERTENCIA: Vas a eliminar permanentemente los datos de $CLIENT_ID."
read -p "Confirmar eliminación total (y/n): " confirm

if [ "$confirm" != "y" ]; then
    echo "Operación cancelada."
    exit 1
fi

# 1. Eliminar Base de Datos y Usuario en PostgreSQL
echo "🗑️  Eliminando base de datos y usuario SQL..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS adestock_db_$CLIENT_ID;"
sudo -u postgres psql -c "DROP USER IF EXISTS user_adestock_$CLIENT_ID;"

# 2. Eliminar Carpetas Físicas (Volúmenes)
echo "📂 Eliminando volúmenes físicos en el host..."
VOLUMES_PATH="/var/lib/docker/volumes"
PREFIX="adestock_$CLIENT_ID"

sudo rm -rf "$VOLUMES_PATH/${PREFIX}_license"
sudo rm -rf "$VOLUMES_PATH/${PREFIX}_logs"
sudo rm -rf "$VOLUMES_PATH/${PREFIX}_media"

echo "✅ Limpieza completa para $CLIENT_ID. El ID ya puede ser reutilizado."
