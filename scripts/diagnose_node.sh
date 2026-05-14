#!/bin/bash
set -euo pipefail
# Adema Core - Diagnostico de nodo Coolify/Traefik

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAINS_ENV_FILE="${ADEMA_DOMAINS_ENV_FILE:-/etc/adema/domains.env}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail() { echo -e "${RED}[FAIL]${RESET}  $*"; }
info() { echo -e "${BOLD}[INFO]${RESET}  $*"; }
title() { echo -e "\n${CYAN}${BOLD}...  $*  ...${RESET}"; }

if [ -f "$DOMAINS_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$DOMAINS_ENV_FILE"
fi

BASE_DOMAIN="${BASE_DOMAIN:-${ADEMA_BASE_DOMAIN:-ademasistemas.com}}"
ROOT_DOMAIN="${ROOT_DOMAIN:-$BASE_DOMAIN}"
WWW_DOMAIN="${WWW_DOMAIN:-www.${BASE_DOMAIN}}"
COOLIFY_DOMAIN="${COOLIFY_DOMAIN:-${ADEMA_DEPLOY_DOMAIN:-deploy.${BASE_DOMAIN}}}"
MONITOR_DOMAIN="${MONITOR_DOMAIN:-${ADEMA_INFRA_DOMAIN:-monitor.${BASE_DOMAIN}}}"
CLIENTES_DOMAIN="${CLIENTES_DOMAIN:-clientes.${BASE_DOMAIN}}"
API_DOMAIN="${API_DOMAIN:-api.${BASE_DOMAIN}}"
CREDITOS_DOMAIN="${CREDITOS_DOMAIN:-creditos.${BASE_DOMAIN}}"
STOCK_DOMAIN="${STOCK_DOMAIN:-stock.${BASE_DOMAIN}}"
ACADEMY_DOMAIN="${ACADEMY_DOMAIN:-academy.${BASE_DOMAIN}}"
MONITOR_INTERNAL_PORT="${MONITOR_INTERNAL_PORT:-${ADEMA_PANEL_PORT:-5000}}"
PUBLIC_PROXY_MODE="${PUBLIC_PROXY_MODE:-coolify-traefik}"

FAILS=0
WARNS=0

mark_fail() { FAILS=$((FAILS + 1)); fail "$*"; }
mark_warn() { WARNS=$((WARNS + 1)); warn "$*"; }

detect_public_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 6 ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    echo "${ip:-}"
}

resolve_domain() {
    local domain="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true
    elif command -v host >/dev/null 2>&1; then
        host "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$domain" 2>/dev/null | awk '/^Address:/ && !/127\.0\.0\.1/ {print $2; exit}' || true
    fi
}

ufw_has_port() {
    local port="$1"
    command -v ufw >/dev/null 2>&1 || { echo "no_ufw"; return; }
    local status
    status=$(ufw status 2>/dev/null || true)
    echo "$status" | grep -qi '^Status: inactive' && { echo "inactive"; return; }
    echo "$status" | grep -qE "^${port}(/tcp)?[[:space:]]+(ALLOW|ALLOW IN)" && echo "open" || echo "closed"
}

port_output() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -E ":${port}\b" || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -E ":${port}\b" || true
    fi
}

port_is_public() {
    local output
    output=$(port_output "$1")
    [ -z "$output" ] && return 1
    echo "$output" | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\[::\]|\*)[:.]'
}

title "IP publica"
SERVER_IP=$(detect_public_ip)
[ -n "$SERVER_IP" ] && ok "IP detectada: $SERVER_IP" || mark_warn "No se pudo detectar IP publica"

