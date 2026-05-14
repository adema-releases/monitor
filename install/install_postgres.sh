#!/bin/bash
set -euo pipefail

apt-get update
apt-get install -y postgresql postgresql-contrib postgresql-client
systemctl enable --now postgresql
echo "PostgreSQL instalado/activo."