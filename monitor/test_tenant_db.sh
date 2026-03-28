#!/bin/bash
set -euo pipefail
# Uso: ./test_tenant_db.sh cli001 [DB_PASSWORD]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="${1:-}"

if ! ensure_client_id "$CLIENT_ID"; then
    echo "Uso: ./test_tenant_db.sh cli001 [DB_PASSWORD]"
    exit 1
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
DB_PASS="${2:-}"

if [ -z "$DB_PASS" ]; then
    read -r -s -p "Ingrese DB_PASSWORD para $DB_USER: " DB_PASS
    echo
fi

echo "=== AUDITORIA DE CAPA DE DATOS: $CLIENT_ID ==="
echo "Objetivo: host=$DB_HOST port=$DB_PORT db=$DB_NAME user=$DB_USER"

TMP_ERR_CONN="/tmp/monitor_psql_conn_$$.err"
TMP_ERR_SCHEMA="/tmp/monitor_psql_schema_$$.err"
trap 'rm -f "$TMP_ERR_CONN" "$TMP_ERR_SCHEMA"' EXIT

ACTIVE_DB_HOST="$DB_HOST"

is_network_error() {
    grep -Eqi 'Connection timed out|No route to host|could not connect to server|Connection refused' "$1"
}

try_connection() {
    local host="$1"
    local err_file="$2"

    PGPASSWORD="$DB_PASS" psql -h "$host" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -c '\q' >/dev/null 2>"$err_file"
}

echo -n "[1/2] Verificando red, DB y credenciales... "
if try_connection "$ACTIVE_DB_HOST" "$TMP_ERR_CONN"; then
    echo "OK"
else
    if [ "$DB_HOST" = "172.17.0.1" ] && [ -s "$TMP_ERR_CONN" ] && is_network_error "$TMP_ERR_CONN"; then
        for fallback_host in 127.0.0.1 localhost; do
            if try_connection "$fallback_host" "$TMP_ERR_CONN"; then
                ACTIVE_DB_HOST="$fallback_host"
                echo "OK"
                echo "Aviso: el host 172.17.0.1 no respondio; se uso fallback $fallback_host."
                echo "Sugerencia: actualiza DB_HOST en monitor/.monitor.env para evitar este fallback."
                break
            fi
        done
    fi

    if [ "$ACTIVE_DB_HOST" = "$DB_HOST" ]; then
        echo "ERROR"
        if [ -s "$TMP_ERR_CONN" ]; then
            echo "Detalle PostgreSQL:"
            sed 's/^/  - /' "$TMP_ERR_CONN"
        fi
        echo "Causa probable: DB inexistente, password incorrecta o PostgreSQL no escucha en ${DB_HOST}:${DB_PORT}."
        exit 1
    fi
fi

echo -n "[2/2] Verificando escritura en schema public... "
if PGPASSWORD="$DB_PASS" psql -h "$ACTIVE_DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -c 'CREATE TABLE monitor_test_permisos (id serial); DROP TABLE monitor_test_permisos;' >/dev/null 2>"$TMP_ERR_SCHEMA"; then
    echo "OK"
else
    echo "ERROR"
    if [ -s "$TMP_ERR_SCHEMA" ]; then
        echo "Detalle PostgreSQL:"
        sed 's/^/  - /' "$TMP_ERR_SCHEMA"
    fi
    echo "Causa probable: usuario sin permisos sobre schema public."
    exit 1
fi

echo "DIAGNOSTICO: infraestructura validada para $CLIENT_ID"
