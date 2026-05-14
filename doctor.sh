#!/bin/bash
set -euo pipefail
# ADEMA Node Lite - diagnostico operativo

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$ROOT_DIR/monitor"
# shellcheck source=/dev/null
. "$MONITOR_DIR/lib/common.sh"
load_monitor_env

OK_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0
NEXT_STEPS=()
NODE_IDENTITY_ERRORS=0
NODE_IDENTITY_WARNINGS=0

ok() { echo "OK    $*"; OK_COUNT=$((OK_COUNT + 1)); }
warn() { echo "WARN  $*"; WARN_COUNT=$((WARN_COUNT + 1)); NEXT_STEPS+=("$*"); }
error() { echo "ERROR $*"; ERROR_COUNT=$((ERROR_COUNT + 1)); NEXT_STEPS+=("$*"); }

identity_ok() { ok "$*"; }
identity_warn() { NODE_IDENTITY_WARNINGS=$((NODE_IDENTITY_WARNINGS + 1)); warn "$*"; }
identity_error() { NODE_IDENTITY_ERRORS=$((NODE_IDENTITY_ERRORS + 1)); error "$*"; }

resolve_domain() {
    local domain="${1:-}"
    [ -n "$domain" ] || { echo ""; return; }
    if command -v dig >/dev/null 2>&1; then
        dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true
    elif command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}' || true
    elif command -v host >/dev/null 2>&1; then
        host "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true
    else
        echo ""
    fi
}

check_domain_points() {
    local label="$1"
    local domain="$2"
    local public_ip="$3"
    local resolved

    [ -n "$domain" ] || return 0
    resolved="$(resolve_domain "$domain")"
    if [ -z "$resolved" ]; then
        identity_warn "$label no resolvio DNS: $domain"
    elif [ -n "$public_ip" ] && [ "$resolved" = "$public_ip" ]; then
        identity_ok "$label apunta a la IP publica actual: $domain -> $resolved"
    elif [ -n "$public_ip" ]; then
        identity_warn "$label resuelve $resolved y la IP publica actual es $public_ip; puede ser proxy/CDN o DNS pendiente"
    else
        identity_warn "$label resuelve $resolved pero no se pudo detectar IP publica local"
    fi
}

check_remote_manifest_readonly() {
    local tmp_dir
    local manifest_file
    local remote_manifest
    local remote_uuid
    local remote_hostname
    local remote_ip
    local local_hostname
    local public_ip

    if ! command -v rclone >/dev/null 2>&1; then
        identity_warn "No se puede validar manifiesto remoto porque rclone no esta instalado"
        return
    fi
    if ! resolve_rclone_config; then
        identity_warn "No se puede validar manifiesto remoto porque RCLONE_CONFIG no esta disponible"
        return
    fi

    tmp_dir="$(mktemp -d)"
    manifest_file="$tmp_dir/node_manifest.json"
    remote_manifest="$(remote_node_manifest_path)"

    if ! rclone copyto "$remote_manifest" "$manifest_file" --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
        identity_warn "No existe manifiesto remoto aun: $remote_manifest; se creara en bootstrap/primer backup"
        rm -rf "$tmp_dir"
        return
    fi

    remote_uuid="$(manifest_json_value "$manifest_file" "ADEMA_NODE_UUID")"
    remote_hostname="$(manifest_json_value "$manifest_file" "hostname")"
    remote_ip="$(manifest_json_value "$manifest_file" "public_ip")"
    local_hostname="$(hostname 2>/dev/null || echo unknown)"
    public_ip="$(detect_public_ip || true)"

    if [ -z "$remote_uuid" ]; then
        identity_error "Manifiesto remoto sin ADEMA_NODE_UUID: $remote_manifest"
    elif [ "$remote_uuid" != "${ADEMA_NODE_UUID:-}" ]; then
        identity_error "Manifiesto remoto pertenece a otro NODE_UUID: remoto=$remote_uuid local=${ADEMA_NODE_UUID:-}"
        audit_event "remote_manifest_mismatch" "" "error" "remote=$remote_manifest remote_uuid=$remote_uuid local_uuid=${ADEMA_NODE_UUID:-}"
    else
        identity_ok "Manifiesto remoto compatible: $remote_manifest"
    fi

    if [ -n "$remote_hostname" ] && [ "$remote_hostname" != "$local_hostname" ]; then
        identity_warn "Hostname actual ($local_hostname) difiere del manifiesto remoto ($remote_hostname); revisar si la VM fue clonada"
    fi
    if [ -n "$remote_ip" ] && [ -n "$public_ip" ] && [ "$remote_ip" != "$public_ip" ]; then
        identity_warn "IP publica actual ($public_ip) difiere del manifiesto remoto ($remote_ip); puede ser IP nueva o VM clonada"
    fi

    rm -rf "$tmp_dir"
}

