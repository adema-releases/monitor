#!/bin/bash
set -euo pipefail
# ADEMA Node Lite - instalacion idempotente del nodo

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$ROOT_DIR/install"
MONITOR_DIR="$ROOT_DIR/monitor"
ENV_FILE="$MONITOR_DIR/.monitor.env"
NODE_ENV_FILE="/etc/adema/node.env"
REGENERATE_NODE_IDENTITY=0
NODE_ENV_EXISTED=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --regenerate-node-identity)
            REGENERATE_NODE_IDENTITY=1
            ;;
        -h|--help)
            cat <<HELP
Uso: sudo bash bootstrap_node.sh [--regenerate-node-identity]

Opciones:
  --regenerate-node-identity  Regenera ADEMA_NODE_UUID de forma explicita.
HELP
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $1"
            exit 1
            ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta bootstrap_node.sh con sudo/root."
    exit 1
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    echo "Error: no se pudo leer /etc/os-release."
    exit 1
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        if ! echo "${ID_LIKE:-}" | grep -Eq '(^| )(debian|ubuntu)( |$)'; then
            echo "Error: sistema no soportado: ${PRETTY_NAME:-desconocido}"
            exit 1
        fi
        ;;
esac

ask_value() {
    local name="$1"
    local default_value="$2"
    local current_value="${!name:-}"
    local answer

    if [ -n "$current_value" ]; then
        echo "$current_value"
        return
    fi

    if [ -t 0 ]; then
        read -r -p "$name [$default_value]: " answer
        echo "${answer:-$default_value}"
    else
        echo "$default_value"
    fi
}

ask_bool() {
    local name="$1"
    local default_value="$2"
    local value
    value="$(ask_value "$name" "$default_value")"
    case "$value" in
        1|y|Y|yes|YES|true|TRUE|si|SI) echo 1 ;;
        *) echo 0 ;;
    esac
}

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

sanitize_node_id() {
    local raw="${1:-}"
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
    echo "${raw:-adema-node}"
}

is_generic_value() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        ''|demo|test|default|node|local|ubuntu|debian|server|vps|cluster-local|cluster-demo-01|demo-node|test-node|adema-demo)
            return 0
            ;;
    esac
    return 1
}

ensure_not_generic_or_exit() {
    local name="$1"
    local value="$2"
    local allow_dev="${3:-0}"
    if is_generic_value "$value"; then
        if [ "$allow_dev" -eq 1 ] && [ "${ADEMA_DEV_MODE:-0}" = "1" ]; then
            echo "WARN: $name usa valor generico en modo desarrollo: $value"
            return 0
        fi
        echo "ERROR: $name no puede quedar con valor generico/default: $value"
        echo "Define un valor real antes de continuar. Ejemplo: ADEMA_NODE_ID=gdc-node-001"
        exit 1
    fi
}

require_safe_node_id() {
    local value="$1"
    if ! echo "$value" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        echo "ERROR: ADEMA_NODE_ID solo puede tener letras, numeros, guion y guion bajo. Valor: $value"
        exit 1
    fi
}

env_quote() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g'
}

if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
fi

if [ -f "$NODE_ENV_FILE" ]; then
    NODE_ENV_EXISTED=1
    # shellcheck source=/dev/null
    . "$NODE_ENV_FILE"
fi

DEFAULT_NODE_ID="$(sanitize_node_id "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo adema-node)")"
if is_generic_value "$DEFAULT_NODE_ID"; then
    DEFAULT_NODE_ID="adema-node-$(generate_uuid | cut -c1-8)"
fi

ADEMA_NODE_ID="$(ask_value ADEMA_NODE_ID "${ADEMA_NODE_ID:-$DEFAULT_NODE_ID}")"
require_safe_node_id "$ADEMA_NODE_ID"
ensure_not_generic_or_exit "ADEMA_NODE_ID" "$ADEMA_NODE_ID" 0

