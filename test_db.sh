#!/bin/bash
# Uso: ./test_db.sh cli001
CLIENT_ID=$1

if [ -z "$CLIENT_ID" ]; then
    echo "Error: Debes proveer un ID de cliente. Ejemplo: ./test_db.sh cli001"
    exit 1
fi

DB_NAME="adestock_db_$CLIENT_ID"
DB_USER="user_adestock_$CLIENT_ID"
DB_PASS="clave_estandar_2026"
DB_HOST="172.17.0.1" # Simulamos la conexión desde la red de contenedores

echo "=== AUDITORÍA DE CAPA DE DATOS: $CLIENT_ID ==="

# 1. Test de Autenticación y Existencia
echo -n "[1/2] Verificando red, existencia de DB y credenciales... "
if PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c '\q' >/dev/null 2>&1; then
    echo "✅ OK"
else
    echo "❌ ERROR"
    echo "Causa probable: La base de datos '$DB_NAME' no existe, la clave es incorrecta o PostgreSQL no escucha en $DB_HOST."
    exit 1
fi

# 2. Test de Permisos sobre el Esquema Público (Simulación de Migración)
echo -n "[2/2] Verificando privilegios de escritura en el esquema public... "
if PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c 'CREATE TABLE adema_test_permisos (id serial); DROP TABLE adema_test_permisos;' >/dev/null 2>&1; then
    echo "✅ OK"
else
    echo "❌ ERROR"
    echo "Causa probable: El usuario no es dueño del esquema. Fallará el comando 'python manage.py migrate'."
    exit 1
fi

echo "============================================="
echo "🚀 DIAGNÓSTICO: LUZ VERDE. Infraestructura validada para $CLIENT_ID."
echo "Puedes proceder con el Deploy en Coolify."