check_node_identity() {
    local public_ip

    if [ ! -f "$ADEMA_NODE_ENV_FILE" ]; then
        identity_error "$ADEMA_NODE_ENV_FILE inexistente"
        audit_event "doctor_node_identity_error" "" "error" "node_env_missing"
        return
    fi
    identity_ok "$ADEMA_NODE_ENV_FILE existe"

    if ! is_safe_node_id "${ADEMA_NODE_ID:-}"; then
        identity_error "ADEMA_NODE_ID faltante o con formato invalido: ${ADEMA_NODE_ID:-}"
    elif is_generic_identity_value "$ADEMA_NODE_ID"; then
        identity_error "ADEMA_NODE_ID generico/no permitido: $ADEMA_NODE_ID"
    else
        identity_ok "ADEMA_NODE_ID valido: $ADEMA_NODE_ID"
    fi

    if ! is_uuid "${ADEMA_NODE_UUID:-}"; then
        identity_error "ADEMA_NODE_UUID faltante o invalido"
    else
        identity_ok "ADEMA_NODE_UUID presente y valido"
    fi

    if [ -z "${CLUSTER_ID:-}" ] || is_generic_identity_value "$CLUSTER_ID"; then
        identity_error "CLUSTER_ID faltante o demo/default: ${CLUSTER_ID:-}"
    else
        identity_ok "CLUSTER_ID valido: $CLUSTER_ID"
    fi

    if [ -z "${PROJECT_CODE:-}" ] || is_generic_identity_value "$PROJECT_CODE"; then
        if [ "${ADEMA_DEV_MODE:-0}" = "1" ]; then
            identity_warn "PROJECT_CODE generico permitido solo por ADEMA_DEV_MODE=1: ${PROJECT_CODE:-}"
        else
            identity_error "PROJECT_CODE faltante o demo/default en modo produccion: ${PROJECT_CODE:-}"
        fi
    else
        identity_ok "PROJECT_CODE valido: $PROJECT_CODE"
    fi

    if [ -z "${BACKUP_REMOTE:-}" ]; then
        identity_error "BACKUP_REMOTE faltante"
    elif ! echo "$BACKUP_REMOTE" | grep -q ':'; then
        identity_error "BACKUP_REMOTE invalido; debe tener formato remote:path"
    elif ! backup_remote_includes_node_id "$BACKUP_REMOTE" "${ADEMA_NODE_ID:-}"; then
        identity_error "BACKUP_REMOTE no incluye ADEMA_NODE_ID; riesgo de colision: $BACKUP_REMOTE"
    else
        identity_ok "BACKUP_REMOTE contiene path unico del nodo: $BACKUP_REMOTE"
    fi

    if [ -n "${ADEMA_BASE_DOMAIN:-}" ]; then
        [ -n "${ADEMA_INFRA_DOMAIN:-}" ] || identity_error "ADEMA_INFRA_DOMAIN faltante aunque ADEMA_BASE_DOMAIN esta configurado"
        [ -n "${ADEMA_DEPLOY_DOMAIN:-}" ] || identity_error "ADEMA_DEPLOY_DOMAIN faltante aunque ADEMA_BASE_DOMAIN esta configurado"
    else
        identity_warn "Dominio base no configurado; correcto para pruebas internas, no para go-live"
    fi

    public_ip="$(detect_public_ip || true)"
    check_domain_points "Infra domain" "${ADEMA_INFRA_DOMAIN:-}" "$public_ip"
    check_domain_points "Deploy domain" "${ADEMA_DEPLOY_DOMAIN:-}" "$public_ip"
    check_remote_manifest_readonly

    if [ "$NODE_IDENTITY_ERRORS" -gt 0 ]; then
        audit_event "doctor_node_identity_error" "" "error" "errors=$NODE_IDENTITY_ERRORS warnings=$NODE_IDENTITY_WARNINGS"
    elif [ "$NODE_IDENTITY_WARNINGS" -gt 0 ]; then
        audit_event "doctor_node_identity_warn" "" "warn" "warnings=$NODE_IDENTITY_WARNINGS"
    else
        audit_event "doctor_node_identity_ok" "" "success" "node_id=${ADEMA_NODE_ID:-}"
    fi
}

