#!/bin/bash
# Uso: ./test_tenant_db.sh cli001 [DB_PASSWORD]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="$1"

if ! ensure_client_id "$CLIENT_ID"; then
    echo "Uso: ./test_tenant_db.sh cli001 [DB_PASSWORD]"
    exit 1
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
DB_PASS="$2"

if [ -z "$DB_PASS" ]; then
    read -r -s -p "Ingrese DB_PASSWORD para $DB_USER: " DB_PASS
    echo
fi

echo "=== AUDITORIA DE CAPA DE DATOS: $CLIENT_ID ==="

echo -n "[1/2] Verificando red, DB y credenciales... "
if PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c '\q' >/dev/null 2>&1; then
    echo "OK"
else
    echo "ERROR"
    echo "Causa probable: DB inexistente, password incorrecta o PostgreSQL no escucha en $DB_HOST."
    exit 1
fi

echo -n "[2/2] Verificando escritura en schema public... "
if PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c 'CREATE TABLE monitor_test_permisos (id serial); DROP TABLE monitor_test_permisos;' >/dev/null 2>&1; then
    echo "OK"
else
    echo "ERROR"
    echo "Causa probable: usuario sin permisos sobre schema public."
    exit 1
fi

echo "DIAGNOSTICO: infraestructura validada para $CLIENT_ID"
