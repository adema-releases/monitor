#!/bin/bash
set -euo pipefail
# Adema Core - Health snapshot
# Repo oficial: https://github.com/adema-releases/monitor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

json_escape() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1])[1:-1], end="")' "$1"
}

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME_VALUE=$(hostname)
UPTIME_TEXT=$(uptime -p 2>/dev/null || uptime)
LOAD_AVG=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)
DISK_USAGE=$(df -h / | awk 'NR==2{print $5}')
RAM_TOTAL_MB=$(free -m | awk 'NR==2{print $2}')
RAM_USED_MB=$(free -m | awk 'NR==2{print $3}')
SWAP_TOTAL_MB=$(free -m | awk 'NR==3{print $2}')
SWAP_USED_MB=$(free -m | awk 'NR==3{print $3}')
DOCKER0_IP=$(detect_docker0_ip || true)
ACTIVE_DB_HOST="${DOCKER0_IP:-$DB_HOST}"

if ! CONTAINERS_RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | awk -v re="${EXCLUDE_CONTAINER_REGEX:-^$}" 'NF && $0 !~ re {count++} END {print count+0}'); then
    # Si docker no esta disponible o falla, devolvemos 0 para no romper el snapshot.
    CONTAINERS_RUNNING=0
fi

DATABASES_RAW=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE '${DB_NAME_PREFIX}_%';" 2>/dev/null || true)
DOCKER_STATS_RAW=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.PIDs}}' 2>/dev/null || true)

printf '{'
printf '"timestamp":"%s",' "$(json_escape "$TIMESTAMP")"
printf '"cluster_id":"%s",' "$(json_escape "$CLUSTER_ID")"
printf '"project_code":"%s",' "$(json_escape "$PROJECT_CODE")"

printf '"host":{'
printf '"hostname":"%s",' "$(json_escape "$HOSTNAME_VALUE")"
printf '"uptime":"%s",' "$(json_escape "$UPTIME_TEXT")"
printf '"load_avg":"%s",' "$(json_escape "$LOAD_AVG")"
printf '"disk_root_usage":"%s",' "$(json_escape "$DISK_USAGE")"
printf '"docker0_ip":"%s",' "$(json_escape "$DOCKER0_IP")"
printf '"ram":{"total_mb":%s,"used_mb":%s},' "${RAM_TOTAL_MB:-0}" "${RAM_USED_MB:-0}"
printf '"swap":{"total_mb":%s,"used_mb":%s}' "${SWAP_TOTAL_MB:-0}" "${SWAP_USED_MB:-0}"
printf '},'

printf '"database":{'
printf '"host":"%s",' "$(json_escape "$ACTIVE_DB_HOST")"
printf '"port":%s' "${DB_PORT:-5432}"
printf '},'

printf '"containers":{"running":%s,"stats":[' "${CONTAINERS_RUNNING:-0}"
FIRST=1
while IFS='|' read -r C_NAME C_CPU C_MEM_USAGE C_MEM_PERC C_PIDS; do
    [ -n "$C_NAME" ] || continue
    if echo "$C_NAME" | grep -Eq "$EXCLUDE_CONTAINER_REGEX"; then
        continue
    fi

    if [ "$FIRST" -eq 0 ]; then
        printf ','
    fi
    FIRST=0

    printf '{'
    printf '"name":"%s",' "$(json_escape "$C_NAME")"
    printf '"cpu":"%s",' "$(json_escape "$C_CPU")"
    printf '"memory_usage":"%s",' "$(json_escape "$C_MEM_USAGE")"
    printf '"memory_percent":"%s",' "$(json_escape "$C_MEM_PERC")"
    printf '"pids":"%s"' "$(json_escape "$C_PIDS")"
    printf '}'
done <<EOF
$DOCKER_STATS_RAW
EOF
printf ']},'

printf '"databases":['
FIRST_DB=1
for DB in $DATABASES_RAW; do
    [ -n "$DB" ] || continue
    CLIENT_ID="${DB#${DB_NAME_PREFIX}_}"
    if [ "$FIRST_DB" -eq 0 ]; then
        printf ','
    fi
    FIRST_DB=0

    printf '{'
    printf '"db_name":"%s",' "$(json_escape "$DB")"
    printf '"client_id":"%s"' "$(json_escape "$CLIENT_ID")"
    printf '}'
done
printf ']'

printf '}'
printf '\n'
