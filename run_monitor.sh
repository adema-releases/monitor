#!/bin/bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$ROOT_DIR/monitor"
ENV_FILE="$SCRIPTS_DIR/.monitor.env"
SECRETS_FILE="$SCRIPTS_DIR/.monitor.secrets"

prepare_script_permissions() {
    # Asegura permisos de ejecucion para TODOS los scripts del repositorio.
    # Evita errores Permission denied aunque el clone llegue con modos alterados.
    find "$ROOT_DIR" -type f -name '*.sh' -exec chmod 755 {} \; 2>/dev/null || true
    echo "Permisos de ejecucion aplicados a todos los scripts .sh del repositorio."
}

run_script() {
    local script_path="$1"
    shift
    /bin/bash "$script_path" "$@"
}

ask_value() {
    local label="$1"
    local current="$2"
    local value

    read -r -p "$label [$current]: " value
    if [ -z "$value" ]; then
        value="$current"
    fi

    echo "$value"
}

configure_environment() {
    local project_code="django"
    local cluster_id="CLUSTER-DJANGO-01"
    local db_prefix="django"
    local db_name_prefix="django_db"
    local db_user_prefix="user_django"
    local volume_base_path="/var/lib/docker/volumes"
    local volume_prefix="django"
    local volume_folders="license logs media"
    local backup_dir="/var/lib/django/backups_locales"
    local backup_retention_days="7"
    local backup_remote="r2:django-backups"
    local brevo_recipient=""
    local brevo_sender=""
    local brevo_sender_name="Monitor Operaciones"
    local db_host="172.17.0.1"
    local ram_threshold_mb="450"
    local exclude_regex="coolify|NAME"

    if [ -f "$ENV_FILE" ]; then
        # shellcheck source=/dev/null
        . "$ENV_FILE"
        project_code="${PROJECT_CODE:-$project_code}"
        cluster_id="${CLUSTER_ID:-$cluster_id}"
        db_prefix="${DB_PREFIX:-$db_prefix}"
        db_name_prefix="${DB_NAME_PREFIX:-$db_name_prefix}"
        db_user_prefix="${DB_USER_PREFIX:-$db_user_prefix}"
        volume_base_path="${VOLUME_BASE_PATH:-$volume_base_path}"
        volume_prefix="${VOLUME_PREFIX:-$volume_prefix}"
        volume_folders="${VOLUME_FOLDERS:-$volume_folders}"
        backup_dir="${BACKUP_DIR:-$backup_dir}"
        backup_retention_days="${BACKUP_RETENTION_DAYS:-$backup_retention_days}"
        backup_remote="${BACKUP_REMOTE:-$backup_remote}"
        brevo_recipient="${BREVO_RECIPIENT:-$brevo_recipient}"
        brevo_sender="${BREVO_SENDER:-$brevo_sender}"
        brevo_sender_name="${BREVO_SENDER_NAME:-$brevo_sender_name}"
        db_host="${DB_HOST:-$db_host}"
        ram_threshold_mb="${RAM_THRESHOLD_MB:-$ram_threshold_mb}"
        exclude_regex="${EXCLUDE_CONTAINER_REGEX:-$exclude_regex}"
    fi

    echo "Configuracion interactiva de entorno"
    project_code=$(ask_value "PROJECT_CODE" "$project_code")
    cluster_id=$(ask_value "CLUSTER_ID" "$cluster_id")
    db_prefix=$(ask_value "DB_PREFIX" "$db_prefix")
    db_name_prefix=$(ask_value "DB_NAME_PREFIX" "$db_name_prefix")
    db_user_prefix=$(ask_value "DB_USER_PREFIX" "$db_user_prefix")
    volume_base_path=$(ask_value "VOLUME_BASE_PATH" "$volume_base_path")
    volume_prefix=$(ask_value "VOLUME_PREFIX" "$volume_prefix")
    volume_folders=$(ask_value "VOLUME_FOLDERS" "$volume_folders")
    backup_dir=$(ask_value "BACKUP_DIR" "$backup_dir")
    backup_retention_days=$(ask_value "BACKUP_RETENTION_DAYS" "$backup_retention_days")
    backup_remote=$(ask_value "BACKUP_REMOTE" "$backup_remote")
    brevo_recipient=$(ask_value "BREVO_RECIPIENT" "$brevo_recipient")
    brevo_sender=$(ask_value "BREVO_SENDER" "$brevo_sender")
    brevo_sender_name=$(ask_value "BREVO_SENDER_NAME" "$brevo_sender_name")
    db_host=$(ask_value "DB_HOST" "$db_host")
    ram_threshold_mb=$(ask_value "RAM_THRESHOLD_MB" "$ram_threshold_mb")
    exclude_regex=$(ask_value "EXCLUDE_CONTAINER_REGEX" "$exclude_regex")

    cat > "$ENV_FILE" <<EOF
PROJECT_CODE=$project_code
CLUSTER_ID=$cluster_id

DB_PREFIX=$db_prefix
DB_NAME_PREFIX=$db_name_prefix
DB_USER_PREFIX=$db_user_prefix

VOLUME_BASE_PATH=$volume_base_path
VOLUME_PREFIX=$volume_prefix
VOLUME_FOLDERS="$volume_folders"

BACKUP_DIR=$backup_dir
BACKUP_RETENTION_DAYS=$backup_retention_days
BACKUP_REMOTE=$backup_remote

BREVO_RECIPIENT=$brevo_recipient
BREVO_SENDER=$brevo_sender
BREVO_SENDER_NAME=$brevo_sender_name

SECRETS_FILE=$SECRETS_FILE

DB_HOST=$db_host
RAM_THRESHOLD_MB=$ram_threshold_mb
EXCLUDE_CONTAINER_REGEX=$exclude_regex
EOF

    local brevo_api_key=""
    if [ -f "$SECRETS_FILE" ]; then
        # shellcheck source=/dev/null
        . "$SECRETS_FILE"
        brevo_api_key="${BREVO_API_KEY:-}"
    fi

    read -r -s -p "BREVO_API_KEY [oculto, Enter para mantener actual]: " new_api_key
    echo
    if [ -n "$new_api_key" ]; then
        brevo_api_key="$new_api_key"
    fi

    cat > "$SECRETS_FILE" <<EOF
BREVO_API_KEY=$brevo_api_key
EOF
    chmod 600 "$SECRETS_FILE" 2>/dev/null || true

    echo "Configuracion guardada en:"
    echo "- $ENV_FILE"
    echo "- $SECRETS_FILE"
}

