#!/bin/bash
set -euo pipefail
# Adema Core - DNS/proxy bootstrap for Coolify/Traefik nodes
# Repo oficial: https://github.com/adema-releases/monitor
#
# Responsabilidades separadas:
#   1) Bootstrap/diagnostico del nodo: DNS, firewall, Docker, Coolify y puertos.
#   2) Monitor como app: se publica desde Coolify en monitor.<dominio>, sin manejar 80/443.
#
# Uso:
#   bash monitor/setup_domains.sh
#   bash monitor/setup_domains.sh --check
#   bash monitor/setup_domains.sh --check --json
#   bash monitor/setup_domains.sh --proxy-mode host-nginx   # legacy, requiere confirmacion

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_ENV_FILE="${ADEMA_DOMAINS_ENV_FILE:-/etc/adema/domains.env}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

MODE_CHECK=0
MODE_JSON=0
PROXY_MODE_REQUESTED="${PUBLIC_PROXY_MODE:-coolify-traefik}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) MODE_CHECK=1 ;;
        --json) MODE_JSON=1; MODE_CHECK=1 ;;
        --proxy-mode)
            shift
            PROXY_MODE_REQUESTED="${1:-}"
            ;;
        --proxy-mode=*) PROXY_MODE_REQUESTED="${1#*=}" ;;
        --host-nginx|--legacy-host-nginx) PROXY_MODE_REQUESTED="host-nginx" ;;
        -h|--help)
            cat <<HELP
Adema Core - setup de dominios

Opciones:
  --check                 Solo diagnostico, sin cambios
  --json                  Salida JSON para API
  --proxy-mode MODE       coolify-traefik (default) o host-nginx (legacy)
  --host-nginx            Alias legacy para --proxy-mode host-nginx

El modo recomendado es coolify-traefik. No instala Nginx ni ejecuta certbot.
HELP
            exit 0
            ;;
        *)
            echo "Argumento desconocido: $1" >&2
            exit 2
            ;;
    esac
    shift
done

_say()    { [ "$MODE_JSON" -eq 0 ] && echo -e "$*" >&2 || true; }
log()     { _say "${BOLD}[INFO]${RESET}  $*"; }
ok()      { _say "${GREEN}[OK]${RESET}    $*"; }
warn()    { _say "${YELLOW}[WARN]${RESET}  $*"; }
fail()    { _say "${RED}[FAIL]${RESET}  $*"; }
err_msg() { _say "${RED}[ERROR]${RESET} $*"; }
title()   { _say "\n${CYAN}${BOLD}...  $*  ...${RESET}"; }
hr()      { _say "${CYAN}----------------------------------------------------${RESET}"; }
sep()     { _say ""; }

