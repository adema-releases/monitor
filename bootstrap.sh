#!/bin/bash
set -euo pipefail
# ADEMA Node Lite - bootstrap liviano para VM limpia

REPO_URL="${ADEMA_NODE_REPO:-https://github.com/adema-releases/monitor.git}"
TARGET_DIR="${ADEMA_NODE_DIR:-/opt/adema-node}"
REF="${ADEMA_NODE_REF:-main}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: ejecuta con sudo/root."
    exit 1
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    echo "Error: no se pudo detectar el sistema operativo."
    exit 1
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        if ! echo "${ID_LIKE:-}" | grep -Eq '(^| )(debian|ubuntu)( |$)'; then
            echo "Error: este bootstrap soporta Ubuntu/Debian. Detectado: ${PRETTY_NAME:-desconocido}"
            exit 1
        fi
        ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates curl

if [ -d "$TARGET_DIR/.git" ]; then
    echo "Actualizando repo en $TARGET_DIR..."
    git -C "$TARGET_DIR" fetch --tags origin
    git -C "$TARGET_DIR" checkout "$REF"
    git -C "$TARGET_DIR" pull --ff-only origin "$REF" || true
else
    echo "Clonando $REPO_URL en $TARGET_DIR..."
    rm -rf "$TARGET_DIR"
    git clone --branch "$REF" "$REPO_URL" "$TARGET_DIR"
fi

chmod +x "$TARGET_DIR/bootstrap_node.sh"
exec /bin/bash "$TARGET_DIR/bootstrap_node.sh" "$@"