if [ -n "${ADEMA_NODE_UUID:-}" ] && [ "$REGENERATE_NODE_IDENTITY" -eq 0 ]; then
    ADEMA_NODE_UUID="$ADEMA_NODE_UUID"
else
    if [ -f "$NODE_ENV_FILE" ] && [ "$REGENERATE_NODE_IDENTITY" -eq 1 ]; then
        cp -a "$NODE_ENV_FILE" "${NODE_ENV_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        echo "WARN: regenerando ADEMA_NODE_UUID por flag explicito."
    fi
    ADEMA_NODE_UUID="$(generate_uuid)"
fi

if ! echo "$ADEMA_NODE_UUID" | grep -Eiq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
    echo "ERROR: ADEMA_NODE_UUID invalido: $ADEMA_NODE_UUID"
    echo "Usa --regenerate-node-identity para regenerarlo de forma explicita."
    exit 1
fi

ADEMA_NODE_NAME="$(ask_value ADEMA_NODE_NAME "${ADEMA_NODE_NAME:-$ADEMA_NODE_ID}")"
PROJECT_CODE="$(ask_value PROJECT_CODE "${PROJECT_CODE:-adema}")"
CLUSTER_ID="$(ask_value CLUSTER_ID "${CLUSTER_ID:-$(printf '%s' "$ADEMA_NODE_ID" | tr '[:lower:]' '[:upper:]' | tr '_' '-')}")"
ADEMA_BASE_DOMAIN="$(ask_value ADEMA_BASE_DOMAIN "${ADEMA_BASE_DOMAIN:-${BASE_DOMAIN:-}}")"
if [ -n "$ADEMA_BASE_DOMAIN" ]; then
    ADEMA_INFRA_DOMAIN="$(ask_value ADEMA_INFRA_DOMAIN "${ADEMA_INFRA_DOMAIN:-infra.${ADEMA_BASE_DOMAIN}}")"
    ADEMA_DEPLOY_DOMAIN="$(ask_value ADEMA_DEPLOY_DOMAIN "${ADEMA_DEPLOY_DOMAIN:-deploy.${ADEMA_BASE_DOMAIN}}")"
else
    ADEMA_INFRA_DOMAIN="$(ask_value ADEMA_INFRA_DOMAIN "${ADEMA_INFRA_DOMAIN:-}")"
    ADEMA_DEPLOY_DOMAIN="$(ask_value ADEMA_DEPLOY_DOMAIN "${ADEMA_DEPLOY_DOMAIN:-}")"
fi
BACKUP_REMOTE="$(ask_value BACKUP_REMOTE "${BACKUP_REMOTE:-r2:adema-backups/${ADEMA_NODE_ID}}")"
NODE_CREATED_AT="${NODE_CREATED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

ensure_not_generic_or_exit "CLUSTER_ID" "$CLUSTER_ID" 0
ensure_not_generic_or_exit "PROJECT_CODE" "$PROJECT_CODE" 1
if ! echo "${BACKUP_REMOTE#*:}" | grep -Fq "$ADEMA_NODE_ID"; then
    echo "ERROR: BACKUP_REMOTE debe incluir ADEMA_NODE_ID para evitar colisiones entre nodos."
    echo "Actual: $BACKUP_REMOTE"
    echo "Ejemplo: adema-crypt:backups/$ADEMA_NODE_ID"
    exit 1
fi

