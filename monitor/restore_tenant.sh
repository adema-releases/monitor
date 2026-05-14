#!/bin/bash
set -euo pipefail
# Uso: sudo ./restore_tenant.sh [CLIENT_ID] [YYYY-MM-DD] [archivo.sql.gz] [--no-pre-backup] [--allow-active] [--force]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="${1:-}"
FECHA="${2:-}"
FILE_NAME="${3:-}"
NO_PRE_BACKUP=0
ALLOW_ACTIVE=0
FORCE=0

if [ "$#" -ge 3 ]; then
    shift 3
else
    shift "$#"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-pre-backup)
            NO_PRE_BACKUP=1
            ;;
        --allow-active)
            ALLOW_ACTIVE=1
            ;;
        --force|-f)
            FORCE=1
            ;;
        -h|--help)
            echo "Uso: sudo ./restore_tenant.sh [CLIENT_ID] [YYYY-MM-DD] [archivo.sql.gz] [--no-pre-backup] [--allow-active] [--force]"
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $1"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$CLIENT_ID" ]; then
    read -r -p "Ingrese CLIENT_ID (ej: cli005): " CLIENT_ID
fi
if [ -z "$FECHA" ]; then
    read -r -p "Ingrese fecha backup (YYYY-MM-DD): " FECHA
fi
if [ -z "$FILE_NAME" ]; then
    read -r -p "Ingrese archivo .sql.gz: " FILE_NAME
fi

if ! ensure_client_id "$CLIENT_ID"; then
    exit 1
fi

if ! echo "$FECHA" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    echo "Error: fecha invalida. Usa YYYY-MM-DD."
    audit_event "restore" "$CLIENT_ID" "error" "invalid_date=$FECHA"
    exit 1
fi

if command -v date >/dev/null 2>&1 && ! date -d "$FECHA" +%F >/dev/null 2>&1; then
    echo "Error: fecha inexistente: $FECHA"
    audit_event "restore" "$CLIENT_ID" "error" "invalid_calendar_date=$FECHA"
    exit 1
fi

if ! echo "$FILE_NAME" | grep -Eq '^[A-Za-z0-9._-]+\.sql\.gz$'; then
    echo "Error: nombre de archivo invalido. Debe ser un .sql.gz sin rutas ni espacios."
    audit_event "restore" "$CLIENT_ID" "error" "invalid_file=$FILE_NAME"
    exit 1
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
PREFIX=$(volume_namespace "$CLIENT_ID")
REMOTE_PATH="$BACKUP_REMOTE/databases/${FECHA}/${FILE_NAME}"
MANIFEST_REMOTE_PATH="${REMOTE_PATH}.manifest.json"
RESTORE_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$RESTORE_TMP_DIR"' EXIT

audit_event "restore" "$CLIENT_ID" "started" "file=$FILE_NAME date=$FECHA"

if ! sudo -u postgres psql -t -A -c "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER';" | grep -qx 1; then
    echo "Error: no existe el usuario PostgreSQL esperado: $DB_USER"
    audit_event "restore" "$CLIENT_ID" "error" "db_user_missing=$DB_USER"
    exit 1
fi

if [ "$ALLOW_ACTIVE" -eq 0 ] && command -v docker >/dev/null 2>&1; then
    ACTIVE_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "(^|[-_])${CLIENT_ID}($|[-_])" || true)
    if [ -n "$ACTIVE_CONTAINERS" ]; then
        echo "Error: hay contenedores activos que parecen pertenecer a $CLIENT_ID:"
        echo "$ACTIVE_CONTAINERS" | sed 's/^/  - /'
        echo "Detenelos antes de restaurar o usa --allow-active si ya validaste el riesgo."
        audit_event "restore" "$CLIENT_ID" "error" "tenant_active"
        exit 1
    fi
fi

echo "Verificando backup remoto..."
if ! rclone ls "$REMOTE_PATH" > /dev/null 2>&1; then
    echo "Error: el archivo no existe en la ruta remota indicada."
    audit_event "restore" "$CLIENT_ID" "error" "remote_file_missing=$REMOTE_PATH"
    exit 1
fi

if [ "$NO_PRE_BACKUP" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR/pre_restore"
    PRE_BACKUP_FILE="$BACKUP_DIR/pre_restore/${DB_NAME}_pre_restore_$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    echo "Generando backup pre-restore obligatorio: $PRE_BACKUP_FILE"
    if sudo -u postgres psql -t -A -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -qx 1; then
        sudo -u postgres pg_dump "$DB_NAME" | gzip > "$PRE_BACKUP_FILE"
        chmod 600 "$PRE_BACKUP_FILE" 2>/dev/null || true
    else
        echo "Aviso: la DB $DB_NAME no existe; se omite dump pre-restore."
    fi
else
    echo "Aviso: backup pre-restore omitido por --no-pre-backup."
fi

if [ "$FORCE" -eq 0 ]; then
    echo "ADVERTENCIA: se va a pisar la base $DB_NAME con $FILE_NAME."
    read -r -p "Escribi RESTORE $CLIENT_ID para confirmar: " confirm_restore
    if [ "$confirm_restore" != "RESTORE $CLIENT_ID" ]; then
        echo "Operacion cancelada."
        audit_event "restore" "$CLIENT_ID" "cancelled" "confirmation_failed"
        exit 1
    fi
fi

echo "Descargando backup logico..."
rclone copy "$REMOTE_PATH" "$RESTORE_TMP_DIR/" --progress

if rclone ls "$MANIFEST_REMOTE_PATH" >/dev/null 2>&1; then
    echo "Descargando manifiesto y verificando SHA256..."
    rclone copy "$MANIFEST_REMOTE_PATH" "$RESTORE_TMP_DIR/" --progress
    EXPECTED_SHA=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("sha256", ""))' "$RESTORE_TMP_DIR/${FILE_NAME}.manifest.json")
    ACTUAL_SHA=$(sha256sum "$RESTORE_TMP_DIR/$FILE_NAME" | awk '{print $1}')
    if [ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        echo "Error: SHA256 no coincide. Esperado=$EXPECTED_SHA Actual=$ACTUAL_SHA"
        audit_event "restore" "$CLIENT_ID" "error" "sha256_mismatch"
        exit 1
    fi
else
    echo "Aviso: no hay manifiesto remoto; se restaura sin verificacion SHA256 externa."
fi

gunzip -f "$RESTORE_TMP_DIR/${FILE_NAME}"
SQL_FILE="$RESTORE_TMP_DIR/${FILE_NAME%.gz}"

echo "Restaurando base de datos $DB_NAME..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
sudo -u postgres psql "$DB_NAME" < "$SQL_FILE"
sudo -u postgres psql -d "$DB_NAME" -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\"; GRANT ALL ON SCHEMA public TO \"$DB_USER\";"

echo "Sincronizando volumenes persistentes..."
for folder in $VOLUME_FOLDERS; do
    rclone sync "$BACKUP_REMOTE/volumes/${PREFIX}_${folder}/" "$VOLUME_BASE_PATH/${PREFIX}_${folder}/" --progress
    sudo chown -R 1000:1000 "$VOLUME_BASE_PATH/${PREFIX}_${folder}"
done

echo "Restauracion completada para $CLIENT_ID"
audit_event "restore" "$CLIENT_ID" "success" "file=$FILE_NAME date=$FECHA no_pre_backup=$NO_PRE_BACKUP allow_active=$ALLOW_ACTIVE"