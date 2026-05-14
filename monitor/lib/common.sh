#!/bin/bash
# Adema Core - Common library
# Repo oficial: https://github.com/adema-releases/monitor

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$(cd "$COMMON_DIR/.." && pwd)"
ADEMA_NODE_ENV_FILE="${ADEMA_NODE_ENV_FILE:-/etc/adema/node.env}"

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
    local node_project_code=""
    local node_cluster_id=""
    local node_backup_remote=""
    local node_base_domain=""
    local node_infra_domain=""
    local node_deploy_domain=""

    load_env_file "$ADEMA_NODE_ENV_FILE"

    node_project_code="${PROJECT_CODE:-}"
    node_cluster_id="${CLUSTER_ID:-}"
    node_backup_remote="${BACKUP_REMOTE:-}"
    node_base_domain="${ADEMA_BASE_DOMAIN:-${BASE_DOMAIN:-}}"
    node_infra_domain="${ADEMA_INFRA_DOMAIN:-}"
    node_deploy_domain="${ADEMA_DEPLOY_DOMAIN:-}"

    load_env_file "$env_file"

    # Prioridad documentada: /etc/adema/node.env define identidad del nodo;
    # .monitor.env define configuracion operativa del monitor.
    PROJECT_CODE="${node_project_code:-${PROJECT_CODE:-}}"
    CLUSTER_ID="${node_cluster_id:-${CLUSTER_ID:-}}"
    BACKUP_REMOTE="${node_backup_remote:-${BACKUP_REMOTE:-}}"
    ADEMA_BASE_DOMAIN="${node_base_domain:-${ADEMA_BASE_DOMAIN:-${BASE_DOMAIN:-}}}"
    ADEMA_INFRA_DOMAIN="${node_infra_domain:-${ADEMA_INFRA_DOMAIN:-}}"
    ADEMA_DEPLOY_DOMAIN="${node_deploy_domain:-${ADEMA_DEPLOY_DOMAIN:-}}"
    BASE_DOMAIN="${ADEMA_BASE_DOMAIN:-${BASE_DOMAIN:-}}"

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
    TENANT_ENV_DIR="${TENANT_ENV_DIR:-/etc/adema/tenants}"
    ADEMA_AUDIT_LOG="${ADEMA_AUDIT_LOG:-/var/log/adema-node/audit.jsonl}"
    BASE_DOMAIN="${BASE_DOMAIN:-${ADEMA_BASE_DOMAIN:-}}"
    ADEMA_NODE_ID="${ADEMA_NODE_ID:-}"
    ADEMA_NODE_UUID="${ADEMA_NODE_UUID:-}"
    ADEMA_NODE_NAME="${ADEMA_NODE_NAME:-${ADEMA_NODE_ID:-}}"
    NODE_CREATED_AT="${NODE_CREATED_AT:-}"

    BREVO_RECIPIENT="${BREVO_RECIPIENT:-}"
    BREVO_SENDER="${BREVO_SENDER:-}"
    BREVO_SENDER_NAME="${BREVO_SENDER_NAME:-Adema Core Operaciones}"

    DB_HOST="${DB_HOST:-${DB_DOCKER0_IP:-}}"
    if [ -z "$DB_HOST" ]; then
        DB_HOST="$(detect_docker0_ip || true)"
    fi
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-5432}"
    RAM_THRESHOLD_MB="${RAM_THRESHOLD_MB:-450}"

    EXCLUDE_CONTAINER_REGEX="${EXCLUDE_CONTAINER_REGEX:-coolify|NAME}"
    SECRETS_FILE="${SECRETS_FILE:-$MONITOR_DIR/.monitor.secrets}"

    load_env_file "$SECRETS_FILE"

    if [ -f "$ADEMA_NODE_ENV_FILE" ]; then
        audit_event "node_identity_loaded" "" "success" "node_id=${ADEMA_NODE_ID:-} node_uuid=${ADEMA_NODE_UUID:-}"
    fi
}

json_escape() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1])[1:-1], end="")' "${1:-}"
}

urlencode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""), end="")' "${1:-}"
}

audit_event() {
    local action="${1:-unknown}"
    local client_id="${2:-}"
    local result="${3:-unknown}"
    local details="${4:-}"
    local audit_log="${ADEMA_AUDIT_LOG:-/var/log/adema-node/audit.jsonl}"
    local audit_dir
    local timestamp
    local system_user

    audit_dir="$(dirname "$audit_log")"
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    system_user="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"

    mkdir -p "$audit_dir" 2>/dev/null || true
    touch "$audit_log" 2>/dev/null || true
    chmod 640 "$audit_log" 2>/dev/null || true

    printf '{"timestamp_utc":"%s","action":"%s","client_id":"%s","system_user":"%s","result":"%s","node":"%s","adema_node_id":"%s","adema_node_uuid":"%s","cluster_id":"%s","project_code":"%s","details":"%s"}\n' \
        "$(json_escape "$timestamp")" \
        "$(json_escape "$action")" \
        "$(json_escape "$client_id")" \
        "$(json_escape "$system_user")" \
        "$(json_escape "$result")" \
        "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
        "$(json_escape "${ADEMA_NODE_ID:-}")" \
        "$(json_escape "${ADEMA_NODE_UUID:-}")" \
        "$(json_escape "${CLUSTER_ID:-}")" \
        "$(json_escape "${PROJECT_CODE:-}")" \
        "$(json_escape "$details")" >> "$audit_log" 2>/dev/null || true
}

