#!/bin/bash
set -euo pipefail
# Adema Core - Configuracion de dominios y proxy reverso
# Repo oficial: https://github.com/adema-releases/monitor
#
# Uso:
#   bash monitor/setup_domains.sh                  # asistente interactivo completo
#   bash monitor/setup_domains.sh --check          # solo verificar, sin modificar
#   bash monitor/setup_domains.sh --check --json   # verificar y devolver JSON (para API)
#
# Variables de entorno soportadas:
#   ADEMA_BASE_DOMAIN     - Dominio base (ej: ademasistemas.com)
#   ADEMA_INFRA_DOMAIN    - Subdominio panel (default: infra.$ADEMA_BASE_DOMAIN)
#   ADEMA_DEPLOY_DOMAIN   - Subdominio Coolify (default: deploy.$ADEMA_BASE_DOMAIN)
#   ADEMA_PANEL_PORT      - Puerto del panel local (default: 5000)
#   ADEMA_PANEL_BIND      - Bind del panel local (default: 127.0.0.1)
#   ADEMA_DOMAINS_ENV_FILE - Ruta al archivo de entorno de dominios
#                            (default: /etc/adema/domains.env)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

DOMAINS_ENV_FILE="${ADEMA_DOMAINS_ENV_FILE:-/etc/adema/domains.env}"

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Flags ─────────────────────────────────────────────────────────────────────
MODE_CHECK=0
MODE_JSON=0
for _arg in "$@"; do
    case "$_arg" in
        --check) MODE_CHECK=1 ;;
        --json)  MODE_JSON=1  ;;
    esac
done
[ "$MODE_JSON" -eq 1 ] && MODE_CHECK=1

# ── Helpers de salida (silencios en modo JSON) ────────────────────────────────
_say()    { [ "$MODE_JSON" -eq 0 ] && echo -e "$*" >&2 || true; }
log()     { _say "${BOLD}[INFO]${RESET}  $*"; }
ok()      { _say "${GREEN}[OK]${RESET}    $*"; }
warn()    { _say "${YELLOW}[WARN]${RESET}  $*"; }
err_msg() { _say "${RED}[ERROR]${RESET} $*"; }
title()   { _say "\n${CYAN}${BOLD}━━━  $*  ━━━${RESET}"; }
hr()      { _say "${CYAN}────────────────────────────────────────────────────${RESET}"; }
sep()     { _say ""; }

# ── Cargar librería común si existe ──────────────────────────────────────────
if [ -f "$LIB_DIR/common.sh" ]; then
    # shellcheck source=lib/common.sh
    source "$LIB_DIR/common.sh"
fi

# ── Cargar archivo de entorno de dominios si existe ───────────────────────────
if [ -f "$DOMAINS_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$DOMAINS_ENV_FILE"
fi

# ── Variables con defaults ────────────────────────────────────────────────────
ADEMA_BASE_DOMAIN="${ADEMA_BASE_DOMAIN:-}"
ADEMA_INFRA_DOMAIN="${ADEMA_INFRA_DOMAIN:-}"
ADEMA_DEPLOY_DOMAIN="${ADEMA_DEPLOY_DOMAIN:-}"
ADEMA_PANEL_PORT="${ADEMA_PANEL_PORT:-5000}"
ADEMA_PANEL_BIND="${ADEMA_PANEL_BIND:-127.0.0.1}"
ADEMA_COOLIFY_PORT="${ADEMA_COOLIFY_PORT:-8000}"

# ── Leer input interactivo ────────────────────────────────────────────────────
prompt_if_empty() {
    local -n _var_ref=$1
    local prompt_text="$2"
    local default_val="${3:-}"

    if [ -n "${_var_ref}" ]; then
        return
    fi

    if [ "$MODE_CHECK" -eq 1 ]; then
        err_msg "Variable $1 no definida. Define ADEMA_BASE_DOMAIN antes de correr con --check."
        exit 1
    fi

    if [ -n "$default_val" ]; then
        printf "%b" "${BOLD}${prompt_text}${RESET} [${CYAN}${default_val}${RESET}]: " >&2
        read -r _input </dev/tty
        _var_ref="${_input:-$default_val}"
    else
        printf "%b" "${BOLD}${prompt_text}${RESET}: " >&2
        read -r _input </dev/tty
        _var_ref="$_input"
    fi
}

# ── Detectar IP pública ───────────────────────────────────────────────────────
detect_public_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 6 ifconfig.me 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 api.ipify.org 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 6 checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    echo "${ip:-}"
}