if [ -f "$DOMAINS_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$DOMAINS_ENV_FILE"
fi

BASE_DOMAIN="${BASE_DOMAIN:-${ADEMA_BASE_DOMAIN:-}}"
ROOT_DOMAIN="${ROOT_DOMAIN:-${BASE_DOMAIN:-}}"
WWW_DOMAIN="${WWW_DOMAIN:-${BASE_DOMAIN:+www.${BASE_DOMAIN}}}"
COOLIFY_DOMAIN="${COOLIFY_DOMAIN:-${ADEMA_DEPLOY_DOMAIN:-${BASE_DOMAIN:+deploy.${BASE_DOMAIN}}}}"
MONITOR_DOMAIN="${MONITOR_DOMAIN:-${ADEMA_MONITOR_DOMAIN:-${ADEMA_INFRA_DOMAIN:-${BASE_DOMAIN:+monitor.${BASE_DOMAIN}}}}}"
CLIENTES_DOMAIN="${CLIENTES_DOMAIN:-${BASE_DOMAIN:+clientes.${BASE_DOMAIN}}}"
API_DOMAIN="${API_DOMAIN:-${BASE_DOMAIN:+api.${BASE_DOMAIN}}}"
CREDITOS_DOMAIN="${CREDITOS_DOMAIN:-${BASE_DOMAIN:+creditos.${BASE_DOMAIN}}}"
STOCK_DOMAIN="${STOCK_DOMAIN:-${BASE_DOMAIN:+stock.${BASE_DOMAIN}}}"
ACADEMY_DOMAIN="${ACADEMY_DOMAIN:-${BASE_DOMAIN:+academy.${BASE_DOMAIN}}}"
MONITOR_INTERNAL_PORT="${MONITOR_INTERNAL_PORT:-${ADEMA_PANEL_PORT:-5000}}"
MONITOR_BIND="${MONITOR_BIND:-${ADEMA_PANEL_BIND:-127.0.0.1}}"
PUBLIC_PROXY_MODE="${PROXY_MODE_REQUESTED:-coolify-traefik}"

# Aliases legacy para integraciones existentes.
ADEMA_BASE_DOMAIN="${ADEMA_BASE_DOMAIN:-$BASE_DOMAIN}"
ADEMA_DEPLOY_DOMAIN="${ADEMA_DEPLOY_DOMAIN:-$COOLIFY_DOMAIN}"
ADEMA_INFRA_DOMAIN="${ADEMA_INFRA_DOMAIN:-$MONITOR_DOMAIN}"
ADEMA_PANEL_PORT="${ADEMA_PANEL_PORT:-$MONITOR_INTERNAL_PORT}"
ADEMA_PANEL_BIND="${ADEMA_PANEL_BIND:-$MONITOR_BIND}"

ALL_DOMAINS=(
    "$ROOT_DOMAIN"
    "$WWW_DOMAIN"
    "$COOLIFY_DOMAIN"
    "$MONITOR_DOMAIN"
    "$CLIENTES_DOMAIN"
    "$API_DOMAIN"
    "$CREDITOS_DOMAIN"
    "$STOCK_DOMAIN"
    "$ACADEMY_DOMAIN"
)

prompt_if_empty() {
    local -n var_ref=$1
    local prompt_text="$2"
    local default_val="${3:-}"

    if [ -n "${var_ref:-}" ]; then
        return
    fi
    if [ "$MODE_CHECK" -eq 1 ]; then
        err_msg "Variable $1 no definida. Define BASE_DOMAIN o crea $DOMAINS_ENV_FILE."
        exit 1
    fi

    if [ -n "$default_val" ]; then
        printf "%b" "${BOLD}${prompt_text}${RESET} [${CYAN}${default_val}${RESET}]: " >&2
        read -r input </dev/tty
        var_ref="${input:-$default_val}"
    else
        printf "%b" "${BOLD}${prompt_text}${RESET}: " >&2
        read -r input </dev/tty
        var_ref="$input"
    fi
}

detect_public_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 6 ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    echo "${ip:-}"
}

resolve_domain() {
    local domain="${1:-}"
    local resolved=""
    [ -z "$domain" ] && { echo ""; return; }

    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
    elif command -v host >/dev/null 2>&1; then
        resolved=$(host "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)
    elif command -v nslookup >/dev/null 2>&1; then
        resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address:/ && !/127\.0\.0\.1/ {print $2; exit}' || true)
    fi
    echo "${resolved:-}"
}

ufw_port_status() {
    local port="$1"
    if ! command -v ufw >/dev/null 2>&1; then
        echo "no_ufw"
        return
    fi

    local status
    status=$(ufw status 2>/dev/null || true)
    if echo "$status" | grep -qi '^Status: inactive'; then
        echo "ufw_inactive"
        return
    fi
    if echo "$status" | grep -qE "^${port}(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)"; then
        echo "open"
        return
    fi
    echo "closed"
}

port_listener_output() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -E ":${port}\b" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -E ":${port}\b" || true
    fi
}

detect_proxy_on_ports() {
    local output docker_output combined
    output="$(port_listener_output 80; port_listener_output 443)"
    docker_output="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)"
    combined="$output
$docker_output"

    if echo "$combined" | grep -qiE 'traefik|coolify-proxy|coolify'; then
        echo "coolify-traefik"
    elif echo "$combined" | grep -qi 'caddy'; then
        echo "caddy"
    elif echo "$output" | grep -qi 'nginx'; then
        echo "nginx"
    elif [ -n "$output" ]; then
        echo "other"
    else
        echo "free"
    fi
}

docker_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "missing"
        return
    fi
    if docker info >/dev/null 2>&1; then
        echo "running"
    else
        echo "installed_not_running"
    fi
}

coolify_status() {
    local containers
    containers=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -iE 'coolify|traefik' || true)
    if [ -n "$containers" ]; then
        echo "running"
        return
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet coolify 2>/dev/null; then
        echo "running"
        return
    fi
    echo "not_detected"
}

host_nginx_status() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo "not_installed"
        return
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        echo "active"
        return
    fi
    echo "installed_inactive"
}