write_monitor_env_file() {
    local project_code="$1"
    local cluster_id="$2"
    local backup_remote="$3"
    local base_domain="$4"
    local backup_dir="/var/lib/${project_code}/backups_locales"

    mkdir -p "$MONITOR_DIR" /etc/adema
    cat > "$ENV_FILE" <<EOF
PROJECT_CODE=$project_code
CLUSTER_ID=$cluster_id

DB_PREFIX=$project_code
DB_NAME_PREFIX=${project_code}_db
DB_USER_PREFIX=${project_code}_user

VOLUME_BASE_PATH=/var/lib/docker/volumes
VOLUME_PREFIX=$project_code
VOLUME_FOLDERS="license logs media"

BACKUP_DIR=$backup_dir
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
BACKUP_REMOTE=$backup_remote
RCLONE_CONFIG=${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}
TENANT_ENV_DIR=${TENANT_ENV_DIR:-/etc/adema/tenants}
ADEMA_AUDIT_LOG=${ADEMA_AUDIT_LOG:-/var/log/adema-node/audit.jsonl}

BASE_DOMAIN=$base_domain

BREVO_RECIPIENT=${BREVO_RECIPIENT:-}
BREVO_SENDER=${BREVO_SENDER:-}
BREVO_SENDER_NAME="${BREVO_SENDER_NAME:-Adema Core}"

SECRETS_FILE=${SECRETS_FILE:-/etc/adema/monitor.secrets}

DB_HOST=
DB_PORT=5432
RAM_THRESHOLD_MB=${RAM_THRESHOLD_MB:-450}
EXCLUDE_CONTAINER_REGEX="coolify|NAME"
EOF
    chown root:root "$ENV_FILE"
    chmod 640 "$ENV_FILE"

}

write_node_env_file() {
    mkdir -p /etc/adema
    cat > "$NODE_ENV_FILE" <<EOF
ADEMA_NODE_ID="$(env_quote "$ADEMA_NODE_ID")"
ADEMA_NODE_UUID="$(env_quote "$ADEMA_NODE_UUID")"
ADEMA_NODE_NAME="$(env_quote "$ADEMA_NODE_NAME")"
CLUSTER_ID="$(env_quote "$CLUSTER_ID")"
PROJECT_CODE="$(env_quote "$PROJECT_CODE")"
ADEMA_BASE_DOMAIN="$(env_quote "$ADEMA_BASE_DOMAIN")"
ADEMA_INFRA_DOMAIN="$(env_quote "$ADEMA_INFRA_DOMAIN")"
ADEMA_DEPLOY_DOMAIN="$(env_quote "$ADEMA_DEPLOY_DOMAIN")"
BACKUP_REMOTE="$(env_quote "$BACKUP_REMOTE")"
NODE_CREATED_AT="$(env_quote "$NODE_CREATED_AT")"
ADEMA_DEV_MODE=${ADEMA_DEV_MODE:-0}
INSTALL_PANEL=$INSTALL_PANEL
INSTALL_COOLIFY=$INSTALL_COOLIFY
COOLIFY_OMITTED=$([ "$INSTALL_COOLIFY" -eq 1 ] && echo 0 || echo 1)
EOF
    chown root:root "$NODE_ENV_FILE"
    chmod 640 "$NODE_ENV_FILE"
}

BASE_DOMAIN="$ADEMA_BASE_DOMAIN"
INSTALL_PANEL="$(ask_bool INSTALL_PANEL "0")"
INSTALL_COOLIFY="$(ask_bool INSTALL_COOLIFY "1")"

export ADEMA_NODE_ID ADEMA_NODE_UUID ADEMA_NODE_NAME PROJECT_CODE CLUSTER_ID BACKUP_REMOTE BASE_DOMAIN ADEMA_BASE_DOMAIN ADEMA_INFRA_DOMAIN ADEMA_DEPLOY_DOMAIN NODE_CREATED_AT INSTALL_PANEL INSTALL_COOLIFY
export ADEMA_NODE_ROOT="$ROOT_DIR"
export DEBIAN_FRONTEND=noninteractive

echo "== ADEMA Node Lite bootstrap =="
echo "Proyecto: $PROJECT_CODE"
echo "Nodo: $ADEMA_NODE_ID ($CLUSTER_ID)"
echo "Repo: $ROOT_DIR"

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release openssl sudo cron ufw python3 python3-venv python3-pip postgresql-client gzip coreutils