title "DNS"
DOMAINS=(
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
DNS_PROXY_WARN=0
DNS_FAIL=0
for domain in "${DOMAINS[@]}"; do
    resolved=$(resolve_domain "$domain")
    if [ -z "$resolved" ]; then
        DNS_FAIL=$((DNS_FAIL + 1))
        mark_fail "$domain sin resolver"
    elif [ -n "$SERVER_IP" ] && [ "$resolved" = "$SERVER_IP" ]; then
        ok "$domain -> $resolved"
    else
        DNS_PROXY_WARN=$((DNS_PROXY_WARN + 1))
        mark_warn "$domain -> $resolved (posible Cloudflare proxied/CDN; recomendado DNS only para SSL inicial)"
    fi
done
[ "$DNS_FAIL" -eq 0 ] && ok "DNS wildcard configurado para la matriz del nodo" || true

title "UFW"
for port in 22 80 443; do
    state=$(ufw_has_port "$port")
    if [ "$state" = "open" ]; then
        ok "UFW permite ${port}/tcp"
    elif [ "$state" = "inactive" ]; then
        mark_warn "UFW inactivo; verificar firewall externo para ${port}/tcp"
    else
        mark_fail "UFW no permite ${port}/tcp"
    fi
done

title "Puertos 80/443"
PORTS_80_443="$(port_output 80; port_output 443)"
if echo "$PORTS_80_443" | grep -qiE 'traefik|coolify'; then
    ok "Coolify/Traefik maneja 80/443"
elif echo "$PORTS_80_443" | grep -qi nginx; then
    mark_fail "Nginx del host activo compitiendo con Traefik"
elif [ -n "$PORTS_80_443" ]; then
    mark_fail "Otro proceso ocupa 80/443"
    echo "$PORTS_80_443"
else
    mark_fail "80/443 libres: Coolify/Traefik no esta escuchando"
fi

title "Docker / Coolify"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker activo"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' | sed -n '1,20p'
    if docker ps --format '{{.Names}} {{.Image}}' | grep -qiE 'coolify|traefik'; then
        ok "Coolify/Traefik detectado en Docker"
    else
        mark_fail "No se detectan contenedores Coolify/Traefik"
    fi
else
    mark_fail "Docker no disponible o no activo"
fi

title "Servicios host"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
        if [ "$PUBLIC_PROXY_MODE" = "coolify-traefik" ]; then
            mark_fail "Nginx host activo con PUBLIC_PROXY_MODE=coolify-traefik"
        else
            mark_warn "Nginx host activo en modo legacy"
        fi
    else
        ok "Nginx host no esta activo"
    fi
    systemctl is-active --quiet docker 2>/dev/null && ok "Servicio docker activo" || mark_warn "systemctl no reporta docker activo"
fi

title "Puertos internos"
if port_is_public "$MONITOR_INTERNAL_PORT"; then
    mark_fail "Puerto ${MONITOR_INTERNAL_PORT} expuesto publicamente"
else
    ok "Puerto ${MONITOR_INTERNAL_PORT} no esta abierto publicamente"
fi
if port_is_public 5432; then
    mark_fail "Postgres 5432 expuesto publicamente"
else
    ok "Postgres no esta expuesto publicamente"
fi
if port_is_public 6379; then
    mark_fail "Redis 6379 expuesto publicamente"
else
    ok "Redis no esta expuesto publicamente"
fi

title "Monitor"
if curl -fsS --max-time 5 "http://127.0.0.1:${MONITOR_INTERNAL_PORT}/healthz" >/dev/null 2>&1; then
    ok "Monitor responde localmente en /healthz"
elif curl -fsS --max-time 5 "http://127.0.0.1:${MONITOR_INTERNAL_PORT}/" >/dev/null 2>&1; then
    ok "Monitor responde localmente"
else
    mark_warn "Monitor local no responde; si corre en Coolify, revisar healthcheck del recurso"
fi

if [ -f "$ROOT_DIR/compose.yml" ] && [ -f "$ROOT_DIR/Dockerfile" ]; then
    ok "Monitor preparado para Coolify con Dockerfile y compose.yml"
else
    mark_fail "Faltan Dockerfile o compose.yml para Coolify"
fi

title "Resumen final"
[ "$DNS_FAIL" -eq 0 ] && ok "DNS wildcard configurado" || mark_fail "DNS incompleto"
echo "$PORTS_80_443" | grep -qiE 'traefik|coolify' && ok "Coolify/Traefik maneja 80/443" || mark_fail "Coolify/Traefik no confirmado en 80/443"
[ "$(ufw_has_port 80)" = "open" ] && [ "$(ufw_has_port 443)" = "open" ] && ok "UFW permite 80/443" || mark_fail "UFW no permite 80/443"
[ "$DNS_PROXY_WARN" -eq 0 ] || warn "Cloudflare esta proxied: recomendable DNS only durante emision inicial de SSL"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null && [ "$PUBLIC_PROXY_MODE" = "coolify-traefik" ]; then
    fail "Nginx del host activo compitiendo con Traefik"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    ok "Diagnostico completado sin fallos bloqueantes (${WARNS} warnings)."
else
    fail "Diagnostico con ${FAILS} fallos y ${WARNS} warnings. Requiere accion."
    exit 1
fi