# ── Resolver dominio DNS ──────────────────────────────────────────────────────
resolve_domain() {
    local domain="${1:-}"
    local resolved=""

    if [ -z "$domain" ]; then echo ""; return; fi

    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
    elif command -v host >/dev/null 2>&1; then
        resolved=$(host "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || true)
    elif command -v nslookup >/dev/null 2>&1; then
        resolved=$(nslookup "$domain" 2>/dev/null | awk '/^Address:/ && !/127\.0\.0\.1/ {print $2; exit}' || true)
    fi

    echo "${resolved:-}"
}

# ── Estado de puerto en UFW ───────────────────────────────────────────────────
ufw_port_status() {
    local port="$1"
    if ! command -v ufw >/dev/null 2>&1; then
        echo "no_ufw"
        return
    fi

    local status
    status=$(ufw status 2>/dev/null || true)

    if echo "$status" | grep -qi "^Status: inactive"; then
        echo "ufw_inactive"
        return
    fi

    # Buscar regla exacta: puerto/tcp o solo puerto como ALLOW o ALLOW IN
    if echo "$status" | grep -qE "^${port}(/tcp)?\s+(ALLOW|ALLOW IN)"; then
        echo "open"
        return
    fi

    echo "closed"
}

# ── Verificar panel local ─────────────────────────────────────────────────────
check_panel_local() {
    local port="${1:-5000}"
    local bind="${2:-127.0.0.1}"
    local url="http://${bind}:${port}/"
    local http_code

    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 "$url" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ]; then
        echo "down"
    else
        echo "up"
    fi
}

# ── Detectar proxy en 80/443 ─────────────────────────────────────────────────
detect_proxy_on_ports() {
    local ports_output=""

    if command -v ss >/dev/null 2>&1; then
        ports_output=$(ss -tulpn 2>/dev/null | grep -E ':(80|443)\b' || true)
    elif command -v netstat >/dev/null 2>&1; then
        ports_output=$(netstat -tulpn 2>/dev/null | grep -E ':(80|443)\b' || true)
    fi

    if echo "$ports_output" | grep -qiE "traefik|coolify"; then
        echo "coolify"
    elif echo "$ports_output" | grep -qi "caddy"; then
        echo "caddy"
    elif echo "$ports_output" | grep -qi "nginx"; then
        echo "nginx"
    elif [ -n "$ports_output" ]; then
        echo "other"
    else
        echo "free"
    fi
}

# ── Generar config Nginx ──────────────────────────────────────────────────────
# Params: domain port bind [conf_name] [ws_upgrade]
#   conf_name:  nombre base del archivo en sites-available (sin .conf), default: adema-core
#   ws_upgrade: 1 para WebSocket/Coolify ("upgrade"), 0 para HTTP normal (panel Flask)
generate_nginx_config() {
    local domain="$1"
    local port="$2"
    local bind="$3"
    local conf_name="${4:-adema-core}"
    local ws_upgrade="${5:-0}"
    local conf_path="/etc/nginx/sites-available/${conf_name}.conf"
    local enabled_path="/etc/nginx/sites-enabled/${conf_name}.conf"

    local connection_header read_timeout
    if [ "$ws_upgrade" = "1" ]; then
        connection_header='"upgrade"'
        read_timeout=120
    else
        connection_header="keep-alive"
        read_timeout=90
    fi

    local nginx_content
    nginx_content="# Adema Core - Proxy reverso
# Generado por setup_domains.sh
# https://github.com/adema-releases/monitor

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # Redirigir a HTTPS si ya tienes certbot instalado
    # return 301 https://\$host\$request_uri;

    location / {
        proxy_pass http://${bind}:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection ${connection_header};
        proxy_read_timeout ${read_timeout};
        proxy_buffering off;
    }
}
"

    if [ "$EUID" -ne 0 ]; then
        warn "Se requiere root para escribir en /etc/nginx/. Ejecuta con sudo."
        sep
        log "Contenido generado para ${conf_path}:"
        echo "$nginx_content"
        return
    fi

    # Verificar si el archivo ya existe con el mismo contenido
    if [ -f "$conf_path" ]; then
        local existing
        existing=$(cat "$conf_path")
        if [ "$existing" = "$nginx_content" ]; then
            ok "Configuracion Nginx ya existente y sin cambios: ${conf_path}"
        else
            warn "El archivo ${conf_path} ya existe con contenido diferente."
            printf "%b" "  ¿Sobreescribir? [s/N]: " >&2
            read -r _overwrite </dev/tty
            if [[ "${_overwrite,,}" != "s" ]]; then
                log "Se conserva configuracion existente."
                return
            fi
            echo "$nginx_content" > "$conf_path"
            ok "Configuracion Nginx actualizada: ${conf_path}"
        fi
    else
        echo "$nginx_content" > "$conf_path"
        ok "Configuracion Nginx creada: ${conf_path}"
    fi

    # Crear symlink si no existe
    if [ ! -L "$enabled_path" ]; then
        ln -s "$conf_path" "$enabled_path"
        ok "Symlink creado: ${enabled_path}"
    else
        ok "Symlink ya existente: ${enabled_path}"
    fi

    # Verificar configuracion de nginx
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>/dev/null; then
            ok "Configuracion Nginx valida."
            nginx -s reload 2>/dev/null && ok "Nginx recargado correctamente." || warn "No se pudo recargar Nginx. Ejecuta: sudo nginx -s reload"
        else
            warn "Error en configuracion Nginx. Revisa con: sudo nginx -t"
        fi
    else
        warn "Nginx no instalado. Instala con: sudo apt install -y nginx"
    fi
}

