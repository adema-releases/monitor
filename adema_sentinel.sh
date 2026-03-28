
#!/bin/bash
# ==============================================================================
# Centinela de Consumo (Watchdog) - Adema Sistemas
# Ruta: /home/adema/scripts/adema_sentinel.sh
# ==============================================================================

# 1. Configuración
source /root/.adestock_secrets
API_KEY=$BREVO_API_KEY
DESTINATARIO="ademasistemas@gmail.com"
REMITENTE="contact@ademasistemas.com"

# Límite de RAM en Megabytes (3x el estimado base de 150MB)
UMBRAL_MB=450
ALERTAS=""

# 2. Extracción de Métricas de Contenedores
STATS_RAW=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' | grep -v -E "coolify|NAME")

# 3. Procesamiento y Detección de Anomalías
while IFS='|' read -r NOME MEM_RAW; do
    # MEM_RAW tiene el formato "152.9MiB / 3.824GiB"
    # Extraemos solo el consumo actual y quitamos espacios
    USAGE=$(echo "$MEM_RAW" | awk -F'/' '{print $1}' | tr -d ' ')
    
    # Separamos el valor numérico de la unidad de medida
    VALOR=$(echo "$USAGE" | sed 's/[A-Za-z]*//g')
    UNIDAD=$(echo "$USAGE" | sed 's/[0-9.]*//g')
    
    ALERTA_FLAG=0
    
    # Si la unidad es GiB o GB, ya superó el umbral estructural
    if [[ "$UNIDAD" == *"GiB"* || "$UNIDAD" == *"GB"* ]]; then
        ALERTA_FLAG=1
    elif [[ "$UNIDAD" == *"MiB"* || "$UNIDAD" == *"MB"* ]]; then
        # Comparamos el valor de consumo contra el umbral establecido
        ES_MAYOR=$(awk -v v="$VALOR" -v u="$UMBRAL_MB" 'BEGIN {if (v > u) print 1; else print 0}')
        if [ "$ES_MAYOR" -eq 1 ]; then
            ALERTA_FLAG=1
        fi
    fi

    if [ "$ALERTA_FLAG" -eq 1 ]; then
        ALERTAS="${ALERTAS}> Inquilino: $NOME | Consumo Actual: $USAGE (Límite tolerado: ${UMBRAL_MB}MB)\n"
    fi
done <<< "$STATS_RAW"

# 4. Disparo de Alerta Prioritaria
if [ -n "$ALERTAS" ]; then
    FECHA_ACTUAL=$(date +'%d/%m/%Y %H:%M')
    ASUNTO="[URGENTE] CLUSTER-001-AESTOCK | Saturación de RAM Detectada"
    
    BODY_TEXT="ALERTA DE INFRAESTRUCTURA: CLUSTER-ADESTOCK-NODO-01\n"
    BODY_TEXT="${BODY_TEXT}Fecha: $FECHA_ACTUAL\n\n"
    BODY_TEXT="${BODY_TEXT}Se ha detectado uno o más nodos superando el umbral crítico de ${UMBRAL_MB}MB de memoria RAM. Esto representa un riesgo directo de paginación (SWAP) que degradará la latencia del resto de los clientes.\n\n"
    BODY_TEXT="${BODY_TEXT}[ DETALLE DE LA ANOMALÍA ]\n"
    BODY_TEXT="${BODY_TEXT}${ALERTAS}\n\n"
    BODY_TEXT="${BODY_TEXT}Acción requerida: Revisión de logs del contenedor para identificar fugas de memoria (memory leaks) o cuellos de botella en consultas a base de datos."

    JSON_BODY=$(echo -e "$BODY_TEXT" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')

    cat <<EOF > /tmp/brevo_alert_payload.json
{
  "sender": { "email": "$REMITENTE", "name": "Adema Centinela" },
  "to": [ { "email": "$DESTINATARIO" } ],
  "subject": "$ASUNTO",
  "textContent": "$JSON_BODY"
}
EOF

    curl -s -X POST 'https://api.brevo.com/v3/smtp/email' \
         -H 'accept: application/json' \
         -H "api-key: $API_KEY" \
         -H 'content-type: application/json' \
         -d @/tmp/brevo_alert_payload.json > /dev/null

    rm -f /tmp/brevo_alert_payload.json
fi
