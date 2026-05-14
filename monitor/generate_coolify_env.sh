#!/bin/bash
set -euo pipefail
# Adema Core - Genera variables listas para Coolify
# Uso: sudo ./generate_coolify_env.sh CLIENT_ID [--no-password-output]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID="${1:-}"
SHOW_DB_PASSWORD=1

shift || true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-password-output)
            SHOW_DB_PASSWORD=0
            ;;
        -h|--help)
            echo "Uso: sudo ./generate_coolify_env.sh CLIENT_ID [--no-password-output]"
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $1"
            exit 1
            ;;
    esac
    shift
done

if ! ensure_client_id "$CLIENT_ID"; then
    echo "Uso: sudo ./generate_coolify_env.sh CLIENT_ID [--no-password-output]"
    exit 1
fi

DB_NAME="$(db_name "$CLIENT_ID")"
DB_USER="$(db_user "$CLIENT_ID")"
DB_PASSWORD="${DB_PASSWORD:-}"

if load_tenant_env "$CLIENT_ID"; then
    DB_NAME="${DB_NAME:-$(db_name "$CLIENT_ID")}" 
    DB_USER="${DB_USER:-$(db_user "$CLIENT_ID")}" 
    DB_PASSWORD="${DB_PASSWORD:-}"
fi

if [ -z "$DB_PASSWORD" ] && [ "$SHOW_DB_PASSWORD" -eq 1 ]; then
    echo "Error: no se encontro DB_PASSWORD para $CLIENT_ID."
    echo "Revisa $(tenant_env_file "$CLIENT_ID") o usa --no-password-output."
    audit_event "generate_env" "$CLIENT_ID" "error" "missing_password"
    exit 1
fi

print_coolify_env "$CLIENT_ID" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$SHOW_DB_PASSWORD"
audit_event "generate_env" "$CLIENT_ID" "success" "password_output=$SHOW_DB_PASSWORD"