# ── Instalar certbot (SOLO muestra comando, no ejecuta) ───────────────────────
suggest_certbot() {
    local infra_domain="$1"

    sep
    title "SSL con Let's Encrypt (certbot)"
    hr
    log "Para habilitar HTTPS en ${infra_domain}, ejecuta el siguiente comando:"
    sep
    echo -e "  ${CYAN}sudo certbot --nginx -d ${infra_domain}${RESET}" >&2
    sep
    log "Requisitos antes de correr certbot:"
    echo "  - El dominio ${infra_domain} ya debe apuntar a este servidor (DNS OK)" >&2
    echo "  - El puerto 80 debe estar abierto en UFW" >&2
    echo "  - Nginx debe estar corriendo con la config generada por este script" >&2
    sep
    warn "Certbot NO se ejecutara automaticamente. Corre el comando manualmente cuando el DNS este listo."

    if [ "$EUID" -eq 0 ]; then
        printf "%b" "\n  ¿Ejecutar certbot ahora? [s/N]: " >&2
        read -r _run_certbot </dev/tty
        if [[ "${_run_certbot,,}" = "s" ]]; then
            certbot --nginx -d "$infra_domain"
        else
            log "Certbot omitido. Ejecutalo manualmente cuando el DNS este confirmado."
        fi
    fi
}

# ── Imprimir instrucciones Cloudflare ─────────────────────────────────────────
print_cloudflare_instructions() {
    local server_ip="$1"
    local infra_domain="$2"
    local deploy_domain="$3"

    # Extraer nombre (parte antes del primer punto)
    local infra_name deploy_name base_domain
    infra_name="${infra_domain%%.*}"
    deploy_name="${deploy_domain%%.*}"
    base_domain="${infra_domain#*.}"

    title "Configuracion DNS en Cloudflare"
    hr
    log "Ingresa al panel de Cloudflare → Dominio: ${BOLD}${base_domain}${RESET} → DNS → Registros"
    sep
    log "Si ${BOLD}${base_domain}${RESET} es un dominio dedicado a este nodo (sin otros servicios externos),"
    log "la forma mas simple es un ${BOLD}registro wildcard${RESET} que cubre todos los subdominios:"
    sep
    echo -e "  ${BOLD}Registro recomendado — Wildcard (cubre todos los subdominios)${RESET}" >&2
    echo -e "    Tipo:      ${CYAN}A${RESET}" >&2
    echo -e "    Nombre:    ${CYAN}*${RESET}  (asterisco)" >&2
    echo -e "    Contenido: ${CYAN}${server_ip:-[IP_PUBLICA_DEL_SERVIDOR]}${RESET}" >&2
    echo -e "    TTL:       Auto" >&2
    echo -e "    Proxy:     ${YELLOW}DNS only (nube gris)${RESET}  ← requerido para SSL con certbot/Traefik" >&2
    sep
    echo -e "  ${BOLD}Registro opcional — Raiz del dominio${RESET}" >&2
    echo -e "    Tipo:      ${CYAN}A${RESET}" >&2
    echo -e "    Nombre:    ${CYAN}@${RESET}  (raiz)" >&2
    echo -e "    Contenido: ${CYAN}${server_ip:-[IP_PUBLICA_DEL_SERVIDOR]}${RESET}" >&2
    echo -e "    TTL:       Auto" >&2
    echo -e "    Proxy:     ${YELLOW}DNS only (nube gris)${RESET}" >&2
    sep
    log "Con el wildcard, ${CYAN}${infra_domain}${RESET} y ${CYAN}${deploy_domain}${RESET} quedan resueltos"
    log "automaticamente. Cualquier nueva app en Coolify tambien queda cubierta sin tocar Cloudflare."
    sep
    warn "El wildcard SOLO resuelve DNS. Cada app sigue necesitando configurar"
    warn "su dominio en la UI de Coolify (o en el archivo Traefik) para que el proxy la enrute."
    sep
    log "Si ${BOLD}${base_domain}${RESET} ya tiene otros servicios en subdominios que apuntan a proveedores"
    log "distintos, podes usar registros A explicitos en lugar del wildcard:"
    echo -e "    ${CYAN}${infra_name}${RESET} → ${server_ip:-[IP_PUBLICA_DEL_SERVIDOR]}  (panel Adema Core)" >&2
    echo -e "    ${CYAN}${deploy_name}${RESET} → ${server_ip:-[IP_PUBLICA_DEL_SERVIDOR]}  (Coolify)" >&2
    log "Ambos enfoques son validos y pueden coexistir si es necesario."
    sep
    warn "¿Por que DNS only?  Coolify y certbot necesitan resolver el IP real del servidor."
    warn "Activar el proxy de Cloudflare puede interferir con la validacion ACME de Let's Encrypt."
    warn "Una vez con SSL estable, puedes activar el proxy de Cloudflare si lo deseas."
    hr
}