check_os() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) ok "Sistema compatible: ${PRETTY_NAME:-$ID}" ;;
            *)
                if echo "${ID_LIKE:-}" | grep -Eq '(^| )(debian|ubuntu)( |$)'; then
                    ok "Sistema compatible por familia Debian: ${PRETTY_NAME:-$ID}"
                else
                    error "Sistema no soportado: ${PRETTY_NAME:-desconocido}"
                fi
                ;;
        esac
    else
        error "No se puede leer /etc/os-release"
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker no instalado"
        return
    fi
    if docker info >/dev/null 2>&1; then
        ok "Docker instalado y corriendo"
    else
        error "Docker instalado pero daemon no responde"
    fi
}

check_coolify() {
    if [ -f /etc/adema/node.env ]; then
        # shellcheck source=/dev/null
        . /etc/adema/node.env
    fi
    if [ "${COOLIFY_OMITTED:-0}" = "1" ]; then
        warn "Coolify marcado como omitido"
        return
    fi
    if docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'coolify|traefik'; then
        ok "Coolify/Traefik detectado"
    else
        warn "Coolify no detectado; valida instalacion u omision intencional"
    fi
}

check_postgres() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet postgresql; then
        ok "PostgreSQL activo"
    else
        error "PostgreSQL no esta activo"
    fi

    if sudo -u postgres psql -t -A -c 'SHOW password_encryption;' 2>/dev/null | grep -qx 'scram-sha-256'; then
        ok "PostgreSQL usa SCRAM"
    else
        warn "PostgreSQL no reporta password_encryption=scram-sha-256"
    fi

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)5432$'; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^0\.0\.0\.0:5432$|^\[::\]:5432$)'; then
            if command -v ufw >/dev/null 2>&1 && ufw status | grep -Eq '5432/tcp.*DENY|5432.*DENY'; then
                warn "PostgreSQL escucha en interfaces publicas, pero UFW muestra DENY para 5432; revisar pg_hba y reglas"
            else
                error "PostgreSQL parece expuesto publicamente en 5432 sin DENY visible en UFW"
            fi
        else
            ok "PostgreSQL no escucha en 0.0.0.0/::"
        fi
    else
        error "No se detecta listener PostgreSQL en 5432"
    fi
}

check_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        error "UFW no instalado"
        return
    fi
    if ufw status | grep -qi '^Status: active'; then
        ok "UFW activo"
    else
        error "UFW inactivo"
    fi
    if ufw status | grep -Eq '5432/tcp.*DENY|5432.*DENY'; then
        ok "Firewall contiene regla DENY para 5432"
    else
        warn "No se ve DENY explicito para 5432 en UFW"
    fi
}

