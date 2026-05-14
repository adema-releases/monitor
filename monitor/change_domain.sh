#!/bin/bash
set -euo pipefail
# ADEMA Node Lite - cambio seguro de dominio base del nodo
# Uso: sudo adema-node change-domain excel-ente.com.ar [opciones]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/common.sh"

NODE_ENV_FILE="${ADEMA_NODE_ENV_FILE:-/etc/adema/node.env}"
DOMAINS_ENV_FILE="${ADEMA_DOMAINS_ENV_FILE:-/etc/adema/domains.env}"
NEW_BASE_DOMAIN=""
NEW_INFRA_DOMAIN=""
NEW_DEPLOY_DOMAIN=""
DRY_RUN=0
YES=0
CHECK_ONLY=0

usage() {
    cat <<HELP
Uso: sudo adema-node change-domain DOMINIO_BASE [opciones]

Ejemplo:
  sudo adema-node change-domain excel-ente.com.ar

Opciones:
  --infra-domain DOMINIO   Dominio del panel/infra (default: infra.DOMINIO_BASE)
  --deploy-domain DOMINIO  Dominio de Coolify/deploy (default: deploy.DOMINIO_BASE)
  --dry-run                Muestra cambios sin escribir archivos
  --yes                    No pide confirmacion interactiva
  --check-only             No cambia nada; muestra dominios actuales y ejecuta setup_domains.sh --check si existe
HELP
}

to_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_forbidden_domain() {
    local value
    value="$(to_lower "${1:-}")"
    case "$value" in
        ''|localhost|example.com|example.org|example.net|test|demo|invalid|*.localhost|*.example.com|*.test|*.invalid)
            return 0
            ;;
    esac
    return 1
}

validate_domain() {
    local domain="$(to_lower "${1:-}")"
    local label

    if is_forbidden_domain "$domain"; then
        echo "Error: dominio no permitido: ${domain:-vacio}" >&2
        return 1
    fi

    if [ "${#domain}" -gt 253 ] || ! echo "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
        echo "Error: dominio invalido o poco razonable: $domain" >&2
        return 1
    fi

    if ! echo "$domain" | awk -F. '{print $NF}' | grep -Eq '^[a-z]{2,63}$'; then
        echo "Error: TLD invalido en dominio: $domain" >&2
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        if [ "${#label}" -lt 1 ] || [ "${#label}" -gt 63 ]; then
            echo "Error: label DNS invalido en dominio: $domain" >&2
            return 1
        fi
    done

    return 0
}

backup_file_if_exists() {
    local file="$1"
    local stamp="$2"
    if [ -f "$file" ]; then
        cp -a "$file" "${file}.bak.${stamp}"
        echo "Backup creado: ${file}.bak.${stamp}"
    fi
}

upsert_env_file() {
    local file="$1"
    shift
    local tmp_file
    tmp_file="$(mktemp)"

    touch "$file"
    awk -v updates="$*" '
    BEGIN {
        n = split(updates, pairs, "\034")
        for (i = 1; i <= n; i++) {
            if (pairs[i] == "") continue
            split(pairs[i], kv, "=")
            key = kv[1]
            value = substr(pairs[i], length(key) + 2)
            wanted[key] = value
            order[++count] = key
        }
    }
    {
        line = $0
        if (line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) {
            key = line
            sub(/^[[:space:]]*/, "", key)
            sub(/=.*/, "", key)
            if (key in wanted) {
                print key "=" wanted[key]
                seen[key] = 1
                next
            }
        }
        print line
    }
    END {
        for (i = 1; i <= count; i++) {
            key = order[i]
            if (!(key in seen)) print key "=" wanted[key]
        }
    }
    ' "$file" > "$tmp_file"

    install -m 640 -o root -g root "$tmp_file" "$file"
    rm -f "$tmp_file"
}

quote_env_value() {
    local value="${1:-}"
    printf '"%s"' "$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g')"
}

public_ip() {
    detect_public_ip 2>/dev/null || true
}