# ── Sugerir apertura de puertos UFW ──────────────────────────────────────────
suggest_ufw_rules() {
    local http_status="$1"
    local https_status="$2"

    if [ "$http_status" = "open" ] && [ "$https_status" = "open" ]; then
        ok "UFW: 80/tcp y 443/tcp ya estan abiertos."
        return
    fi

    sep
    title "Reglas UFW recomendadas"
    hr
    warn "Algunos puertos necesarios para HTTPS no estan abiertos:"

    if [ "$http_status" != "open" ]; then
        echo -e "  ${YELLOW}Puerto 80 no abierto.${RESET} Ejecuta:" >&2
        echo -e "  ${CYAN}sudo ufw allow 80/tcp comment 'HTTP'${RESET}" >&2
    else
        ok "Puerto 80/tcp: abierto."
    fi

    if [ "$https_status" != "open" ]; then
        echo -e "  ${YELLOW}Puerto 443 no abierto.${RESET} Ejecuta:" >&2
        echo -e "  ${CYAN}sudo ufw allow 443/tcp comment 'HTTPS'${RESET}" >&2
    else
        ok "Puerto 443/tcp: abierto."
    fi

    if [ "$http_status" = "ufw_inactive" ] || [ "$https_status" = "ufw_inactive" ]; then
        warn "UFW esta inactivo. Si no usas otro firewall, puedes activarlo con:"
        echo -e "  ${CYAN}sudo ufw allow OpenSSH${RESET}" >&2
        echo -e "  ${CYAN}sudo ufw allow 80/tcp comment 'HTTP'${RESET}" >&2
        echo -e "  ${CYAN}sudo ufw allow 443/tcp comment 'HTTPS'${RESET}" >&2
        echo -e "  ${CYAN}sudo ufw --force enable${RESET}" >&2
    fi

    hr
    warn "IMPORTANTE: No abras el puerto ${ADEMA_PANEL_PORT} publicamente."
    log "El panel en :${ADEMA_PANEL_PORT} es accesible a traves del proxy reverso (Nginx o Coolify)."
}

# ── Imprimir instrucciones MODO B (Coolify como proxy) ───────────────────────
print_coolify_proxy_instructions() {
    local infra_domain="$1"
    local panel_port="$2"
    local panel_bind="$3"

    title "MODO B: Publicar panel a traves de Coolify"
    hr
    warn "Coolify o Traefik ya esta usando los puertos 80/443."
    warn "NO se instalara Nginx del host para evitar conflictos."
    sep
    log "Para acceder a ${infra_domain} a traves de Coolify:"
    sep
    echo -e "  ${BOLD}Opcion recomendada: Proxy en Coolify${RESET}" >&2
    echo "" >&2
    echo -e "  1. En Coolify → Settings → Proxy → Traefik Dashboard" >&2
    echo -e "     O bien: crea un nuevo servicio de tipo 'Generic'." >&2
    echo "" >&2
    echo -e "  2. Crea una aplicacion 'Redirect' o 'Generic' en Coolify:" >&2
    echo -e "     - Domain:  ${CYAN}https://${infra_domain}${RESET}" >&2
    echo -e "     - Proxy a: ${CYAN}http://${panel_bind}:${panel_port}${RESET}" >&2
    echo "" >&2
    echo -e "  3. Alternativa via archivo Traefik en /etc/coolify/proxy/dynamic/:" >&2
    echo "" >&2
    echo -e "     Crea el archivo:" >&2
    echo -e "     ${CYAN}/etc/coolify/proxy/dynamic/adema-core.yml${RESET}" >&2
    echo "" >&2
    cat >&2 <<TRAEFIK_YAML
     Contenido del archivo:
     ──────────────────────────────────────────────
     http:
       routers:
         adema-core:
           rule: "Host(\`${infra_domain}\`)"
           service: adema-core-svc
           entryPoints:
             - websecure
           tls:
             certResolver: letsencrypt

       services:
         adema-core-svc:
           loadBalancer:
             servers:
               - url: "http://${panel_bind}:${panel_port}"
     ──────────────────────────────────────────────
TRAEFIK_YAML
    sep
    warn "Coolify gestiona el SSL automaticamente con su certResolver configurado."
    log "Despues de agregar la config, verifica en los logs de Traefik que el router este activo."
    hr
}