port_public_status() {
    local port="$1"
    local output
    output=$(port_listener_output "$port")
    if [ -z "$output" ]; then
        echo "closed"
    elif echo "$output" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\[::\]|\*)[:.]'; then
        echo "public"
    else
        echo "local_or_internal"
    fi
}

check_monitor_local() {
    local bind="${1:-127.0.0.1}"
    local port="${2:-5000}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${bind}:${port}/healthz" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
        echo "up"
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${bind}:${port}/" 2>/dev/null || echo "000")
        [ "$code" = "000" ] && echo "down" || echo "up"
    fi
}

ensure_ufw_rules() {
    if [ "$EUID" -ne 0 ]; then
        warn "No se aplican reglas UFW porque no estas ejecutando como root."
        echo "  sudo ufw allow 22/tcp comment 'SSH'" >&2
        echo "  sudo ufw allow 80/tcp comment 'HTTP for Coolify Traefik'" >&2
        echo "  sudo ufw allow 443/tcp comment 'HTTPS for Coolify Traefik'" >&2
        return
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        warn "UFW no esta instalado. Instala ufw o aplica reglas equivalentes en tu firewall."
        return
    fi

    ufw allow 22/tcp comment 'SSH' >/dev/null || true
    ufw allow 80/tcp comment 'HTTP for Coolify Traefik' >/dev/null || true
    ufw allow 443/tcp comment 'HTTPS for Coolify Traefik' >/dev/null || true
    ok "UFW permite 22/tcp, 80/tcp y 443/tcp."

    if ufw status 2>/dev/null | grep -qi '^Status: inactive'; then
        warn "UFW esta inactivo."
        printf "%b" "  Activar UFW ahora? [s/N]: " >&2
        read -r enable_ufw </dev/tty
        if [[ "${enable_ufw,,}" = "s" ]]; then
            ufw --force enable >/dev/null
            ok "UFW activado."
        else
            warn "UFW queda inactivo; verifica firewall externo antes de produccion."
        fi
    fi
}

print_cloudflare_instructions() {
    local server_ip="$1"

    title "Cloudflare DNS"
    hr
    log "Cloudflare debe resolver DNS solamente; Coolify/Traefik enruta HTTP/HTTPS."
    sep
    echo "  A      @      ${server_ip:-IP_DEL_NODO}       DNS only" >&2
    echo "  A      *      ${server_ip:-IP_DEL_NODO}       DNS only" >&2
    echo "  CNAME  www    ${ROOT_DOMAIN:-ademasistemas.com}  DNS only" >&2
    sep
    warn "No tocar MX/TXT/DKIM/SPF/DMARC/Brevo/Zoho existentes."
    warn "Durante emision inicial de SSL, usar DNS only. Luego evaluar proxied si no rompe ACME/websockets."
    hr
}

print_coolify_instructions() {
    title "Coolify / Traefik"
    hr
    log "Crear recursos separados en Coolify y asignar estos dominios:"
    echo "  adema-web          -> https://${ROOT_DOMAIN}" >&2
    echo "  adema-web alias    -> https://${WWW_DOMAIN}" >&2
    echo "  coolify panel      -> https://${COOLIFY_DOMAIN}" >&2
    echo "  adema-monitor      -> https://${MONITOR_DOMAIN}  (puerto interno ${MONITOR_INTERNAL_PORT})" >&2
    echo "  adema-clientes     -> https://${CLIENTES_DOMAIN}" >&2
    echo "  adema-api          -> https://${API_DOMAIN}" >&2
    echo "  gestion-creditos   -> https://${CREDITOS_DOMAIN}" >&2
    echo "  adema-stock        -> https://${STOCK_DOMAIN}" >&2
    echo "  academia-adema     -> https://${ACADEMY_DOMAIN}" >&2
    sep
    log "Cada app debe tener DB/servicio Postgres propio y credenciales propias."
    warn "No publiques el puerto ${MONITOR_INTERNAL_PORT} como puerto host; Coolify debe enrutarlo por Traefik."
    hr
}