run_check() {
    local root_dir
    root_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ -x "$SCRIPT_DIR/setup_domains.sh" ] || [ -f "$SCRIPT_DIR/setup_domains.sh" ]; then
        echo
        echo "Chequeo de dominios:"
        /bin/bash "$SCRIPT_DIR/setup_domains.sh" --check || true
    else
        echo "Aviso: no se encontro monitor/setup_domains.sh para ejecutar --check."
        echo "Ejecuta manualmente si existe en otra ruta: bash monitor/setup_domains.sh --check"
    fi
    echo "Siguiente validacion recomendada: sudo adema-node doctor"
    (cd "$root_dir" >/dev/null 2>&1 && true) || true
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --infra-domain)
            shift
            if [ -z "${1:-}" ]; then
                echo "Error: falta valor luego de --infra-domain" >&2
                exit 1
            fi
            NEW_INFRA_DOMAIN="${1:-}"
            ;;
        --infra-domain=*)
            NEW_INFRA_DOMAIN="${1#*=}"
            ;;
        --deploy-domain)
            shift
            if [ -z "${1:-}" ]; then
                echo "Error: falta valor luego de --deploy-domain" >&2
                exit 1
            fi
            NEW_DEPLOY_DOMAIN="${1:-}"
            ;;
        --deploy-domain=*)
            NEW_DEPLOY_DOMAIN="${1#*=}"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --yes|-y)
            YES=1
            ;;
        --check-only)
            CHECK_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$NEW_BASE_DOMAIN" ]; then
                NEW_BASE_DOMAIN="$1"
            else
                echo "Argumento no reconocido: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
    shift
done

if [ ! -f "$NODE_ENV_FILE" ]; then
    echo "Error: no existe $NODE_ENV_FILE. Ejecuta bootstrap_node.sh primero." >&2
    exit 1
fi

load_monitor_env

OLD_BASE_DOMAIN="${ADEMA_BASE_DOMAIN:-${BASE_DOMAIN:-}}"
OLD_INFRA_DOMAIN="${ADEMA_INFRA_DOMAIN:-}"
OLD_DEPLOY_DOMAIN="${ADEMA_DEPLOY_DOMAIN:-}"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "Dominios actuales del nodo:"
    echo "ADEMA_BASE_DOMAIN=${OLD_BASE_DOMAIN:-sin_configurar}"
    echo "ADEMA_INFRA_DOMAIN=${OLD_INFRA_DOMAIN:-sin_configurar}"
    echo "ADEMA_DEPLOY_DOMAIN=${OLD_DEPLOY_DOMAIN:-sin_configurar}"
    run_check
    exit 0
fi

if [ -z "$NEW_BASE_DOMAIN" ]; then
    echo "Error: falta DOMINIO_BASE." >&2
    usage
    exit 1
fi

NEW_BASE_DOMAIN="$(to_lower "$NEW_BASE_DOMAIN")"
NEW_INFRA_DOMAIN="$(to_lower "${NEW_INFRA_DOMAIN:-infra.${NEW_BASE_DOMAIN}}")"
NEW_DEPLOY_DOMAIN="$(to_lower "${NEW_DEPLOY_DOMAIN:-deploy.${NEW_BASE_DOMAIN}}")"

validate_domain "$NEW_BASE_DOMAIN"
validate_domain "$NEW_INFRA_DOMAIN"
validate_domain "$NEW_DEPLOY_DOMAIN"

echo "Cambio de dominio ADEMA Node Lite"
echo "Nodo: ${ADEMA_NODE_ID:-sin_id} (${ADEMA_NODE_UUID:-sin_uuid})"
echo
echo "Actual:"
echo "  ADEMA_BASE_DOMAIN=${OLD_BASE_DOMAIN:-sin_configurar}"
echo "  ADEMA_INFRA_DOMAIN=${OLD_INFRA_DOMAIN:-sin_configurar}"
echo "  ADEMA_DEPLOY_DOMAIN=${OLD_DEPLOY_DOMAIN:-sin_configurar}"
echo
echo "Nuevo:"
echo "  ADEMA_BASE_DOMAIN=$NEW_BASE_DOMAIN"
echo "  ADEMA_INFRA_DOMAIN=$NEW_INFRA_DOMAIN"
echo "  ADEMA_DEPLOY_DOMAIN=$NEW_DEPLOY_DOMAIN"
echo
echo "No se modifican: ADEMA_NODE_UUID, ADEMA_NODE_ID, CLUSTER_ID, PROJECT_CODE ni BACKUP_REMOTE."

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "DRY-RUN: no se escribieron archivos."
    audit_event "domain_changed" "" "dry_run" "old_base_domain=$OLD_BASE_DOMAIN new_base_domain=$NEW_BASE_DOMAIN old_infra_domain=$OLD_INFRA_DOMAIN new_infra_domain=$NEW_INFRA_DOMAIN old_deploy_domain=$OLD_DEPLOY_DOMAIN new_deploy_domain=$NEW_DEPLOY_DOMAIN"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: ejecuta con sudo/root para modificar $NODE_ENV_FILE y $DOMAINS_ENV_FILE." >&2
    exit 1