# ── Diagnostico cuando el panel no responde ───────────────────────────────────
diagnose_panel_down() {
    sep
    title "Diagnostico: panel local no responde"
    hr
    warn "El panel en http://${ADEMA_PANEL_BIND}:${ADEMA_PANEL_PORT}/ no esta respondiendo."
    sep
    log "Verifica el estado del servicio:"
    echo -e "  ${CYAN}sudo systemctl status adema-web-panel.service${RESET}" >&2
    echo -e "  ${CYAN}sudo journalctl -u adema-web-panel.service -n 80 --no-pager${RESET}" >&2
    sep
    log "Si el servicio no existe, instala el panel con:"
    echo -e "  ${CYAN}sudo bash setup_web_panel.sh${RESET}" >&2
    sep

    if command -v systemctl >/dev/null 2>&1; then
        log "Estado actual del servicio:"
        systemctl status adema-web-panel.service --no-pager 2>/dev/null || \
            warn "No se pudo consultar el estado (puede requerir sudo)."
    fi
    hr
}

# ── Función de verificaciones completa ────────────────────────────────────────
run_checks() {
    local server_ip
    server_ip=$(detect_public_ip)

    local infra_resolved deploy_resolved
    infra_resolved=$(resolve_domain "${ADEMA_INFRA_DOMAIN:-}")
    deploy_resolved=$(resolve_domain "${ADEMA_DEPLOY_DOMAIN:-}")

    local infra_ok="false" deploy_ok="false"
    local infra_resolves="false" deploy_resolves="false"
    local infra_via_proxy="false" deploy_via_proxy="false"
    if [ -n "$infra_resolved" ]; then
        infra_resolves="true"
        if [ -n "$server_ip" ] && [ "$infra_resolved" = "$server_ip" ]; then
            infra_ok="true"
        else
            infra_via_proxy="true"
        fi
    fi
    if [ -n "$deploy_resolved" ]; then
        deploy_resolves="true"
        if [ -n "$server_ip" ] && [ "$deploy_resolved" = "$server_ip" ]; then
            deploy_ok="true"
        else
            deploy_via_proxy="true"
        fi
    fi

    local http_status https_status
    http_status=$(ufw_port_status 80)
    https_status=$(ufw_port_status 443)
    local http_open="false" https_open="false"
    [ "$http_status" = "open" ] && http_open="true"
    [ "$https_status" = "open" ] && https_open="true"

    local panel_status
    panel_status=$(check_panel_local "$ADEMA_PANEL_PORT" "$ADEMA_PANEL_BIND")
    local panel_responding="false"
    [ "$panel_status" = "up" ] && panel_responding="true"

    local proxy_mode
    proxy_mode=$(detect_proxy_on_ports)

    local proxy_compat_mode="A"
    if [ "$proxy_mode" = "coolify" ] || [ "$proxy_mode" = "caddy" ]; then
        proxy_compat_mode="B"
    fi

    local overall_ok="true"
    # DNS ok si resuelve a algo (directo o via CDN); panel debe responder
    if [ "$infra_resolves" = "false" ] || [ "$deploy_resolves" = "false" ] || [ "$panel_responding" = "false" ]; then
        overall_ok="false"
    fi

    # ── Salida JSON ──────────────────────────────────────────────────────────
    if [ "$MODE_JSON" -eq 1 ]; then
        printf '{\n'
        printf '  "ok": %s,\n'                       "$overall_ok"
        printf '  "infra_domain": "%s",\n'            "${ADEMA_INFRA_DOMAIN:-}"
        printf '  "deploy_domain": "%s",\n'           "${ADEMA_DEPLOY_DOMAIN:-}"
        printf '  "server_ip": "%s",\n'               "$server_ip"
        printf '  "dns": {\n'
        printf '    "infra_resolved": "%s",\n'        "$infra_resolved"
        printf '    "deploy_resolved": "%s",\n'       "$deploy_resolved"
        printf '    "infra_resolves": %s,\n'           "$infra_resolves"
        printf '    "deploy_resolves": %s,\n'          "$deploy_resolves"
        printf '    "infra_points_to_server": %s,\n'  "$infra_ok"
        printf '    "deploy_points_to_server": %s,\n' "$deploy_ok"
        printf '    "infra_via_proxy": %s,\n'          "$infra_via_proxy"
        printf '    "deploy_via_proxy": %s\n'          "$deploy_via_proxy"
        printf '  },\n'
        printf '  "firewall": {\n'
        printf '    "ufw_http": "%s",\n'              "$http_status"
        printf '    "ufw_https": "%s",\n'             "$https_status"
        printf '    "http_open": %s,\n'               "$http_open"
        printf '    "https_open": %s,\n'              "$https_open"
        printf '    "panel_port_public_required": false\n'
        printf '  },\n'
        printf '  "panel": {\n'
        printf '    "local_url": "http://%s:%s/",\n'  "$ADEMA_PANEL_BIND" "$ADEMA_PANEL_PORT"
        printf '    "responding": %s\n'               "$panel_responding"
        printf '  },\n'
        printf '  "proxy": {\n'
        printf '    "detected": "%s",\n'              "$proxy_mode"
        printf '    "mode": "%s"\n'                   "$proxy_compat_mode"
        printf '  }\n'
        printf '}\n'
        return
    fi

    # ── Salida legible para humanos ──────────────────────────────────────────
    title "IP publica del servidor"
    hr
    if [ -n "$server_ip" ]; then
        ok "IP detectada: ${BOLD}${server_ip}${RESET}"
    else
        warn "No se pudo detectar la IP publica (curl fallido o sin internet)."
    fi

    title "Verificacion DNS"
    hr

    if [ -n "${ADEMA_INFRA_DOMAIN:-}" ]; then
        if [ "$infra_ok" = "true" ]; then
            ok "${ADEMA_INFRA_DOMAIN} → ${infra_resolved} ✓"
        elif [ "$infra_via_proxy" = "true" ]; then
            ok "${ADEMA_INFRA_DOMAIN} → ${infra_resolved} (via CDN/proxy, no IP directa del servidor)"
            log "El dominio resuelve correctamente. Si usas Cloudflare proxy (nube naranja), la IP que ve dig es de Cloudflare."
        else
            warn "${ADEMA_INFRA_DOMAIN} → [sin resolver] (esperado: ${server_ip:-desconocido})"
            log "No apunta al servidor. Agrega el registro A en Cloudflare y espera la propagacion DNS."
        fi
    else
        warn "ADEMA_INFRA_DOMAIN no configurado."
    fi

    if [ -n "${ADEMA_DEPLOY_DOMAIN:-}" ]; then
        if [ "$deploy_ok" = "true" ]; then
            ok "${ADEMA_DEPLOY_DOMAIN} → ${deploy_resolved} ✓"
        elif [ "$deploy_via_proxy" = "true" ]; then
            ok "${ADEMA_DEPLOY_DOMAIN} → ${deploy_resolved} (via CDN/proxy, no IP directa del servidor)"
            log "El dominio resuelve correctamente. Si usas Cloudflare proxy (nube naranja), la IP que ve dig es de Cloudflare."
        else
            warn "${ADEMA_DEPLOY_DOMAIN} → [sin resolver] (esperado: ${server_ip:-desconocido})"
            log "No apunta al servidor. Agrega el registro A en Cloudflare y espera la propagacion DNS."
        fi
    else
        warn "ADEMA_DEPLOY_DOMAIN no configurado."
    fi

    title "Firewall UFW"
    hr
    suggest_ufw_rules "$http_status" "$https_status"

    title "Panel local"
    hr
    if [ "$panel_responding" = "true" ]; then
        ok "http://${ADEMA_PANEL_BIND}:${ADEMA_PANEL_PORT}/ → respondiendo ✓"
    else
        diagnose_panel_down
    fi

    title "Proxy en puertos 80/443"
    hr
    case "$proxy_mode" in
        coolify) ok "Coolify/Traefik detectado en 80/443 → MODO B (proxy via Coolify)" ;;
        caddy)   ok "Caddy detectado en 80/443 → MODO B (no instalar Nginx del host)" ;;
        nginx)   ok "Nginx detectado en 80/443 → el script puede gestionar la config" ;;
        other)   warn "Proceso desconocido en 80/443. Verifica con: sudo ss -tulpn | grep -E ':80|:443'" ;;
        free)    log "Puertos 80/443 libres → MODO A disponible (instalar Nginx del host)" ;;
    esac

    sep
    title "Resumen"
    hr
    [ "$infra_ok" = "true" ]         && ok  "DNS infra:     OK (directo)" \
      || { [ "$infra_via_proxy" = "true" ] && ok "DNS infra:     OK (via CDN/proxy)" || warn "DNS infra:     pendiente (sin resolver)"; }
    [ "$deploy_ok" = "true" ]         && ok  "DNS deploy:    OK (directo)" \
      || { [ "$deploy_via_proxy" = "true" ] && ok "DNS deploy:    OK (via CDN/proxy)" || warn "DNS deploy:    pendiente (sin resolver)"; }
    [ "$http_open" = "true" ]      && ok  "UFW 80/tcp:    abierto" || warn "UFW 80/tcp:    cerrado"
    [ "$https_open" = "true" ]     && ok  "UFW 443/tcp:   abierto" || warn "UFW 443/tcp:   cerrado"
    [ "$panel_responding" = "true" ] && ok "Panel local:   activo"  || warn "Panel local:   sin respuesta"
    sep

    if [ "$overall_ok" = "true" ]; then
        ok "${BOLD}Todo en orden. El nodo esta listo para operar por dominio.${RESET}"
    else
        warn "${BOLD}Algunos items necesitan atencion antes de operar por dominio.${RESET}"
        log "Consulta docs/09-domain-setup.md para el procedimiento completo."
    fi
    hr
}