write_domains_env() {
    if [ "$EUID" -ne 0 ]; then
        warn "No se guarda $DOMAINS_ENV_FILE porque no estas ejecutando como root."
        return
    fi

    printf "%b" "  Guardar configuracion en ${DOMAINS_ENV_FILE}? [S/n]: " >&2
    read -r save_env </dev/tty
    if [[ "${save_env,,}" = "n" ]]; then
        return
    fi

    mkdir -p "$(dirname "$DOMAINS_ENV_FILE")"
    cat > "$DOMAINS_ENV_FILE" <<ENVEOF
# Adema Core - Dominios del nodo
# Generado por setup_domains.sh
BASE_DOMAIN=${BASE_DOMAIN}
ROOT_DOMAIN=${ROOT_DOMAIN}
WWW_DOMAIN=${WWW_DOMAIN}
COOLIFY_DOMAIN=${COOLIFY_DOMAIN}
MONITOR_DOMAIN=${MONITOR_DOMAIN}
CLIENTES_DOMAIN=${CLIENTES_DOMAIN}
API_DOMAIN=${API_DOMAIN}
CREDITOS_DOMAIN=${CREDITOS_DOMAIN}
STOCK_DOMAIN=${STOCK_DOMAIN}
ACADEMY_DOMAIN=${ACADEMY_DOMAIN}
MONITOR_INTERNAL_PORT=${MONITOR_INTERNAL_PORT}
PUBLIC_PROXY_MODE=coolify-traefik

# Aliases legacy/deprecated para compatibilidad
ADEMA_BASE_DOMAIN=${BASE_DOMAIN}
ADEMA_DEPLOY_DOMAIN=${COOLIFY_DOMAIN}
ADEMA_INFRA_DOMAIN=${MONITOR_DOMAIN}
ADEMA_PANEL_PORT=${MONITOR_INTERNAL_PORT}
ADEMA_PANEL_BIND=127.0.0.1
ENVEOF
    chmod 640 "$DOMAINS_ENV_FILE"
    ok "Configuracion guardada en $DOMAINS_ENV_FILE"
}

json_bool() {
    [ "${1:-false}" = "true" ] && echo "true" || echo "false"
}

bool_expr() {
    if eval "$1"; then
        echo "true"
    else
        echo "false"
    fi
}

