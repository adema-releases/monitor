#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"
load_monitor_env

FORCE_REMOTE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            FORCE_REMOTE=1
            ;;
        -h|--help)
            echo "Uso: sudo ./backup_project.sh [--force]"
            echo "--force permite continuar si el manifiesto remoto pertenece a otro nodo o el path no incluye ADEMA_NODE_ID."
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $1"
            exit 1
            ;;
    esac
    shift
done

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone no esta instalado o no esta en PATH."
    audit_event "backup" "" "error" "rclone_missing"
    exit 1
fi

REMOTE_NAME="${BACKUP_REMOTE%%:*}"
if [ -z "$REMOTE_NAME" ] || [ "$REMOTE_NAME" = "$BACKUP_REMOTE" ]; then
    echo "ERROR: BACKUP_REMOTE invalido: '$BACKUP_REMOTE'. Debe tener formato remote:ruta"
    audit_event "backup" "" "error" "invalid_backup_remote=$BACKUP_REMOTE"
    exit 1
fi

if [ -z "${ADEMA_NODE_ID:-}" ] || [ -z "${ADEMA_NODE_UUID:-}" ]; then
    echo "ERROR: identidad de nodo incompleta. Revisa /etc/adema/node.env."
    audit_event "backup" "" "error" "node_identity_incomplete"
    exit 1
fi

if ! backup_remote_includes_node_id "$BACKUP_REMOTE" "$ADEMA_NODE_ID"; then
    echo "ERROR: BACKUP_REMOTE no incluye ADEMA_NODE_ID ($ADEMA_NODE_ID): $BACKUP_REMOTE"
    echo "Esto puede pisar backups/latest de otro nodo. Usa un path unico, por ejemplo: adema-crypt:backups/$ADEMA_NODE_ID"
    audit_event "backup" "" "error" "remote_without_node_id remote=$BACKUP_REMOTE node_id=$ADEMA_NODE_ID"
    [ "$FORCE_REMOTE" -eq 1 ] || exit 1
fi

if ! resolve_rclone_config; then
    echo "ERROR: No se encontro rclone.conf."
    echo "Configura RCLONE_CONFIG en monitor/.monitor.env con la ruta correcta del archivo."
    audit_event "backup" "" "error" "rclone_config_missing"
    exit 1
fi

if ! rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -Fxq "$REMOTE_NAME:"; then
    echo "ERROR: El remote '$REMOTE_NAME' no existe en $RCLONE_CONFIG"
    echo "Ejecuta: rclone config --config $RCLONE_CONFIG"
    audit_event "backup" "" "error" "rclone_remote_missing remote=$REMOTE_NAME"
    exit 1
fi

if ! ensure_remote_node_manifest "$FORCE_REMOTE"; then
    echo "ERROR: manifiesto remoto incompatible. Backup bloqueado."
    echo "Usa --force solo despues de confirmar que este remote debe reasignarse a este nodo."
    exit 1
fi

# Verificar espacio en disco antes de continuar
MIN_FREE_MB="${ADEMA_MIN_BACKUP_FREE_MB:-500}"
mkdir -p "$BACKUP_DIR"
AVAIL_KB=$(df --output=avail "$BACKUP_DIR" 2>/dev/null | tail -n1 | tr -d ' ' || echo "0")
AVAIL_MB=$((AVAIL_KB / 1024))
if [ "$AVAIL_MB" -lt "$MIN_FREE_MB" ]; then
    echo "ERROR: Espacio insuficiente en $BACKUP_DIR (${AVAIL_MB}MB libres, minimo ${MIN_FREE_MB}MB)."
    audit_event "backup" "" "error" "disk_free_mb=$AVAIL_MB min_mb=$MIN_FREE_MB"
    exit 1
fi

DATE_FOLDER=$(date +%Y-%m-%d)
DATE_FILE=$(date +%H-%M)

echo "Iniciando backup de bases de datos para $PROJECT_CODE..."
audit_event "backup" "" "started" "remote=$BACKUP_REMOTE date=$DATE_FOLDER"

DATABASES=$(sudo -u postgres psql -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE '${DB_NAME_PREFIX}_%';")

for DB in $DATABASES; do
    CLIENT_ID="${DB#${DB_NAME_PREFIX}_}"
    echo "Respaldando: $DB"
    FILENAME="${DB}_${DATE_FOLDER}_${DATE_FILE}.sql.gz"
    sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_DIR/$FILENAME"
    cp "$BACKUP_DIR/$FILENAME" "$BACKUP_DIR/${DB}_latest.sql.gz"

    SIZE_BYTES=$(stat -c%s "$BACKUP_DIR/$FILENAME" 2>/dev/null || wc -c < "$BACKUP_DIR/$FILENAME")
    SHA256_VALUE=$(sha256sum "$BACKUP_DIR/$FILENAME" | awk '{print $1}')
    MANIFEST_FILE="$BACKUP_DIR/${FILENAME}.manifest.json"
    cat > "$MANIFEST_FILE" <<EOF
{
  "tenant": "$(json_escape "$CLIENT_ID")",
  "db": "$(json_escape "$DB")",
  "date": "$(json_escape "$DATE_FOLDER")",
  "file": "$(json_escape "$FILENAME")",
  "size": $SIZE_BYTES,
  "sha256": "$(json_escape "$SHA256_VALUE")",
  "node": "$(json_escape "$(hostname)")",
  "adema_node_id": "$(json_escape "$ADEMA_NODE_ID")",
  "adema_node_uuid": "$(json_escape "$ADEMA_NODE_UUID")",
  "adema_node_name": "$(json_escape "${ADEMA_NODE_NAME:-}")",
  "cluster_id": "$(json_escape "$CLUSTER_ID")",
  "project_code": "$(json_escape "$PROJECT_CODE")"
}
EOF
done

echo "Sincronizando bases a remoto: $BACKUP_REMOTE"
rclone copy "$BACKUP_DIR" "$BACKUP_REMOTE/databases/$DATE_FOLDER" --progress --filter "- *_latest.sql.gz" --filter "+ *.sql.gz" --filter "+ *.manifest.json" --filter "- *"
rclone sync "$BACKUP_DIR" "$BACKUP_REMOTE/databases/current" --progress --filter "+ *_latest.sql.gz" --filter "- *"

echo "Sincronizando volumenes del proyecto..."
for folder in $VOLUME_FOLDERS; do
    for vol_dir in "$VOLUME_BASE_PATH"/"${VOLUME_PREFIX}"_*_"$folder"; do
        [ -d "$vol_dir" ] || continue
        vol_name=$(basename "$vol_dir")
        rclone sync "$vol_dir/" "$BACKUP_REMOTE/volumes/$vol_name/" --progress
    done
done

echo "Limpieza de archivos locales"
find "$BACKUP_DIR" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete

echo "Backup completado"
audit_event "backup" "" "success" "remote=$BACKUP_REMOTE date=$DATE_FOLDER databases=$(echo "$DATABASES" | wc -w)"