# ── Modo --check: solo verificar ─────────────────────────────────────────────
if [ "$MODE_CHECK" -eq 1 ]; then
    if [ -z "${ADEMA_BASE_DOMAIN:-}" ] && [ -z "${ADEMA_INFRA_DOMAIN:-}" ]; then
        if [ "$MODE_JSON" -eq 1 ]; then
            printf '{"ok":false,"error":"domains_not_configured","message":"ADEMA_BASE_DOMAIN no definido. Define la variable o crea /etc/adema/domains.env."}\n'
            exit 0
        fi
        err_msg "ADEMA_BASE_DOMAIN no definido y no se encontro ${DOMAINS_ENV_FILE}."
        log "Opciones:"
        echo "  1) Correr el asistente interactivo para generarlo automaticamente:" >&2
        echo "       sudo bash monitor/setup_domains.sh" >&2
        echo "" >&2
        echo "  2) Crearlo manualmente desde el template:" >&2
        echo "       sudo mkdir -p /etc/adema" >&2
        echo "       sudo cp ${SCRIPT_DIR}/.domains.env.example /etc/adema/domains.env" >&2
        echo "       sudo nano /etc/adema/domains.env" >&2
        exit 1
    fi

    # Derivar dominios si solo se tiene la base
    if [ -n "${ADEMA_BASE_DOMAIN:-}" ]; then
        ADEMA_INFRA_DOMAIN="${ADEMA_INFRA_DOMAIN:-infra.${ADEMA_BASE_DOMAIN}}"
        ADEMA_DEPLOY_DOMAIN="${ADEMA_DEPLOY_DOMAIN:-deploy.${ADEMA_BASE_DOMAIN}}"
    fi

    run_checks
    exit 0
