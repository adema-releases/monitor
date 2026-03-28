API_KEY="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"

#!/bin/bash
# ==============================================================================
# Telemetría Avanzada y Auditoría - Adema Sistemas (Versión POSIX)
# Ruta: /home/adema/scripts/adema_monitor.sh
# ==============================================================================

# 1. Configuración de API
DESTINATARIO="ademasistemas@gmail.com"
REMITENTE="contact@ademasistemas.com"

# 2. Recolección de Métricas del Host
FECHA_ACTUAL=$(date +'%d/%m/%Y %H:%M')
NODOS_ACTIVOS=$(docker ps --format '{{.Names}}' | grep -v -E "coolify|NAMES" | wc -l)

RAM_USO=$(free -m | awk 'NR==2{printf "%sMB/%sMB (%.2f%%)", $3,$2,$3*100/$2 }')
SWAP_USO=$(free -m | awk 'NR==3{printf "%sMB/%sMB", $3,$2 }')
CPU_CARGA=$(uptime | awk -F'load average:' '{ print $2 }' | xargs)
DISCO_USO=$(df -h / | awk 'NR==2{print $5}')

# 3. Recolección de Métricas de Contenedores (Corregido a .Name en singular)
STATS_RAW=$(docker stats --no-stream --format '{{.Name}} | Uso CPU: {{.CPUPerc}} | Uso RAM: {{.MemUsage}}' | grep -v -E "coolify|NAME")

# 4. Construcción del Cuerpo del Mensaje
ASUNTO="CLUSTER-001-AESTOCK | Nodos: $NODOS_ACTIVOS | Estado: OK"

# Usamos formato POSIX estricto para concatenar texto (sin usar +=)
BODY_TEXT="REPORTE DE OPERACIONES: CLUSTER-ADESTOCK-NODO-01\n"
BODY_TEXT="${BODY_TEXT}Fecha: $FECHA_ACTUAL\n\n"
BODY_TEXT="${BODY_TEXT}[ MÉTRICAS DEL SERVIDOR BASE ]\n"
BODY_TEXT="${BODY_TEXT}RAM Física: $RAM_USO\n"
BODY_TEXT="${BODY_TEXT}Memoria SWAP: $SWAP_USO\n"
BODY_TEXT="${BODY_TEXT}Carga CPU (1m, 5m, 15m): $CPU_CARGA\n"
BODY_TEXT="${BODY_TEXT}Almacenamiento NVMe: $DISCO_USO\n\n"

BODY_TEXT="${BODY_TEXT}[ ESTADO POR INQUILINO (POSTGRESQL + BACKUPS) ]\n"

JSON_AGENT="\"inquilinos\": ["
DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE 'adestock_db_%';")

if [ -z "$DATABASES" ]; then
    BODY_TEXT="${BODY_TEXT}No se encontraron bases de datos de inquilinos.\n"
else
    FIRST_ITEM=true
    for DB in $DATABASES; do
        CLIENT_ID=${DB#adestock_db_}
        BACKUP_FILE="/var/lib/adestock/backups_locales/${DB}_latest.sql.gz"
        
        DB_BYTES=$(sudo -u postgres psql -t -A -c "SELECT pg_database_size('$DB');")
        DB_MB=$(( DB_BYTES / 1048576 ))
        
        if [ -f "$BACKUP_FILE" ]; then
            LAST_BACKUP=$(stat -c '%y' "$BACKUP_FILE" | cut -d'.' -f1)
            ESTADO_DB="OK ($LAST_BACKUP)"
        else
            ESTADO_DB="CRÍTICO (Sin backup reciente)"
            ASUNTO="CLUSTER-001-AESTOCK | ⚠️ ALERTA BACKUP: $CLIENT_ID"
        fi

        BODY_TEXT="${BODY_TEXT}> Cliente: $CLIENT_ID\n"
        BODY_TEXT="${BODY_TEXT}  - Tamaño Base de Datos: ${DB_MB} MB\n"
        BODY_TEXT="${BODY_TEXT}  - Estado de Backup: $ESTADO_DB\n"
        
        if [ "$FIRST_ITEM" = true ]; then FIRST_ITEM=false; else JSON_AGENT="${JSON_AGENT},"; fi
        JSON_AGENT="${JSON_AGENT}{\"cliente\": \"$CLIENT_ID\", \"db_size_mb\": $DB_MB, \"estado_backup\": \"$ESTADO_DB\"}"
    done
    JSON_AGENT="${JSON_AGENT}]"
fi

BODY_TEXT="${BODY_TEXT}\n[ RENDIMIENTO DE CONTENEDORES (EN VIVO) ]\n"

# Formateo sin usar <<< para evitar errores de sintaxis en dash/sh
STATS_FORMATTED=$(echo "$STATS_RAW" | sed 's/^/- /')
BODY_TEXT="${BODY_TEXT}${STATS_FORMATTED}\n"

# 5. Inyección del Payload IA
BODY_TEXT="${BODY_TEXT}\n\n--- INICIO PAYLOAD IA ---\n"
BODY_TEXT="${BODY_TEXT}{\n"
BODY_TEXT="${BODY_TEXT}  \"cluster_id\": \"CLUSTER-ADESTOCK-NODO-01\",\n"
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

JSON_BODY=$(echo -e "$BODY_TEXT" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')

# 6. Ejecución
cat <<EOF > /tmp/brevo_payload.json
{
  "sender": { "email": "$REMITENTE", "name": "Adema Operaciones" },
  "to": [ { "email": "$DESTINATARIO" } ],
  "subject": "$ASUNTO",
  "textContent": "$JSON_BODY"
}
EOF

curl -s -X POST 'https://api.brevo.com/v3/smtp/email' \
     -H 'accept: application/json' \
     -H "api-key: $API_KEY" \
     -H 'content-type: application/json' \
     -d @/tmp/brevo_payload.json > /dev/null

rm /tmp/brevo_payload.json
