#!/bin/bash
set -euo pipefail
# Uso: sudo ./delete_tenant.sh cli001

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

CLIENT_ID=""
FORCE_DELETE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE_DELETE=1
            ;;
        *)
            if [ -z "$CLIENT_ID" ]; then
                CLIENT_ID="$arg"
            else
                echo "Uso: sudo ./delete_tenant.sh cli001 [--force]"
                exit 1
            fi
            ;;
    esac
done

if ! ensure_client_id "$CLIENT_ID"; then
    echo "Uso: sudo ./delete_tenant.sh cli001 [--force]"
    exit 1
fi

DB_NAME=$(db_name "$CLIENT_ID")
DB_USER=$(db_user "$CLIENT_ID")
PREFIX=$(volume_namespace "$CLIENT_ID")

echo "ADVERTENCIA: vas a eliminar permanentemente los datos de $CLIENT_ID en $PROJECT_CODE."
if [ "$FORCE_DELETE" -eq 0 ]; then
    read -r -p "Confirmar eliminacion total (y/n): " confirm

    if [ "$confirm" != "y" ]; then
        echo "Operacion cancelada."
        exit 1
    fi
else
    echo "Modo no interactivo habilitado (--force)."
fi

echo "Eliminando base de datos y usuario SQL..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
sudo -u postgres psql -c "DROP USER IF EXISTS \"$DB_USER\";"

echo "Eliminando volumenes fisicos en el host..."
for folder in $VOLUME_FOLDERS; do
    sudo rm -rf "$VOLUME_BASE_PATH/${PREFIX}_$folder"
done

echo "Limpieza completa para $CLIENT_ID."