fi

# ── Modo interactivo completo ─────────────────────────────────────────────────
clear >&2 || true
title "Adema Core - Configuracion de dominios"
hr
log "Este asistente configura acceso por dominio al panel y a Coolify."
log "Puedes cancelar en cualquier momento con Ctrl+C."
if [ ! -f "$DOMAINS_ENV_FILE" ]; then
    sep
    log "No se encontro ${DOMAINS_ENV_FILE}."
    log "Al finalizar, el asistente ofrecera guardarlo. Si prefieres crearlo manualmente:"
    echo "    sudo cp ${SCRIPT_DIR}/.domains.env.example /etc/adema/domains.env" >&2
    echo "    sudo nano /etc/adema/domains.env" >&2
fi
sep

prompt_if_empty ADEMA_BASE_DOMAIN "Dominio base del servidor (ej: ademasistemas.com)" ""
ADEMA_INFRA_DOMAIN="${ADEMA_INFRA_DOMAIN:-infra.${ADEMA_BASE_DOMAIN}}"
ADEMA_DEPLOY_DOMAIN="${ADEMA_DEPLOY_DOMAIN:-deploy.${ADEMA_BASE_DOMAIN}}"
prompt_if_empty ADEMA_INFRA_DOMAIN "Dominio panel Adema Core" "${ADEMA_INFRA_DOMAIN}"
prompt_if_empty ADEMA_DEPLOY_DOMAIN "Dominio Coolify" "${ADEMA_DEPLOY_DOMAIN}"
prompt_if_empty ADEMA_PANEL_PORT "Puerto del panel local" "5000"
prompt_if_empty ADEMA_PANEL_BIND "Bind del panel local" "127.0.0.1"
prompt_if_empty ADEMA_COOLIFY_PORT "Puerto local de Coolify" "8000"

sep
log "Configuracion:"
log "  Dominio infra:   ${ADEMA_INFRA_DOMAIN}  (panel → :${ADEMA_PANEL_PORT})"
log "  Dominio deploy:  ${ADEMA_DEPLOY_DOMAIN}  (Coolify → :${ADEMA_COOLIFY_PORT})"
log "  Panel local:     http://${ADEMA_PANEL_BIND}:${ADEMA_PANEL_PORT}/"
sep