check_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        error "rclone no instalado"
        return
    fi
    ok "rclone instalado"
    if resolve_rclone_config && rclone lsd "$BACKUP_REMOTE" --config "$RCLONE_CONFIG" >/dev/null 2>&1; then
        ok "Remote de backup accesible: $BACKUP_REMOTE"
    else
        warn "Remote de backup no validado: $BACKUP_REMOTE"
    fi
}

check_cron() {
    if [ -f /etc/cron.d/adema-node ]; then
        ok "Cron de backup instalado en /etc/cron.d/adema-node"
    else
        warn "Cron de backup no instalado"
    fi
}

check_permissions() {
    if [ -O "$ROOT_DIR" ] || [ "$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || echo root)" = "root" ]; then
        ok "$ROOT_DIR pertenece a root o usuario actual root"
    else
        warn "$ROOT_DIR no parece root-owned"
    fi

    for script in "$MONITOR_DIR/create_tenant.sh" "$MONITOR_DIR/delete_tenant.sh" "$MONITOR_DIR/restore_tenant.sh" "$ROOT_DIR/web_manager.py"; do
        owner="$(stat -c '%U' "$script" 2>/dev/null || echo unknown)"
        if [ "$owner" = "root" ]; then
            ok "Script critico root-owned: $script"
        else
            warn "Script critico no root-owned: $script owner=$owner"
        fi
    done

    if [ -d "$ROOT_DIR/.web_jobs" ]; then
        perm="$(stat -c '%a %U' "$ROOT_DIR/.web_jobs" 2>/dev/null || echo unknown)"
        ok ".web_jobs presente: $perm"
    else
        warn ".web_jobs no existe; se creara al instalar panel"
    fi
}

check_panel() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet adema-web-panel.service; then
        ok "Panel web activo"
        if ss -ltn 2>/dev/null | grep -q ':5000'; then
            if ss -ltn 2>/dev/null | grep -Eq '0\.0\.0\.0:5000|\[::\]:5000'; then
                warn "Panel escucha en interfaz publica; usa 127.0.0.1 + proxy protegido"
            else
                ok "Panel no expone 5000 publicamente"
            fi
        fi
    else
        warn "Panel web inactivo u omitido"
    fi
}

check_db_from_docker() {
    docker0_ip="$(detect_docker0_ip || true)"
    if [ -n "$docker0_ip" ] && timeout 3 bash -c "</dev/tcp/$docker0_ip/${DB_PORT:-5432}" >/dev/null 2>&1; then
        ok "Conectividad TCP a PostgreSQL desde IP docker0: $docker0_ip:${DB_PORT:-5432}"
    else
        warn "No se pudo validar conectividad TCP a PostgreSQL desde docker0"
    fi
}

check_disk() {
    available_mb="$(df -Pm / | awk 'NR==2{print $4}')"
    if [ "${available_mb:-0}" -ge 5120 ]; then
        ok "Espacio en disco suficiente: ${available_mb}MB libres"
    else
        warn "Espacio en disco bajo: ${available_mb}MB libres"
    fi
}

echo "== ADEMA Node Lite doctor =="
check_node_identity
check_os
check_docker
check_coolify
check_postgres
check_firewall
check_rclone
check_cron
check_permissions
check_panel
check_db_from_docker
check_disk

audit_event "doctor" "" "$([ "$ERROR_COUNT" -eq 0 ] && echo success || echo error)" "ok=$OK_COUNT warn=$WARN_COUNT error=$ERROR_COUNT"

echo "=================================================="
echo "Resumen: OK=$OK_COUNT WARN=$WARN_COUNT ERROR=$ERROR_COUNT"
if [ "${#NEXT_STEPS[@]}" -gt 0 ]; then
    echo "Proximos pasos:"
    printf ' - %s\n' "${NEXT_STEPS[@]}"
fi
echo "=================================================="

[ "$ERROR_COUNT" -eq 0 ]