run_checks() {
    local server_ip http_status https_status ssh_status proxy_detected docker_state coolify_state nginx_state
    local monitor_port_state postgres_state redis_state monitor_local_status
    local dns_count=0 dns_direct_count=0 dns_proxy_count=0 dns_fail_count=0 wildcard_ok="false"
    local monitor_resolved deploy_resolved root_resolved www_resolved

    server_ip=$(detect_public_ip)
    http_status=$(ufw_port_status 80)
    https_status=$(ufw_port_status 443)
    ssh_status=$(ufw_port_status 22)
    proxy_detected=$(detect_proxy_on_ports)
    docker_state=$(docker_status)
    coolify_state=$(coolify_status)
    nginx_state=$(host_nginx_status)
    monitor_port_state=$(port_public_status "$MONITOR_INTERNAL_PORT")
    postgres_state=$(port_public_status 5432)
    redis_state=$(port_public_status 6379)
    monitor_local_status=$(check_monitor_local "$MONITOR_BIND" "$MONITOR_INTERNAL_PORT")

    root_resolved=$(resolve_domain "$ROOT_DOMAIN")
    www_resolved=$(resolve_domain "$WWW_DOMAIN")
    deploy_resolved=$(resolve_domain "$COOLIFY_DOMAIN")
    monitor_resolved=$(resolve_domain "$MONITOR_DOMAIN")

    local domain resolved
    local check_domains=(
        "$ROOT_DOMAIN"
        "$WWW_DOMAIN"
        "$COOLIFY_DOMAIN"
        "$MONITOR_DOMAIN"
        "$CLIENTES_DOMAIN"
        "$API_DOMAIN"
        "$CREDITOS_DOMAIN"
        "$STOCK_DOMAIN"
        "$ACADEMY_DOMAIN"
    )
    for domain in "${check_domains[@]}"; do
        [ -n "$domain" ] || continue
        dns_count=$((dns_count + 1))
        resolved=$(resolve_domain "$domain")
        if [ -z "$resolved" ]; then
            dns_fail_count=$((dns_fail_count + 1))
        elif [ -n "$server_ip" ] && [ "$resolved" = "$server_ip" ]; then
            dns_direct_count=$((dns_direct_count + 1))
        else
            dns_proxy_count=$((dns_proxy_count + 1))
        fi
    done

    if [ -n "$root_resolved" ] && [ -n "$monitor_resolved" ] && { [ "$root_resolved" = "$monitor_resolved" ] || [ "$dns_proxy_count" -gt 0 ]; }; then
        wildcard_ok="true"
    fi

    local http_open="false" https_open="false" ssh_open="false" proxy_ok="false" nginx_conflict="false"
    local monitor_port_public="false" postgres_public="false" redis_public="false" docker_ok="false" coolify_ok="false"
    local monitor_dns_ok="false" deploy_dns_ok="false" root_dns_ok="false" warning_count=0 fail_count=0 overall_ok="true"

    [ "$http_status" = "open" ] && http_open="true"
    [ "$https_status" = "open" ] && https_open="true"
    [ "$ssh_status" = "open" ] && ssh_open="true"
    [ "$docker_state" = "running" ] && docker_ok="true"
    [ "$coolify_state" = "running" ] && coolify_ok="true"
    [ "$proxy_detected" = "coolify-traefik" ] && proxy_ok="true"
    [ "$nginx_state" = "active" ] && nginx_conflict="true"
    [ "$monitor_port_state" = "public" ] && monitor_port_public="true"
    [ "$postgres_state" = "public" ] && postgres_public="true"
    [ "$redis_state" = "public" ] && redis_public="true"
    [ -n "$monitor_resolved" ] && monitor_dns_ok="true"
    [ -n "$deploy_resolved" ] && deploy_dns_ok="true"
    [ -n "$root_resolved" ] && root_dns_ok="true"

    [ "$http_open" = "true" ] || fail_count=$((fail_count + 1))
    [ "$https_open" = "true" ] || fail_count=$((fail_count + 1))
    [ "$proxy_ok" = "true" ] || fail_count=$((fail_count + 1))
    [ "$nginx_conflict" = "false" ] || fail_count=$((fail_count + 1))
    [ "$monitor_port_public" = "false" ] || fail_count=$((fail_count + 1))
    [ "$postgres_public" = "false" ] || fail_count=$((fail_count + 1))
    [ "$redis_public" = "false" ] || fail_count=$((fail_count + 1))
    [ "$docker_ok" = "true" ] || fail_count=$((fail_count + 1))
    [ "$coolify_ok" = "true" ] || fail_count=$((fail_count + 1))
    [ "$monitor_dns_ok" = "true" ] || fail_count=$((fail_count + 1))
    [ "$deploy_dns_ok" = "true" ] || fail_count=$((fail_count + 1))

    [ "$root_dns_ok" = "true" ] || warning_count=$((warning_count + 1))
    [ "$dns_proxy_count" -eq 0 ] || warning_count=$((warning_count + 1))
    [ "$monitor_local_status" = "up" ] || warning_count=$((warning_count + 1))
    [ "$ssh_open" = "true" ] || warning_count=$((warning_count + 1))

    [ "$fail_count" -eq 0 ] || overall_ok="false"

    local deploy_points monitor_points deploy_proxy monitor_proxy panel_responding
    deploy_points=$(bool_expr '[ -n "$server_ip" ] && [ "$deploy_resolved" = "$server_ip" ]')
    monitor_points=$(bool_expr '[ -n "$server_ip" ] && [ "$monitor_resolved" = "$server_ip" ]')
    deploy_proxy=$(bool_expr '[ -n "$deploy_resolved" ] && { [ -z "$server_ip" ] || [ "$deploy_resolved" != "$server_ip" ]; }')
    monitor_proxy=$(bool_expr '[ -n "$monitor_resolved" ] && { [ -z "$server_ip" ] || [ "$monitor_resolved" != "$server_ip" ]; }')
    panel_responding=$(bool_expr '[ "$monitor_local_status" = "up" ]')

    if [ "$MODE_JSON" -eq 1 ]; then
        cat <<JSON
{
  "ok": $(json_bool "$overall_ok"),
  "public_proxy_mode": "coolify-traefik",
  "base_domain": "${BASE_DOMAIN}",
  "root_domain": "${ROOT_DOMAIN}",
  "www_domain": "${WWW_DOMAIN}",
  "deploy_domain": "${COOLIFY_DOMAIN}",
  "monitor_domain": "${MONITOR_DOMAIN}",
  "infra_domain": "${MONITOR_DOMAIN}",
  "server_ip": "${server_ip}",
  "dns": {
    "root_resolved": "${root_resolved}",
    "www_resolved": "${www_resolved}",
    "deploy_resolved": "${deploy_resolved}",
    "monitor_resolved": "${monitor_resolved}",
    "root_resolves": $(json_bool "$root_dns_ok"),
    "deploy_resolves": $(json_bool "$deploy_dns_ok"),
    "monitor_resolves": $(json_bool "$monitor_dns_ok"),
    "deploy_points_to_server": $(json_bool "$deploy_points"),
    "monitor_points_to_server": $(json_bool "$monitor_points"),
    "infra_points_to_server": $(json_bool "$monitor_points"),
    "deploy_via_proxy": $(json_bool "$deploy_proxy"),
    "monitor_via_proxy": $(json_bool "$monitor_proxy"),
    "infra_via_proxy": $(json_bool "$monitor_proxy"),
    "wildcard_likely_ok": $(json_bool "$wildcard_ok"),
    "checked_count": ${dns_count},
    "direct_count": ${dns_direct_count},
    "proxied_or_cdn_count": ${dns_proxy_count},
    "failed_count": ${dns_fail_count}
  },
  "firewall": {
    "ufw_ssh": "${ssh_status}",
    "ufw_http": "${http_status}",
    "ufw_https": "${https_status}",
    "ssh_open": $(json_bool "$ssh_open"),
    "http_open": $(json_bool "$http_open"),
    "https_open": $(json_bool "$https_open"),
    "panel_port_public_required": false
  },
  "ports": {
    "monitor_internal_port": "${MONITOR_INTERNAL_PORT}",
    "monitor_public": $(json_bool "$monitor_port_public"),
    "postgres_public": $(json_bool "$postgres_public"),
    "redis_public": $(json_bool "$redis_public")
  },
  "services": {
    "docker": "${docker_state}",
    "coolify": "${coolify_state}",
    "host_nginx": "${nginx_state}"
  },
  "panel": {
    "local_url": "http://${MONITOR_BIND}:${MONITOR_INTERNAL_PORT}/",
    "responding": $(json_bool "$panel_responding")
  },
  "proxy": {
    "detected": "${proxy_detected}",
    "mode": "coolify-traefik",
    "ok": $(json_bool "$proxy_ok"),
    "nginx_conflict": $(json_bool "$nginx_conflict")
  },
  "summary": {
    "warnings": ${warning_count},
    "failures": ${fail_count}
  }
}
JSON
        return
    fi

    title "IP publica"
    hr
    [ -n "$server_ip" ] && ok "IP detectada: $server_ip" || warn "No se pudo detectar la IP publica."

    title "DNS Cloudflare"
    hr
    [ "$wildcard_ok" = "true" ] && ok "DNS wildcard configurado o cubierto por CDN" || warn "No se pudo confirmar wildcard A * -> nodo."
    [ "$root_dns_ok" = "true" ] && ok "$ROOT_DOMAIN -> $root_resolved" || warn "$ROOT_DOMAIN sin resolver"
    [ "$deploy_dns_ok" = "true" ] && ok "$COOLIFY_DOMAIN -> $deploy_resolved" || fail "$COOLIFY_DOMAIN sin resolver"
    [ "$monitor_dns_ok" = "true" ] && ok "$MONITOR_DOMAIN -> $monitor_resolved" || fail "$MONITOR_DOMAIN sin resolver"
    [ "$dns_proxy_count" -eq 0 ] || warn "Cloudflare parece proxied/CDN en algun dominio. Recomendado DNS only durante SSL inicial."

    title "Firewall y puertos"
    hr
    [ "$ssh_open" = "true" ] && ok "UFW permite SSH" || warn "UFW no muestra 22/tcp abierto. Verifica acceso SSH."
    [ "$http_open" = "true" ] && ok "UFW permite 80/tcp" || fail "UFW 80/tcp cerrado"
    [ "$https_open" = "true" ] && ok "UFW permite 443/tcp" || fail "UFW 443/tcp cerrado"
    [ "$monitor_port_public" = "false" ] && ok "Puerto ${MONITOR_INTERNAL_PORT} no esta abierto publicamente" || fail "Puerto ${MONITOR_INTERNAL_PORT} expuesto publicamente"
    [ "$postgres_public" = "false" ] && ok "Postgres no esta expuesto publicamente" || fail "Postgres 5432 expuesto publicamente"
    [ "$redis_public" = "false" ] && ok "Redis no esta expuesto publicamente" || fail "Redis 6379 expuesto publicamente"

    title "Docker / Coolify / Traefik"
    hr
    [ "$docker_ok" = "true" ] && ok "Docker activo" || fail "Docker no esta activo"
    [ "$coolify_ok" = "true" ] && ok "Coolify detectado" || fail "Coolify no detectado"
    case "$proxy_detected" in
        coolify-traefik) ok "Coolify/Traefik maneja 80/443" ;;
        nginx) fail "Nginx del host activo compitiendo con Traefik" ;;
        free) fail "80/443 libres: Coolify/Traefik todavia no esta escuchando" ;;
        other|caddy) fail "Otro proxy usa 80/443: $proxy_detected" ;;
    esac
    [ "$nginx_conflict" = "false" ] && ok "Nginx host no esta activo" || fail "Nginx host activo"

    title "Monitor"
    hr
    [ "$monitor_local_status" = "up" ] && ok "Monitor responde localmente" || warn "Monitor local no responde; si se despliega por Coolify, revisar healthcheck del recurso."
    ok "Dominio publico objetivo: https://${MONITOR_DOMAIN}"

    title "Resumen"
    hr
    [ "$wildcard_ok" = "true" ] && ok "DNS wildcard configurado" || warn "DNS wildcard no confirmado"
    [ "$proxy_ok" = "true" ] && ok "Coolify/Traefik maneja 80/443" || fail "Coolify/Traefik no confirmado en 80/443"
    [ "$http_open" = "true" ] && [ "$https_open" = "true" ] && ok "UFW permite 80/443" || fail "UFW no permite 80/443"
    [ "$monitor_port_public" = "false" ] && ok "Monitor preparado para Coolify sin puerto host publico" || fail "Monitor expone puerto host publico"
    [ "$dns_proxy_count" -eq 0 ] || warn "Cloudflare esta proxied: recomendable DNS only durante emision inicial de SSL"
    [ "$nginx_conflict" = "false" ] || fail "Nginx del host activo compitiendo con Traefik"
    sep
    if [ "$overall_ok" = "true" ]; then
        ok "Nodo listo para arquitectura Cloudflare DNS -> Coolify/Traefik -> Apps."
    else
        warn "Requiere accion antes de considerarlo listo. No se declara 'todo en orden'."
    fi
    hr
}