fi

if [ "$YES" -eq 0 ]; then
    echo
    read -r -p "Escribi CHANGE DOMAIN para confirmar: " confirm
    if [ "$confirm" != "CHANGE DOMAIN" ]; then
        echo "Operacion cancelada."
        audit_event "domain_changed" "" "cancelled" "old_base_domain=$OLD_BASE_DOMAIN new_base_domain=$NEW_BASE_DOMAIN"
        exit 1
    fi
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$(dirname "$NODE_ENV_FILE")" "$(dirname "$DOMAINS_ENV_FILE")"
backup_file_if_exists "$NODE_ENV_FILE" "$STAMP"
backup_file_if_exists "$DOMAINS_ENV_FILE" "$STAMP"

SEP=$'\034'
upsert_env_file "$NODE_ENV_FILE" \
    "ADEMA_BASE_DOMAIN=$(quote_env_value "$NEW_BASE_DOMAIN")${SEP}ADEMA_INFRA_DOMAIN=$(quote_env_value "$NEW_INFRA_DOMAIN")${SEP}ADEMA_DEPLOY_DOMAIN=$(quote_env_value "$NEW_DEPLOY_DOMAIN")"

upsert_env_file "$DOMAINS_ENV_FILE" \
    "ADEMA_BASE_DOMAIN=$(quote_env_value "$NEW_BASE_DOMAIN")${SEP}ADEMA_INFRA_DOMAIN=$(quote_env_value "$NEW_INFRA_DOMAIN")${SEP}ADEMA_DEPLOY_DOMAIN=$(quote_env_value "$NEW_DEPLOY_DOMAIN")${SEP}BASE_DOMAIN=$(quote_env_value "$NEW_BASE_DOMAIN")${SEP}MONITOR_DOMAIN=$(quote_env_value "$NEW_INFRA_DOMAIN")${SEP}COOLIFY_DOMAIN=$(quote_env_value "$NEW_DEPLOY_DOMAIN")${SEP}ADEMA_PANEL_PORT=5000${SEP}ADEMA_PANEL_BIND=$(quote_env_value "127.0.0.1")${SEP}ADEMA_COOLIFY_PORT=8000"

audit_event "domain_changed" "" "success" "old_base_domain=$OLD_BASE_DOMAIN new_base_domain=$NEW_BASE_DOMAIN old_infra_domain=$OLD_INFRA_DOMAIN new_infra_domain=$NEW_INFRA_DOMAIN old_deploy_domain=$OLD_DEPLOY_DOMAIN new_deploy_domain=$NEW_DEPLOY_DOMAIN"

echo
echo "Dominio actualizado correctamente."
echo "Archivos actualizados:"
echo "  $NODE_ENV_FILE"
echo "  $DOMAINS_ENV_FILE"
echo
IP_PUBLICA="$(public_ip)"
echo "Instrucciones DNS sugeridas:"
if [ -n "$IP_PUBLICA" ]; then
    echo "  A @      -> $IP_PUBLICA"
    echo "  A *      -> $IP_PUBLICA"
    echo "  o explicitos:"
    echo "  A infra  -> $IP_PUBLICA"
    echo "  A deploy -> $IP_PUBLICA"
else
    echo "  A @      -> IP_PUBLICA_DEL_NODO"
    echo "  A *      -> IP_PUBLICA_DEL_NODO"
    echo "  o explicitos:"
    echo "  A infra  -> IP_PUBLICA_DEL_NODO"
    echo "  A deploy -> IP_PUBLICA_DEL_NODO"
fi
echo
echo "Validaciones recomendadas:"
echo "  bash monitor/setup_domains.sh --check"
echo "  sudo adema-node doctor"
echo
echo "Nota: tenants existentes deben actualizar dominio/env en Coolify si ya fueron creados."