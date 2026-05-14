#!/bin/bash
set -euo pipefail

if ! command -v psql >/dev/null 2>&1; then
    echo "PostgreSQL client no disponible."
    exit 1
fi

CONFIG_FILE="$(sudo -u postgres psql -t -A -c "SHOW config_file;" | tr -d '[:space:]')"
HBA_FILE="$(sudo -u postgres psql -t -A -c "SHOW hba_file;" | tr -d '[:space:]')"

set_conf() {
    local key="$1"
    local value="$2"
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$CONFIG_FILE"
    else
        printf '\n%s = %s\n' "$key" "$value" >> "$CONFIG_FILE"
    fi
}

set_conf "password_encryption" "'scram-sha-256'"
set_conf "listen_addresses" "'*'"

if ! grep -q 'ADEMA Node Lite docker networks' "$HBA_FILE"; then
    cat >> "$HBA_FILE" <<'EOF'

# ADEMA Node Lite docker networks
host    all             all             172.16.0.0/12           scram-sha-256
host    all             all             10.0.0.0/8              scram-sha-256
host    all             all             192.168.0.0/16          scram-sha-256
EOF
fi

systemctl restart postgresql
echo "PostgreSQL endurecido: SCRAM + pg_hba para redes internas Docker/LAN."