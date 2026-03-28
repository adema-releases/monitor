#!/bin/bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(cd "$COMMON_DIR/.." && pwd)"

load_env_file() {
    local env_file="$1"
    local line
    local key
    local value

    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        # Soportar archivos con fin de linea CRLF
        line="${line%$'\r'}"

        # Ignorar lineas vacias o comentarios
        case "$line" in
            ''|'#'*)
                continue
                ;;
        esac

        if [[ "$line" != *=* ]]; then
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"

        # Limpiar espacios alrededor de la clave y el valor
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"

        # Validar nombre de variable para evitar parseos ambiguos
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            continue
        fi

        # Remover comillas envolventes simples o dobles
        if [ "${#value}" -ge 2 ]; then
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                value="${value:1:${#value}-2}"
            fi
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"
}

load_monitor_env() {
    local env_file="${MONITOR_ENV_FILE:-$MONITOR_DIR/.monitor.env}"

    load_env_file "$env_file"

    PROJECT_CODE="${PROJECT_CODE:-django}"
    CLUSTER_ID="${CLUSTER_ID:-CLUSTER-LOCAL}"

    DB_PREFIX="${DB_PREFIX:-$PROJECT_CODE}"
    DB_NAME_PREFIX="${DB_NAME_PREFIX:-${DB_PREFIX}_db}"
    DB_USER_PREFIX="${DB_USER_PREFIX:-user_${DB_PREFIX}}"

    VOLUME_BASE_PATH="${VOLUME_BASE_PATH:-/var/lib/docker/volumes}"
    VOLUME_PREFIX="${VOLUME_PREFIX:-$DB_PREFIX}"
    VOLUME_FOLDERS="${VOLUME_FOLDERS:-license logs media}"

    BACKUP_DIR="${BACKUP_DIR:-/var/lib/${PROJECT_CODE}/backups_locales}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_REMOTE="${BACKUP_REMOTE:-r2:${PROJECT_CODE}-backups}"

    BREVO_RECIPIENT="${BREVO_RECIPIENT:-}"
    BREVO_SENDER="${BREVO_SENDER:-}"
    BREVO_SENDER_NAME="${BREVO_SENDER_NAME:-Adema Core Operaciones}"

    DB_HOST="${DB_HOST:-172.17.0.1}"
    DB_PORT="${DB_PORT:-5432}"
    RAM_THRESHOLD_MB="${RAM_THRESHOLD_MB:-450}"

    EXCLUDE_CONTAINER_REGEX="${EXCLUDE_CONTAINER_REGEX:-coolify|NAME}"
    SECRETS_FILE="${SECRETS_FILE:-$MONITOR_DIR/.monitor.secrets}"

    load_env_file "$SECRETS_FILE"
}

db_name() {
    echo "${DB_NAME_PREFIX}_$1"
}

db_user() {
    echo "${DB_USER_PREFIX}_$1"
}

volume_namespace() {
    echo "${VOLUME_PREFIX}_$1"
}

ensure_client_id() {
    if [ -z "$1" ]; then
        return 1
    fi

    if ! echo "$1" | grep -Eq '^[a-zA-Z0-9_-]+$'; then
        echo "Error: El CLIENT_ID solo puede tener letras, numeros, guion y guion bajo."
        return 1
    fi

    return 0
}

send_brevo_email() {
    local subject="$1"
    local body_text="$2"
    local payload_path="/tmp/brevo_payload_$$.json"
    local json_body

    if [ -z "$BREVO_API_KEY" ] || [ -z "$BREVO_RECIPIENT" ] || [ -z "$BREVO_SENDER" ]; then
        echo "Error: Faltan BREVO_API_KEY, BREVO_RECIPIENT o BREVO_SENDER en la configuracion."
        return 1
    fi

    json_body=$(echo -e "$body_text" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')

    cat <<EOF > "$payload_path"
{
  "sender": { "email": "$BREVO_SENDER", "name": "$BREVO_SENDER_NAME" },
  "to": [ { "email": "$BREVO_RECIPIENT" } ],
  "subject": "$subject",
  "textContent": "$json_body"
}
EOF

    curl -s -X POST 'https://api.brevo.com/v3/smtp/email' \
        -H 'accept: application/json' \
        -H "api-key: $BREVO_API_KEY" \
        -H 'content-type: application/json' \
        -d @"$payload_path" > /dev/null

    rm -f "$payload_path"
}