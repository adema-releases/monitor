#!/bin/bash
set -euo pipefail
# Adema Core - Tenant bootstrap
# Repo oficial: https://github.com/adema-releases/monitor
# Uso: sudo ./create_tenant.sh cli003 [DB_PASSWORD] [--password-file RUTA] [--env-output] [--password-output]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="${1:-}"

if ! ensure_client_id "$CLIENT_ID"; then
    echo "Uso: sudo ./create_tenant.sh cli003 [DB_PASSWORD] [--password-file RUTA] [--env-output] [--password-output] [--output-file RUTA]"
    exit 1
fi

DB_PASSWORD=""
SHOW_DB_PASSWORD=0
ENV_OUTPUT=0
PASSWORD_FILE=""
OUTPUT_FILE=""

ARGS=("${@:2}")
IDX=0
while [ "$IDX" -lt "${#ARGS[@]}" ]; do
    arg="${ARGS[$IDX]}"
    case "$arg" in
        --env-output)
            ENV_OUTPUT=1
            SHOW_DB_PASSWORD=1
            ;;
        --password-output)
            SHOW_DB_PASSWORD=1
            ;;
        --no-password-output)
            SHOW_DB_PASSWORD=0
            ;;
        --password-file)
            IDX=$((IDX + 1))
            if [ "$IDX" -ge "${#ARGS[@]}" ]; then
                echo "Error: falta ruta luego de --password-file"
                exit 1
            fi
            PASSWORD_FILE="${ARGS[$IDX]}"
            ;;
        --output-file)
            IDX=$((IDX + 1))
            if [ "$IDX" -ge "${#ARGS[@]}" ]; then
                echo "Error: falta ruta luego de --output-file"
                exit 1
            fi
            OUTPUT_FILE="${ARGS[$IDX]}"
            ;;
        *)
            if [ -z "$DB_PASSWORD" ]; then
                DB_PASSWORD="$arg"
            else
                echo "Error: argumento extra no reconocido: $arg"
                echo "Uso: sudo ./create_tenant.sh cli003 [DB_PASSWORD] [--password-file RUTA] [--env-output] [--password-output] [--output-file RUTA]"
                exit 1
            fi
            ;;
    esac
    IDX=$((IDX + 1))
done

if [ -n "$PASSWORD_FILE" ]; then
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo "Error: no existe archivo de password: $PASSWORD_FILE"
        exit 1
    fi
    DB_PASSWORD="$(tr -d '\r\n' < "$PASSWORD_FILE")"
    rm -f "$PASSWORD_FILE" || true
fi

if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
PREFIX=$(volume_namespace "$CLIENT_ID")
TENANT_FILE="$OUTPUT_FILE"
if [ -z "$TENANT_FILE" ]; then
    TENANT_FILE="$(tenant_env_file "$CLIENT_ID")"
fi

mkdir -p "$(dirname "$TENANT_FILE")"

echo "Creando infraestructura para $CLIENT_ID en proyecto $PROJECT_CODE..."
audit_event "create_tenant" "$CLIENT_ID" "started" "db=$DB_NAME user=$DB_USER"

DOCKER0_IP="$(detect_docker0_ip || true)"
if [ -n "$DOCKER0_IP" ]; then
    echo "docker0 detectada: $DOCKER0_IP"
fi

ensure_postgres_scram

if sudo -u postgres psql -t -A -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -qx 1; then
    echo "Error: ya existe la base $DB_NAME. No se sobrescribe un tenant existente."
    audit_event "create_tenant" "$CLIENT_ID" "error" "database_exists"
    exit 1
fi

if sudo -u postgres psql -t -A -c "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER';" | grep -qx 1; then
    echo "Error: ya existe el usuario $DB_USER. No se reutilizan usuarios de app."
    audit_event "create_tenant" "$CLIENT_ID" "error" "role_exists"
    exit 1
fi

for folder in $VOLUME_FOLDERS; do
    mkdir -p "$VOLUME_BASE_PATH/${PREFIX}_$folder"
    chown -R 1000:1000 "$VOLUME_BASE_PATH/${PREFIX}_$folder"
    chmod -R 755 "$VOLUME_BASE_PATH/${PREFIX}_$folder"
done

sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\";"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "SET password_encryption = 'scram-sha-256'; CREATE USER \"$DB_USER\" WITH ENCRYPTED PASSWORD '$(printf '%s' "$DB_PASSWORD" | sed "s/'/''/g")';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";"

sudo -u postgres psql -d "$DB_NAME" -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\";"
sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL ON SCHEMA public TO \"$DB_USER\";"

print_coolify_env "$CLIENT_ID" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" 1 | write_secure_file "$TENANT_FILE"
audit_event "create_tenant" "$CLIENT_ID" "success" "db=$DB_NAME env_file=$TENANT_FILE"

echo "=================================================="
echo "Infraestructura y DB listas para $CLIENT_ID"
echo "DB_NAME: $DB_NAME"
echo "DB_USER: $DB_USER"
echo "Credenciales Coolify guardadas en: $TENANT_FILE"
echo "Permisos recomendados: root:root 600"
if [ "$ENV_OUTPUT" -eq 1 ]; then
    echo "---------------- COOLIFY ENV ----------------"
    print_coolify_env "$CLIENT_ID" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$SHOW_DB_PASSWORD"
elif [ "$SHOW_DB_PASSWORD" -eq 1 ]; then
    echo "DB_PASSWORD: $DB_PASSWORD"
fi
echo "=================================================="