tenant_env_file() {
    echo "${TENANT_ENV_DIR:-/etc/adema/tenants}/$1.env"
}

write_secure_file() {
    local target="$1"
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "$tmp_file"
    install -m 600 -o root -g root "$tmp_file" "$target"
    rm -f "$tmp_file"
}

load_tenant_env() {
    local client_id="$1"
    local env_file
    env_file="$(tenant_env_file "$client_id")"
    if [ -f "$env_file" ]; then
        load_env_file "$env_file"
        return 0
    fi
    return 1
}

tenant_allowed_hosts() {
    local client_id="$1"
    if [ -n "${BASE_DOMAIN:-}" ]; then
        echo "${client_id}.${BASE_DOMAIN}"
    else
        echo ""
    fi
}

print_coolify_env() {
    local client_id="$1"
    local db_name_value="$2"
    local db_user_value="$3"
    local db_password_value="$4"
    local show_password="${5:-1}"
    local prefix_value
    local active_db_host
    local encoded_user
    local encoded_pass
    local encoded_db

    prefix_value="$(volume_namespace "$client_id")"
    active_db_host="$(detect_docker0_ip || true)"
    active_db_host="${active_db_host:-${DB_HOST:-127.0.0.1}}"

    encoded_user="$(urlencode "$db_user_value")"
    encoded_pass="$(urlencode "$db_password_value")"
    encoded_db="$(urlencode "$db_name_value")"

    echo "CLIENT_ID=$client_id"
    echo "DB_NAME=$db_name_value"
    echo "DB_USER=$db_user_value"
    if [ "$show_password" -eq 1 ]; then
        echo "DB_PASSWORD=$db_password_value"
    fi
    echo "DB_HOST=$active_db_host"
    echo "DB_PORT=${DB_PORT:-5432}"
    if [ "$show_password" -eq 1 ]; then
        echo "DATABASE_URL=postgresql://${encoded_user}:${encoded_pass}@${active_db_host}:${DB_PORT:-5432}/${encoded_db}"
    else
        echo "DATABASE_URL=postgresql://${encoded_user}:<DB_PASSWORD>@${active_db_host}:${DB_PORT:-5432}/${encoded_db}"
    fi
    echo "DJANGO_ALLOWED_HOSTS=$(tenant_allowed_hosts "$client_id")"
    echo "MEDIA_PATH=$VOLUME_BASE_PATH/${prefix_value}_media"
    echo "LOGS_PATH=$VOLUME_BASE_PATH/${prefix_value}_logs"
    echo "LICENSE_PATH=$VOLUME_BASE_PATH/${prefix_value}_license"
}

resolve_rclone_config() {
    if [ -n "${RCLONE_CONFIG:-}" ] && [ -f "$RCLONE_CONFIG" ]; then
        return 0
    fi

    if [ -f "/root/.config/rclone/rclone.conf" ]; then
        RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
        export RCLONE_CONFIG
        return 0
    fi

    local invoking_user="${SUDO_USER:-}"
    if [ -n "$invoking_user" ]; then
        local user_home
        user_home=$(getent passwd "$invoking_user" | cut -d: -f6)
        if [ -n "$user_home" ] && [ -f "$user_home/.config/rclone/rclone.conf" ]; then
            RCLONE_CONFIG="$user_home/.config/rclone/rclone.conf"
            export RCLONE_CONFIG
            return 0
        fi
    fi

    return 1
}

detect_docker0_ip() {
    ip -o -4 addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

ensure_postgres_scram() {
    local config_file
    local changed

    config_file="$(sudo -u postgres psql -t -A -c "SHOW config_file;" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        echo "Aviso: no se pudo detectar postgresql.conf; se aplicara SCRAM por sesion al crear usuario." >&2
        return 0
    fi

    changed=0
    if grep -Eq '^[[:space:]]*#?[[:space:]]*password_encryption[[:space:]]*=' "$config_file"; then
        if sed -i -E "s|^[[:space:]]*#?[[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = 'scram-sha-256'|" "$config_file"; then
            changed=1
        fi
    else
        if printf "\npassword_encryption = 'scram-sha-256'\n" >> "$config_file"; then
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        sudo -u postgres psql -c "SELECT pg_reload_conf();" >/dev/null || true
    else
        echo "Aviso: no se pudo persistir SCRAM en $config_file (posible filesystem read-only)." >&2
        echo "Aviso: se continuara usando SCRAM por sesion durante la creacion de usuarios." >&2
    fi

    return 0
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

is_generic_identity_value() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        ''|demo|test|default|node|local|ubuntu|debian|server|vps|cluster-local|cluster-demo-01|demo-node|test-node|adema-demo)
            return 0
            ;;
    esac
    return 1
}