write_node_env_file
write_monitor_env_file "$PROJECT_CODE" "$CLUSTER_ID" "$BACKUP_REMOTE" "$BASE_DOMAIN"

/bin/bash "$INSTALL_DIR/configure_adema_structure.sh"
/bin/bash "$INSTALL_DIR/install_docker.sh"
if [ "$INSTALL_COOLIFY" -eq 1 ]; then
    /bin/bash "$INSTALL_DIR/install_coolify.sh"
else
    echo "Coolify omitido por configuracion."
fi
/bin/bash "$INSTALL_DIR/install_postgres.sh"
/bin/bash "$INSTALL_DIR/configure_postgres_security.sh"
/bin/bash "$INSTALL_DIR/install_rclone.sh"
/bin/bash "$INSTALL_DIR/configure_firewall.sh"
/bin/bash "$INSTALL_DIR/configure_backups.sh"
/bin/bash "$INSTALL_DIR/configure_permissions.sh"

ln -sf "$ROOT_DIR/adema-node" /usr/local/bin/adema-node
chmod 755 "$ROOT_DIR/adema-node"

if [ "$INSTALL_PANEL" -eq 1 ]; then
    /bin/bash "$ROOT_DIR/setup_web_panel.sh"
else
    echo "Panel web omitido. Se puede instalar despues con: sudo bash $ROOT_DIR/setup_web_panel.sh"
fi

if [ -f "$MONITOR_DIR/lib/common.sh" ]; then
    # shellcheck source=/dev/null
    . "$MONITOR_DIR/lib/common.sh"
    load_monitor_env
    if [ "$REGENERATE_NODE_IDENTITY" -eq 1 ]; then
        audit_event "node_identity_regenerated" "" "success" "node_id=$ADEMA_NODE_ID node_uuid=$ADEMA_NODE_UUID"
    elif [ "$NODE_ENV_EXISTED" -eq 0 ]; then
        audit_event "node_identity_created" "" "success" "node_id=$ADEMA_NODE_ID node_uuid=$ADEMA_NODE_UUID"
    fi
    audit_event "bootstrap" "" "success" "install_panel=$INSTALL_PANEL install_coolify=$INSTALL_COOLIFY"
    if command -v rclone >/dev/null 2>&1 && resolve_rclone_config; then
        ensure_remote_node_manifest 0 || true
    fi
fi

DOCKER0_IP="$(ip -o -4 addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
COOLIFY_URL="${ADEMA_DEPLOY_DOMAIN:+https://${ADEMA_DEPLOY_DOMAIN}}"
PANEL_URL="${ADEMA_INFRA_DOMAIN:+https://${ADEMA_INFRA_DOMAIN}}"

echo "=================================================="
echo "ADEMA Node Lite instalado/configurado"
echo "NODE_ID: $ADEMA_NODE_ID"
echo "NODE_UUID: $ADEMA_NODE_UUID"
echo "CLUSTER_ID: $CLUSTER_ID"
echo "PROJECT_CODE: $PROJECT_CODE"
echo "BACKUP_REMOTE: $BACKUP_REMOTE"
echo "INFRA_DOMAIN: ${ADEMA_INFRA_DOMAIN:-sin_configurar}"
echo "DEPLOY_DOMAIN: ${ADEMA_DEPLOY_DOMAIN:-sin_configurar}"
echo "Estado rapido: sudo adema-node doctor"
echo "Coolify sugerido: ${COOLIFY_URL:-http://IP_DEL_NODO:8000}"
if [ "$INSTALL_PANEL" -eq 1 ]; then
    echo "Panel sugerido: ${PANEL_URL:-http://127.0.0.1:5000}"
else
    echo "Panel web: omitido"
fi
echo "PostgreSQL interno: ${DOCKER0_IP:-127.0.0.1}:5432"
echo "Backups remote: $BACKUP_REMOTE"
echo "Proximo paso: sudo adema-node create-tenant cliente001"
echo "=================================================="