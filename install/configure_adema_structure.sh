#!/bin/bash
set -euo pipefail

PROJECT_CODE="${PROJECT_CODE:-adema}"
mkdir -p "/var/lib/${PROJECT_CODE}/backups_locales" /etc/adema/tenants /var/log/adema-node
touch /var/log/adema-node/audit.jsonl
chmod 700 /etc/adema/tenants
chmod 750 /var/log/adema-node
chmod 640 /var/log/adema-node/audit.jsonl
echo "Estructura ADEMA creada para $PROJECT_CODE."