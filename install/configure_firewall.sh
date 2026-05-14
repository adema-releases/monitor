#!/bin/bash
set -euo pipefail

apt-get install -y ufw
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

remove_open_5432_anywhere() {
    local line_num
    while true; do
        line_num=$(ufw status numbered | awk '/5432\/tcp/ && /ALLOW IN/ && /Anywhere/ {gsub(/\[|\]/, "", $1); print $1; exit}')
        [ -n "$line_num" ] || break
        ufw --force delete "$line_num" >/dev/null || true
    done
}

remove_open_5432_anywhere
ufw allow from 172.16.0.0/12 to any port 5432 proto tcp >/dev/null 2>&1 || true
ufw allow from 10.0.0.0/8 to any port 5432 proto tcp >/dev/null 2>&1 || true
ufw allow from 192.168.0.0/16 to any port 5432 proto tcp >/dev/null 2>&1 || true
ufw deny in to any port 5432 proto tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null
echo "UFW configurado: SSH/80/443 abiertos, 5432 protegido."