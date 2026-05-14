#!/bin/bash
set -euo pipefail
# Desactiva Nginx del host con backup previo. No purga salvo --purge.

PURGE=0
if [ "${1:-}" = "--purge" ]; then
    PURGE=1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta con sudo/root."
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1 && ! dpkg -s nginx >/dev/null 2>&1; then
    echo "[OK] Nginx no esta instalado. No hay nada que desactivar."
    exit 0
fi

BACKUP_DIR="/etc/adema/backups/nginx-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "[WARN] Este script desactiva Nginx del host para dejar 80/443 a Coolify/Traefik."
echo "[INFO] Backup previo: $BACKUP_DIR"

for path in /etc/nginx/nginx.conf /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d; do
    if [ -e "$path" ]; then
        cp -a "$path" "$BACKUP_DIR/"
    fi
done

if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl disable --now nginx
    echo "[OK] Nginx deshabilitado y detenido."
else
    echo "[WARN] nginx.service no existe en systemd; se omitio systemctl disable."
fi

if [ "$PURGE" -eq 1 ]; then
    echo
    echo "[WARN] --purge solicitado. Se desinstalara Nginx despues del backup."
    read -r -p "Escribe PURGAR NGINX para continuar: " CONFIRM
    if [ "$CONFIRM" = "PURGAR NGINX" ]; then
        apt-get purge -y nginx nginx-common nginx-core || apt-get purge -y nginx
        apt-get autoremove -y
        echo "[OK] Nginx purgado. Backup conservado en $BACKUP_DIR"
    else
        echo "[INFO] Purge cancelado. Nginx quedo deshabilitado."
    fi
fi

echo "[OK] Listo. Verifica que Coolify/Traefik use 80/443 con: sudo ss -tulpn | grep -E ':80|:443'"