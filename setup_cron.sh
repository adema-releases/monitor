#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$ROOT_DIR/monitor"
ENV_FILE="$SCRIPTS_DIR/.monitor.env"
LOG_DIR="$ROOT_DIR/logs"

if [ ! -f "$ENV_FILE" ]; then
    echo "No existe $ENV_FILE"
    echo "Primero ejecuta: sudo bash run_monitor.sh y configura el entorno."
    exit 1
fi

mkdir -p "$LOG_DIR"

echo "Configurador de cron para Adema Core Django"
echo "Los jobs se instalaran en el crontab del usuario actual: $(whoami)"
echo

read -r -p "Hora backup diario (0-23) [2]: " BACKUP_HOUR
BACKUP_HOUR="${BACKUP_HOUR:-2}"

read -r -p "Minuto backup diario (0-59) [15]: " BACKUP_MIN
BACKUP_MIN="${BACKUP_MIN:-15}"

read -r -p "Frecuencia reporte Adema Core en horas [6]: " REPORT_EVERY_HOURS
REPORT_EVERY_HOURS="${REPORT_EVERY_HOURS:-6}"

read -r -p "Frecuencia sentinel en minutos [10]: " SENTINEL_EVERY_MIN
SENTINEL_EVERY_MIN="${SENTINEL_EVERY_MIN:-10}"

if ! echo "$BACKUP_HOUR" | grep -Eq '^[0-9]{1,2}$' || [ "$BACKUP_HOUR" -gt 23 ]; then
    echo "Valor invalido para hora backup"
    exit 1
fi

if ! echo "$BACKUP_MIN" | grep -Eq '^[0-9]{1,2}$' || [ "$BACKUP_MIN" -gt 59 ]; then
    echo "Valor invalido para minuto backup"
    exit 1
fi

if ! echo "$REPORT_EVERY_HOURS" | grep -Eq '^[0-9]{1,2}$' || [ "$REPORT_EVERY_HOURS" -lt 1 ] || [ "$REPORT_EVERY_HOURS" -gt 24 ]; then
    echo "Valor invalido para frecuencia de reporte"
    exit 1
fi

if ! echo "$SENTINEL_EVERY_MIN" | grep -Eq '^[0-9]{1,2}$' || [ "$SENTINEL_EVERY_MIN" -lt 1 ] || [ "$SENTINEL_EVERY_MIN" -gt 59 ]; then
    echo "Valor invalido para frecuencia de sentinel"
    exit 1
fi

BACKUP_EXPR="$BACKUP_MIN $BACKUP_HOUR * * *"
REPORT_EXPR="0 */$REPORT_EVERY_HOURS * * *"
SENTINEL_EXPR="*/$SENTINEL_EVERY_MIN * * * *"

BACKUP_CMD="cd $ROOT_DIR && /bin/bash $SCRIPTS_DIR/backup_project.sh >> $LOG_DIR/backup_project.log 2>&1"
REPORT_CMD="cd $ROOT_DIR && /bin/bash $SCRIPTS_DIR/monitor_report.sh >> $LOG_DIR/monitor_report.log 2>&1"
SENTINEL_CMD="cd $ROOT_DIR && /bin/bash $SCRIPTS_DIR/sentinel_ram.sh >> $LOG_DIR/sentinel_ram.log 2>&1"

EXISTING_CRON="$(crontab -l 2>/dev/null || true)"

# Limpiamos entradas previas gestionadas por este repositorio
CLEAN_CRON="$(echo "$EXISTING_CRON" | grep -v 'backup_project.sh' | grep -v 'monitor_report.sh' | grep -v 'sentinel_ram.sh' || true)"

NEW_BLOCK=$(cat <<EOF
# adema-core-jobs START
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$BACKUP_EXPR $BACKUP_CMD
$REPORT_EXPR $REPORT_CMD
$SENTINEL_EXPR $SENTINEL_CMD
# adema-core-jobs END
EOF
)

if [ -n "$CLEAN_CRON" ]; then
    printf "%s\n\n%s\n" "$CLEAN_CRON" "$NEW_BLOCK" | crontab -
else
    printf "%s\n" "$NEW_BLOCK" | crontab -
fi

echo
echo "Cron instalado correctamente."
echo "Resumen:"
echo "- Backup:   $BACKUP_EXPR"
echo "- Reporte:  $REPORT_EXPR"
echo "- Sentinel: $SENTINEL_EXPR"
echo
echo "Crontab actual:"
crontab -l
echo
echo "Logs:"
echo "- $LOG_DIR/backup_project.log"
echo "- $LOG_DIR/monitor_report.log"
echo "- $LOG_DIR/sentinel_ram.log"