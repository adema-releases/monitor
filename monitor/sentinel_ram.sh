#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

ALERTAS=""
STATS_RAW=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' | grep -v -E "$EXCLUDE_CONTAINER_REGEX")

while IFS='|' read -r NOME MEM_RAW; do
    USAGE=$(echo "$MEM_RAW" | awk -F'/' '{print $1}' | tr -d ' ')
    VALOR=$(echo "$USAGE" | sed 's/[A-Za-z]*//g')
    UNIDAD=$(echo "$USAGE" | sed 's/[0-9.]*//g')

    ALERTA_FLAG=0
    if [[ "$UNIDAD" == *"GiB"* || "$UNIDAD" == *"GB"* ]]; then
        ALERTA_FLAG=1
    elif [[ "$UNIDAD" == *"MiB"* || "$UNIDAD" == *"MB"* ]]; then
        ES_MAYOR=$(awk -v v="$VALOR" -v u="$RAM_THRESHOLD_MB" 'BEGIN {if (v > u) print 1; else print 0}')
        if [ "$ES_MAYOR" -eq 1 ]; then
            ALERTA_FLAG=1
        fi
    fi

    if [ "$ALERTA_FLAG" -eq 1 ]; then
        ALERTAS="${ALERTAS}> Contenedor: $NOME | RAM: $USAGE (Limite: ${RAM_THRESHOLD_MB}MB)\n"
    fi
done <<< "$STATS_RAW"

if [ -n "$ALERTAS" ]; then
    FECHA_ACTUAL=$(date +'%d/%m/%Y %H:%M')
    ASUNTO="[URGENTE] $CLUSTER_ID | Saturacion de RAM"

    BODY_TEXT="ALERTA DE INFRAESTRUCTURA: $CLUSTER_ID\n"
    BODY_TEXT="${BODY_TEXT}Proyecto: $PROJECT_CODE\n"
    BODY_TEXT="${BODY_TEXT}Fecha: $FECHA_ACTUAL\n\n"
    BODY_TEXT="${BODY_TEXT}Se detectaron contenedores con uso de RAM por encima del umbral ${RAM_THRESHOLD_MB}MB.\n\n"
    BODY_TEXT="${BODY_TEXT}[ DETALLE ]\n"
    BODY_TEXT="${BODY_TEXT}${ALERTAS}\n"

    send_brevo_email "$ASUNTO" "$BODY_TEXT"
fi