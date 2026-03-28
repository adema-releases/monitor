#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

FECHA_ACTUAL=$(date +'%d/%m/%Y %H:%M')
NODOS_ACTIVOS=$(docker ps --format '{{.Names}}' | grep -v -E "$EXCLUDE_CONTAINER_REGEX" | wc -l)

RAM_USO=$(free -m | awk 'NR==2{printf "%sMB/%sMB (%.2f%%)", $3,$2,$3*100/$2 }')
SWAP_USO=$(free -m | awk 'NR==3{printf "%sMB/%sMB", $3,$2 }')
CPU_CARGA=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)
DISCO_USO=$(df -h / | awk 'NR==2{print $5}')

STATS_RAW=$(docker stats --no-stream --format '{{.Name}} | CPU: {{.CPUPerc}} | RAM: {{.MemUsage}}' | grep -v -E "$EXCLUDE_CONTAINER_REGEX")
ASUNTO="$CLUSTER_ID | Proyecto: $PROJECT_CODE | Nodos: $NODOS_ACTIVOS | Estado: OK"

BODY_TEXT="REPORTE DE OPERACIONES: $CLUSTER_ID\n"
BODY_TEXT="${BODY_TEXT}Proyecto: $PROJECT_CODE\n"
BODY_TEXT="${BODY_TEXT}Fecha: $FECHA_ACTUAL\n\n"
BODY_TEXT="${BODY_TEXT}[ METRICAS HOST ]\n"
BODY_TEXT="${BODY_TEXT}RAM: $RAM_USO\n"
BODY_TEXT="${BODY_TEXT}SWAP: $SWAP_USO\n"
BODY_TEXT="${BODY_TEXT}CPU (1m, 5m, 15m): $CPU_CARGA\n"
BODY_TEXT="${BODY_TEXT}DISCO: $DISCO_USO\n\n"
BODY_TEXT="${BODY_TEXT}[ ESTADO POR CLIENTE ]\n"

JSON_AGENT="\"inquilinos\": ["
DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE '${DB_NAME_PREFIX}_%';")

if [ -z "$DATABASES" ]; then
    BODY_TEXT="${BODY_TEXT}No se encontraron bases de datos para este proyecto.\n"
else
    FIRST_ITEM=true
    for DB in $DATABASES; do
        CLIENT_ID=${DB#${DB_NAME_PREFIX}_}
        BACKUP_FILE="$BACKUP_DIR/${DB}_latest.sql.gz"
        DB_BYTES=$(sudo -u postgres psql -t -A -c "SELECT pg_database_size('$DB');")
        DB_MB=$((DB_BYTES / 1048576))

        if [ -f "$BACKUP_FILE" ]; then
            LAST_BACKUP=$(stat -c '%y' "$BACKUP_FILE" | cut -d'.' -f1)
            ESTADO_DB="OK ($LAST_BACKUP)"
        else
            ESTADO_DB="CRITICO (Sin backup reciente)"
            ASUNTO="$CLUSTER_ID | ALERTA BACKUP: $CLIENT_ID"
        fi

        BODY_TEXT="${BODY_TEXT}> Cliente: $CLIENT_ID\n"
        BODY_TEXT="${BODY_TEXT}  - DB Size: ${DB_MB} MB\n"
        BODY_TEXT="${BODY_TEXT}  - Backup: $ESTADO_DB\n"

        if [ "$FIRST_ITEM" = true ]; then FIRST_ITEM=false; else JSON_AGENT="${JSON_AGENT},"; fi
        JSON_AGENT="${JSON_AGENT}{\"cliente\": \"$CLIENT_ID\", \"db_size_mb\": $DB_MB, \"estado_backup\": \"$ESTADO_DB\"}"
    done
    JSON_AGENT="${JSON_AGENT}]"
fi

BODY_TEXT="${BODY_TEXT}\n[ RENDIMIENTO CONTENEDORES ]\n"
STATS_FORMATTED=$(echo "$STATS_RAW" | sed 's/^/- /')
BODY_TEXT="${BODY_TEXT}${STATS_FORMATTED}\n"

BODY_TEXT="${BODY_TEXT}\n--- INICIO PAYLOAD IA ---\n"
BODY_TEXT="${BODY_TEXT}{\n"
BODY_TEXT="${BODY_TEXT}  \"cluster_id\": \"$CLUSTER_ID\",\n"
BODY_TEXT="${BODY_TEXT}  \"proyecto\": \"$PROJECT_CODE\",\n"
BODY_TEXT="${BODY_TEXT}  \"timestamp\": \"$FECHA_ACTUAL\",\n"
BODY_TEXT="${BODY_TEXT}  \"metricas_host\": {\n"
BODY_TEXT="${BODY_TEXT}    \"ram_uso\": \"$RAM_USO\",\n"
BODY_TEXT="${BODY_TEXT}    \"swap_uso\": \"$SWAP_USO\",\n"
BODY_TEXT="${BODY_TEXT}    \"cpu_carga\": \"$CPU_CARGA\",\n"
BODY_TEXT="${BODY_TEXT}    \"disco_uso\": \"$DISCO_USO\"\n"
BODY_TEXT="${BODY_TEXT}  },\n"
BODY_TEXT="${BODY_TEXT}  $JSON_AGENT\n"
BODY_TEXT="${BODY_TEXT}}\n"
BODY_TEXT="${BODY_TEXT}--- FIN PAYLOAD IA ---\n"

send_brevo_email "$ASUNTO" "$BODY_TEXT"