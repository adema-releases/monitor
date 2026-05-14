#!/bin/bash
set -euo pipefail

if docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'coolify|traefik'; then
    echo "Coolify/Traefik ya detectado."
    exit 0
fi

echo "Instalando Coolify con instalador oficial..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
echo "Coolify instalado o instalador finalizado."