run_new_client() {
    local client_id
    read -r -p "CLIENT_ID: " client_id
    run_script "$SCRIPTS_DIR/create_tenant.sh" "$client_id"
}

run_delete_client() {
    local client_id
    read -r -p "CLIENT_ID: " client_id
    run_script "$SCRIPTS_DIR/delete_tenant.sh" "$client_id"
}

run_test_db() {
    local client_id
    local db_password
    read -r -p "CLIENT_ID: " client_id
    read -r -s -p "DB_PASSWORD: " db_password
    echo
    run_script "$SCRIPTS_DIR/test_tenant_db.sh" "$client_id" "$db_password"
}

run_setup_web_panel() {
    run_script "$ROOT_DIR/setup_web_panel.sh"
}

run_restart_web_panel() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: esta opcion requiere sudo/root."
        return 1
    fi

    systemctl restart adema-web-panel.service
    systemctl --no-pager --full status adema-web-panel.service | sed -n '1,20p'
}

run_status_web_panel() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status adema-web-panel.service | sed -n '1,25p'
    else
        echo "systemctl no disponible en este host."
    fi
}

menu() {
    while true; do
        echo
        echo "===== MONITOR CLI ====="
        echo "1) Configurar variables y secretos"
        echo "2) Crear tenant"
        echo "3) Borrar tenant"
        echo "4) Ejecutar backup"
        echo "5) Restaurar tenant"
        echo "6) Testear DB"
        echo "7) Enviar reporte de monitor"
        echo "8) Ejecutar centinela de RAM"
        echo "9) Instalar/actualizar cron de produccion"
        echo "10) Regenerar token del panel web"
        echo "11) Instalar/actualizar panel web"
        echo "12) Reiniciar servicio panel web"
        echo "13) Ver estado servicio panel web"
        echo "0) Salir"
        read -r -p "Opcion: " option

        case "$option" in
            1) configure_environment ;;
            2) run_new_client ;;
            3) run_delete_client ;;
            4) run_script "$SCRIPTS_DIR/backup_project.sh" ;;
            5) run_script "$SCRIPTS_DIR/restore_tenant.sh" ;;
            6) run_test_db ;;
            7) run_script "$SCRIPTS_DIR/monitor_report.sh" ;;
            8) run_script "$SCRIPTS_DIR/sentinel_ram.sh" ;;
            9) run_script "$ROOT_DIR/setup_cron.sh" ;;
            10) run_script "$ROOT_DIR/rotate_web_token.sh" ;;
            11) run_setup_web_panel ;;
            12) run_restart_web_panel ;;
            13) run_status_web_panel ;;
            0) exit 0 ;;
            *) echo "Opcion invalida" ;;
        esac
    done
}

if [ ! -f "$ENV_FILE" ]; then
    echo "No existe $ENV_FILE. Iniciando asistente de configuracion..."
    configure_environment
fi

if [ "$EUID" -ne 0 ]; then
    echo "Aviso: ejecuta con sudo para operaciones de DB, volumenes y permisos."
fi

prepare_script_permissions

menu