# Ofrecer guardar en /etc/adema/domains.env
if [ "$EUID" -eq 0 ]; then
    printf "%b" "  ¿Guardar configuracion en ${DOMAINS_ENV_FILE}? [S/n]: " >&2
    read -r _save_env </dev/tty
    if [[ "${_save_env,,}" != "n" ]]; then
        mkdir -p "$(dirname "$DOMAINS_ENV_FILE")"
        cat > "$DOMAINS_ENV_FILE" <<ENVEOF
# Adema Core - Configuracion de dominios
# Generado por setup_domains.sh
ADEMA_BASE_DOMAIN=${ADEMA_BASE_DOMAIN}
ADEMA_INFRA_DOMAIN=${ADEMA_INFRA_DOMAIN}
ADEMA_DEPLOY_DOMAIN=${ADEMA_DEPLOY_DOMAIN}
ADEMA_PANEL_PORT=${ADEMA_PANEL_PORT}
ADEMA_PANEL_BIND=${ADEMA_PANEL_BIND}
ADEMA_COOLIFY_PORT=${ADEMA_COOLIFY_PORT}
ENVEOF
        chmod 640 "$DOMAINS_ENV_FILE"
        ok "Configuracion guardada en ${DOMAINS_ENV_FILE}"
    fi
fi

# Detectar IP y mostrar instrucciones Cloudflare
SERVER_IP=$(detect_public_ip)
print_cloudflare_instructions "$SERVER_IP" "$ADEMA_INFRA_DOMAIN" "$ADEMA_DEPLOY_DOMAIN"

sep
title "Esperando confirmacion DNS"
hr
printf "%b" "  Continuar cuando hayas creado los registros DNS en Cloudflare [Enter o Ctrl+C para salir]: " >&2
read -r _ </dev/tty

# Ejecutar verificaciones
run_checks

# Detectar modo proxy
PROXY_MODE=$(detect_proxy_on_ports)

sep
case "$PROXY_MODE" in
    coolify|caddy)
        print_coolify_proxy_instructions "$ADEMA_INFRA_DOMAIN" "$ADEMA_PANEL_PORT" "$ADEMA_PANEL_BIND"
        ;;
    *)
        title "Configuracion de proxy reverso (MODO A - Nginx del host)"
        hr

        if ! command -v nginx >/dev/null 2>&1; then
            warn "Nginx no esta instalado."
            printf "%b" "  ¿Instalar Nginx ahora? [S/n]: " >&2
            read -r _install_nginx </dev/tty
            if [[ "${_install_nginx,,}" != "n" ]]; then
                if [ "$EUID" -ne 0 ]; then
                    warn "Se requiere root. Ejecuta: sudo apt install -y nginx"
                else
                    apt-get install -y nginx
                    ok "Nginx instalado."
                fi
            fi
        else
            ok "Nginx instalado: $(nginx -v 2>&1 || true)"
        fi

        sep
        printf "%b" "  ¿Generar config Nginx para ${ADEMA_INFRA_DOMAIN} (panel → :${ADEMA_PANEL_PORT})? [S/n]: " >&2
        read -r _gen_nginx </dev/tty
        if [[ "${_gen_nginx,,}" != "n" ]]; then
            generate_nginx_config "$ADEMA_INFRA_DOMAIN" "$ADEMA_PANEL_PORT" "$ADEMA_PANEL_BIND" "adema-core" "0"
        fi

        sep
        printf "%b" "  ¿Generar config Nginx para ${ADEMA_DEPLOY_DOMAIN} (Coolify → :${ADEMA_COOLIFY_PORT})? [S/n]: " >&2
        read -r _gen_deploy </dev/tty
        if [[ "${_gen_deploy,,}" != "n" ]]; then
            generate_nginx_config "$ADEMA_DEPLOY_DOMAIN" "$ADEMA_COOLIFY_PORT" "127.0.0.1" "coolify-deploy" "1"
        fi

        suggest_certbot "$ADEMA_INFRA_DOMAIN"
        if [ -n "${ADEMA_DEPLOY_DOMAIN:-}" ]; then
            suggest_certbot "$ADEMA_DEPLOY_DOMAIN"
        fi
        ;;
esac

sep
title "Configuracion completada"
hr
ok  "Panel Adema Core:  https://${ADEMA_INFRA_DOMAIN}"
log "Coolify:           https://${ADEMA_DEPLOY_DOMAIN}"
log "Panel local:       http://${ADEMA_PANEL_BIND}:${ADEMA_PANEL_PORT}/"
sep
log "Para verificar el estado en cualquier momento:"
echo -e "  ${CYAN}bash monitor/setup_domains.sh --check${RESET}" >&2
log "Para obtener estado en JSON (uso por API):"
echo -e "  ${CYAN}bash monitor/setup_domains.sh --check --json${RESET}" >&2
hr