is_safe_node_id() {
    echo "${1:-}" | grep -Eq '^[A-Za-z0-9_-]+$'
}

is_uuid() {
    echo "${1:-}" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

backup_remote_path() {
    local remote="${1:-${BACKUP_REMOTE:-}}"
    if [[ "$remote" == *:* ]]; then
        echo "${remote#*:}"
    else
        echo ""
    fi
}

backup_remote_includes_node_id() {
    local remote="${1:-${BACKUP_REMOTE:-}}"
    local node_id="${2:-${ADEMA_NODE_ID:-}}"
    local path
    [ -n "$remote" ] || return 1
    [ -n "$node_id" ] || return 1
    path="$(backup_remote_path "$remote")"
    echo "$path" | grep -Fq "$node_id"
}

detect_public_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 5 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    echo "${ip:-}"
}

remote_node_manifest_path() {
    echo "${BACKUP_REMOTE%/}/node_manifest.json"
}

write_node_manifest_file() {
    local target="$1"
    local created_at="${2:-}"
    local now
    local public_ip

    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    public_ip="$(detect_public_ip || true)"
    created_at="${created_at:-${NODE_CREATED_AT:-$now}}"

    cat > "$target" <<EOF
{
  "ADEMA_NODE_ID": "$(json_escape "${ADEMA_NODE_ID:-}")",
  "ADEMA_NODE_UUID": "$(json_escape "${ADEMA_NODE_UUID:-}")",
  "ADEMA_NODE_NAME": "$(json_escape "${ADEMA_NODE_NAME:-}")",
  "CLUSTER_ID": "$(json_escape "${CLUSTER_ID:-}")",
  "PROJECT_CODE": "$(json_escape "${PROJECT_CODE:-}")",
  "hostname": "$(json_escape "$(hostname 2>/dev/null || echo unknown)")",
  "public_ip": "$(json_escape "$public_ip")",
  "created_at": "$(json_escape "$created_at")",
  "updated_at": "$(json_escape "$now")"
}
EOF
}

manifest_json_value() {
    local file="$1"
    local key="$2"
    python3 -c 'import json, sys; data=json.load(open(sys.argv[1], encoding="utf-8")); print(data.get(sys.argv[2], ""), end="")' "$file" "$key" 2>/dev/null || true
}

ensure_remote_node_manifest() {
    local force="${1:-0}"
    local tmp_dir
    local remote_manifest
    local existing_manifest
    local new_manifest
    local existing_uuid
    local existing_created_at

    if [ -z "${BACKUP_REMOTE:-}" ]; then
        echo "ERROR: BACKUP_REMOTE no definido."
        audit_event "remote_manifest_mismatch" "" "error" "backup_remote_missing"
        return 1
    fi

    if ! backup_remote_includes_node_id "$BACKUP_REMOTE" "${ADEMA_NODE_ID:-}"; then
        echo "ERROR: BACKUP_REMOTE debe incluir ADEMA_NODE_ID (${ADEMA_NODE_ID:-sin_id}). Actual: $BACKUP_REMOTE"
        audit_event "remote_manifest_mismatch" "" "error" "remote_without_node_id remote=$BACKUP_REMOTE node_id=${ADEMA_NODE_ID:-}"
        [ "$force" -eq 1 ] || return 1
    fi

    if ! resolve_rclone_config; then
        echo "ERROR: No se pudo resolver RCLONE_CONFIG para validar manifiesto remoto."
        return 1
    fi

    tmp_dir="$(mktemp -d)"
    existing_manifest="$tmp_dir/existing_node_manifest.json"
    new_manifest="$tmp_dir/node_manifest.json"
    remote_manifest="$(remote_node_manifest_path)"

    if rclone copyto "$remote_manifest" "$existing_manifest" --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
        existing_uuid="$(manifest_json_value "$existing_manifest" "ADEMA_NODE_UUID")"
        existing_created_at="$(manifest_json_value "$existing_manifest" "created_at")"
        if [ -n "$existing_uuid" ] && [ "$existing_uuid" != "${ADEMA_NODE_UUID:-}" ]; then
            echo "ERROR: $remote_manifest pertenece a otro ADEMA_NODE_UUID."
            echo "       remoto=$existing_uuid local=${ADEMA_NODE_UUID:-}"
            audit_event "remote_manifest_mismatch" "" "error" "remote=$remote_manifest remote_uuid=$existing_uuid local_uuid=${ADEMA_NODE_UUID:-}"
            if [ "$force" -ne 1 ]; then
                rm -rf "$tmp_dir"
                return 2
            fi
        fi
    fi

    write_node_manifest_file "$new_manifest" "${existing_created_at:-${NODE_CREATED_AT:-}}"
    rclone copyto "$new_manifest" "$remote_manifest" --config "$RCLONE_CONFIG" >/dev/null
    if [ -n "${existing_uuid:-}" ]; then
        audit_event "remote_manifest_created" "" "success" "updated remote=$remote_manifest"
    else
        audit_event "remote_manifest_created" "" "success" "created remote=$remote_manifest"
    fi
    rm -rf "$tmp_dir"
    return 0
}