confirm_host_nginx_legacy() {
    title "MODO LEGACY: host-nginx"
    hr
    fail "Este modo NO debe usarse si Coolify/Traefik maneja 80/443."
    warn "Puede crear configuracion de Nginx del host para instalaciones antiguas."
    warn "La arquitectura recomendada publica el monitor como app en Coolify."
    sep
    printf "%b" "  Escribe exactamente USAR HOST NGINX para continuar: " >&2
    read -r confirm </dev/tty
    [ "$confirm" = "USAR HOST NGINX" ] || { warn "Modo legacy cancelado."; exit 1; }
}

run_host_nginx_legacy() {
    confirm_host_nginx_legacy
    if [ "$EUID" -ne 0 ]; then
        fail "El modo host-nginx requiere root. Ejecuta con sudo."
        exit 1
    fi
    if ! command -v nginx >/dev/null 2>&1; then
        printf "%b" "  Instalar Nginx ahora? [s/N]: " >&2
        read -r install_nginx </dev/tty
        if [[ "${install_nginx,,}" = "s" ]]; then
            apt-get update
            apt-get install -y nginx
        else
            fail "Nginx no instalado."
            exit 1
        fi
    fi

    local conf_path="/etc/nginx/sites-available/adema-monitor-legacy.conf"
    local enabled_path="/etc/nginx/sites-enabled/adema-monitor-legacy.conf"
    local backup_dir="/etc/adema/backups/nginx-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    [ -f "$conf_path" ] && cp -a "$conf_path" "$backup_dir/" || true

    cat > "$conf_path" <<NGINXEOF
# Adema Monitor legacy host-nginx proxy
# Generado por setup_domains.sh --proxy-mode host-nginx
server {
    listen 80;
    listen [::]:80;
    server_name ${MONITOR_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${MONITOR_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF
    ln -sf "$conf_path" "$enabled_path"
    nginx -t
    systemctl reload nginx || systemctl restart nginx
    ok "Config legacy creada: $conf_path"
    warn "No se ejecuto certbot. En arquitectura Coolify no uses certbot del host."
}

if [ "$MODE_CHECK" -eq 1 ]; then
    if [ -z "$BASE_DOMAIN" ] && [ -z "$MONITOR_DOMAIN" ]; then
        if [ "$MODE_JSON" -eq 1 ]; then
            printf '{"ok":false,"error":"domains_not_configured","message":"BASE_DOMAIN no definido. Define la variable o crea /etc/adema/domains.env."}\n'
            exit 0
        fi
        err_msg "BASE_DOMAIN no definido y no se encontro configuracion suficiente."
        log "Crea $DOMAINS_ENV_FILE desde ${SCRIPT_DIR}/.domains.env.example o ejecuta el asistente."
        exit 1
    fi
    run_checks
    exit 0
fi

if [ "$PUBLIC_PROXY_MODE" = "host-nginx" ]; then
    prompt_if_empty BASE_DOMAIN "Dominio base del nodo" "ademasistemas.com"
    ROOT_DOMAIN="${ROOT_DOMAIN:-$BASE_DOMAIN}"
    MONITOR_DOMAIN="${MONITOR_DOMAIN:-monitor.${BASE_DOMAIN}}"
    run_host_nginx_legacy
    exit 0
fi

if [ "$PUBLIC_PROXY_MODE" != "coolify-traefik" ]; then
    err_msg "PUBLIC_PROXY_MODE invalido: $PUBLIC_PROXY_MODE. Usa coolify-traefik o host-nginx."
    exit 2
fi

clear >&2 || true
title "Adema Core - Bootstrap DNS para Coolify/Traefik"
hr
log "Cloudflare solo resuelve DNS; Coolify/Traefik es el unico proxy publico en 80/443."
log "deploy.* apunta al panel Coolify; monitor.* apunta al monitor ADEMA como app."
warn "infra.* queda legacy/deprecated y no se usara como dominio principal."
sep

prompt_if_empty BASE_DOMAIN "Dominio base del nodo" "ademasistemas.com"
ROOT_DOMAIN="${ROOT_DOMAIN:-$BASE_DOMAIN}"
WWW_DOMAIN="${WWW_DOMAIN:-www.${BASE_DOMAIN}}"
COOLIFY_DOMAIN="${COOLIFY_DOMAIN:-deploy.${BASE_DOMAIN}}"
MONITOR_DOMAIN="${MONITOR_DOMAIN:-monitor.${BASE_DOMAIN}}"
CLIENTES_DOMAIN="${CLIENTES_DOMAIN:-clientes.${BASE_DOMAIN}}"
API_DOMAIN="${API_DOMAIN:-api.${BASE_DOMAIN}}"
CREDITOS_DOMAIN="${CREDITOS_DOMAIN:-creditos.${BASE_DOMAIN}}"
STOCK_DOMAIN="${STOCK_DOMAIN:-stock.${BASE_DOMAIN}}"
ACADEMY_DOMAIN="${ACADEMY_DOMAIN:-academy.${BASE_DOMAIN}}"
prompt_if_empty MONITOR_INTERNAL_PORT "Puerto interno del monitor" "5000"

sep
log "Matriz de dominios objetivo:"
echo "  ${ROOT_DOMAIN}              -> web institucional" >&2
echo "  ${WWW_DOMAIN}          -> alias web institucional" >&2
echo "  ${COOLIFY_DOMAIN}       -> panel Coolify" >&2
echo "  ${MONITOR_DOMAIN}      -> Adema Monitor" >&2
echo "  ${CLIENTES_DOMAIN}     -> CRM interno" >&2
echo "  ${API_DOMAIN}          -> API central" >&2
echo "  ${CREDITOS_DOMAIN}     -> Gestion de Creditos" >&2
echo "  ${STOCK_DOMAIN}        -> Stock" >&2
echo "  ${ACADEMY_DOMAIN}      -> Academia" >&2
sep

write_domains_env
SERVER_IP=$(detect_public_ip)
print_cloudflare_instructions "$SERVER_IP"
print_coolify_instructions

title "Firewall UFW"
hr
ensure_ufw_rules

sep
printf "%b" "  Continuar con diagnostico ahora? [S/n]: " >&2
read -r run_diag </dev/tty
if [[ "${run_diag,,}" != "n" ]]; then
    run_checks
fi

sep
title "Siguiente paso"
hr
log "En Coolify, crea el recurso adema-monitor desde este repo y asigna https://${MONITOR_DOMAIN}."
log "El puerto interno esperado es ${MONITOR_INTERNAL_PORT}; no publiques puerto host."
log "Ejecuta diagnostico completo con: bash scripts/diagnose_node.sh"
hr