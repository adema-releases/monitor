# Changelist Release 1.2.0

Fecha: 2026-05-07
Tipo de release: Nueva funcionalidad — Configuracion de dominios y proxy reverso

## Resumen ejecutivo

La release 1.2.0 agrega soporte completo para acceder al panel Adema Core y a Coolify por dominios propios (`https://infra.tudominio.com`, `https://deploy.tudominio.com`) en lugar de `http://IP:5000`.

Incluye un script de configuracion y verificacion, un endpoint de API, una seccion visual en el dashboard y documentacion operativa completa.

---

## Detalle de cambios

### 1) Script `monitor/setup_domains.sh` (nuevo)

**Modo interactivo** (`sudo bash monitor/setup_domains.sh`):

- Solicita `ADEMA_BASE_DOMAIN`, `ADEMA_INFRA_DOMAIN`, `ADEMA_DEPLOY_DOMAIN`, `ADEMA_PANEL_PORT`, `ADEMA_PANEL_BIND` interactivamente si no estan definidas como variables de entorno.
- Detecta la IP publica del servidor via `curl -4 ifconfig.me` (fallbacks: `api.ipify.org`, `checkip.amazonaws.com`).
- Imprime instrucciones exactas para crear registros DNS tipo A en Cloudflare, con la IP detectada y recomendacion DNS only.
- Ofrece guardar la configuracion en `/etc/adema/domains.env` para uso persistente.
- Espera confirmacion del operador antes de continuar.

**Verificaciones** (`--check`):

- Resolucion DNS de `ADEMA_INFRA_DOMAIN` y `ADEMA_DEPLOY_DOMAIN` via `dig`, `host` o `nslookup` (orden de preferencia).
- Estado de UFW para puertos 80 y 443. Si estan cerrados, muestra los comandos `ufw allow` sugeridos sin ejecutarlos.
- Disponibilidad del panel en `http://ADEMA_PANEL_BIND:ADEMA_PANEL_PORT/` via `curl`. Si no responde, muestra `systemctl status` y `journalctl`.
- Deteccion de proxy activo en 80/443 via `ss -tulpn` (fallback: `netstat`). Identifica Traefik/Coolify, Caddy, Nginx u otros.

**Modo A** (puertos 80/443 libres, sin Coolify gestionando HTTPS):

- Ofrece instalar Nginx del host si no esta instalado.
- Genera `/etc/nginx/sites-available/adema-core.conf` con `proxy_pass http://127.0.0.1:5000` y headers correctos (`X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`).
- Crea symlink en `sites-enabled/`, valida configuracion y recarga Nginx.
- Idempotente: si el archivo ya existe con el mismo contenido, no lo sobreescribe.
- Sugiere el comando `certbot --nginx -d infra.tudominio.com` con confirmacion `[s/N]` (no ejecuta automaticamente).

**Modo B** (Coolify/Traefik ya maneja 80/443):

- No instala Nginx del host para evitar conflictos.
- Imprime instrucciones para publicar el panel via Coolify UI o via archivo de configuracion Traefik dinamica en `/etc/coolify/proxy/dynamic/adema-core.yml`.

**Salida JSON** (`--check --json`):

- Devuelve JSON estructurado con estado DNS, firewall, panel y proxy.
- Todos los mensajes de texto van a stderr; solo el JSON va a stdout.
- Usado internamente por el endpoint `GET /api/domain/status`.

**Seguridad**:

- No abre puertos UFW automaticamente.
- No instala ni modifica nada sin confirmacion del operador.
- No expone el puerto 5000 publicamente.
- No ejecuta certbot sin confirmacion explicita.

---

### 2) `web_manager.py` — Tres adiciones

**Constantes nuevas** (al inicio del modulo):

```python
SETUP_DOMAINS_SCRIPT = ROOT_DIR / "monitor" / "setup_domains.sh"
ADEMA_INFRA_DOMAIN   = os.getenv("ADEMA_INFRA_DOMAIN", "").strip()
ADEMA_DEPLOY_DOMAIN  = os.getenv("ADEMA_DEPLOY_DOMAIN", "").strip()
```

**Endpoint nuevo** `GET /api/domain/status`:

- Rate limit: 6 por minuto.
- Verifica que `setup_domains.sh` exista antes de ejecutar.
- Ejecuta `sudo -n /bin/bash setup_domains.sh --check --json` con timeout de 20 segundos.
- Pasa `ADEMA_INFRA_DOMAIN` y `ADEMA_DEPLOY_DOMAIN` al entorno del subproceso si estan definidas.
- Maneja errores: script no encontrado (404), timeout (504), fallo de ejecucion (500), JSON invalido (500).
- Devuelve el JSON del script directamente.

**Seccion visual nueva** "Dominios del nodo" en el dashboard:

- Insertada entre el panel de metricas (Host/RAM/Disco/Contenedores) y la gestion de tenants.
- Grid de 8 tarjetas: Infra domain, Deploy domain, IP publica, Panel local, DNS infra, DNS deploy, HTTP 80+443, Proxy.
- Boton "Verificar estado" que llama a `GET /api/domain/status` y actualiza los badges en tiempo real.
- Badges de estado con colores: verde para ok, rojo para fallo, indicando el estado exacto.
- Si el script no existe, muestra aviso claro.
- Muestra hora de la ultima verificacion.

---

### 3) `setup_web_panel.sh` — Sudoers actualizado

Agrega permiso para que el usuario `adema` ejecute `setup_domains.sh` via `sudo -n`:

```
adema ALL=(root) NOPASSWD: /bin/bash /home/adema/monitor/monitor/setup_domains.sh *
```

Esto permite que el endpoint `GET /api/domain/status` consulte UFW y procesos de red sin interaccion manual.

---

### 4) `docs/09-domain-setup.md` (nuevo)

Documentacion operativa completa que cubre:

- Por que abandonar `IP:5000` en produccion.
- Mapa de acceso (tabla de dominios vs destinos).
- Variables de entorno del script.
- Como crear registros DNS A en Cloudflare, con tabla de valores exactos.
- Por que usar DNS only (nube gris) en lugar de proxied para ACME.
- Como verificar propagacion DNS con `dig`.
- Como abrir puertos 80 y 443 en UFW.
- Como validar el panel local con `curl`.
- Modo A paso a paso: Nginx del host + certbot.
- Modo B paso a paso: Coolify UI o archivo Traefik YAML.
- Ejemplos de salida del script: todo OK, DNS sin propagar, panel sin respuesta.
- Notas de seguridad: puertos cerrados, PostgreSQL, token cifrado.

---

### 5) `README.md` — Seccion "Acceso por dominio"

Nueva seccion agregada antes de "Prerrequisitos" con:

- Tabla de dominios (infra → Adema Core, deploy → Coolify).
- Comandos de configuracion y verificacion.
- Referencia a `docs/09-domain-setup.md`.

---

## Criterios de calidad cumplidos

- No rompe instalaciones existentes: el panel sigue funcionando en `IP:5000` si no se configura el dominio.
- No instala Nginx si Coolify/Traefik ya esta en 80/443.
- No abre PostgreSQL publicamente.
- No expone puerto 5000 publicamente.
- Idempotente: el script puede correrse multiples veces sin efectos secundarios.
- Mensajes claros para operador no experto.
- Compatible con Ubuntu 24.04.
- Estilo consistente con el resto del repo: Bash simple + documentacion clara.

---

## Archivos creados

- `monitor/setup_domains.sh`
- `docs/09-domain-setup.md`
- `CHANGESET-1.2.0.md`

## Archivos modificados

- `web_manager.py`
- `setup_web_panel.sh`
- `README.md`
- `CHANGELOG.md`

---

## Comandos para probar

```bash
# Asistente interactivo (server Linux)
sudo bash monitor/setup_domains.sh

# Solo verificar estado
ADEMA_BASE_DOMAIN=tudominio.com bash monitor/setup_domains.sh --check

# Verificar en JSON
ADEMA_BASE_DOMAIN=tudominio.com bash monitor/setup_domains.sh --check --json

# Estado via API del panel
curl -H "X-ADEMA-TOKEN: TU_TOKEN" https://infra.tudominio.com/api/domain/status
```

---

## Configuracion Cloudflare de ejemplo

Para `ademasistemas.com` con IP `24.199.105.64`:

```
Tipo: A  |  Nombre: infra   |  IP: 24.199.105.64  |  Proxy: DNS only
Tipo: A  |  Nombre: deploy  |  IP: 24.199.105.64  |  Proxy: DNS only
```

---

## Ejemplo de salida cuando el DNS todavia no apunta al servidor

```
━━━  IP publica del servidor  ━━━
────────────────────────────────────────────────────
[OK]    IP detectada: 24.199.105.64

━━━  Verificacion DNS  ━━━
────────────────────────────────────────────────────
[WARN]  infra.ademasistemas.com → 76.76.21.21 (esperado: 24.199.105.64)
[INFO]  Todavia no apunta al servidor. Agrega el registro A en Cloudflare y espera la propagacion DNS.
[WARN]  deploy.ademasistemas.com → [sin resolver] (esperado: 24.199.105.64)
[INFO]  Todavia no apunta al servidor. Agrega el registro A en Cloudflare y espera la propagacion DNS.
...
━━━  Resumen  ━━━
[WARN]  DNS infra:     pendiente
[WARN]  DNS deploy:    pendiente
[OK]    UFW 80/tcp:    abierto
[OK]    UFW 443/tcp:   abierto
[OK]    Panel local:   activo
[WARN]  Algunos items necesitan atencion antes de operar por dominio.
```

## Ejemplo de salida cuando el panel local no responde

```
━━━  Panel local  ━━━
────────────────────────────────────────────────────
[WARN]  El panel en http://127.0.0.1:5000/ no esta respondiendo.

━━━  Diagnostico: panel local no responde  ━━━
────────────────────────────────────────────────────
[INFO]  Verifica el estado del servicio:
  sudo systemctl status adema-web-panel.service
  sudo journalctl -u adema-web-panel.service -n 80 --no-pager
[INFO]  Si el servicio no existe, instala el panel con:
  sudo bash setup_web_panel.sh
```

## Ejemplo de salida correcta (todo OK)

```
━━━  IP publica del servidor  ━━━
────────────────────────────────────────────────────
[OK]    IP detectada: 24.199.105.64

━━━  Verificacion DNS  ━━━
────────────────────────────────────────────────────
[OK]    infra.ademasistemas.com → 24.199.105.64 ✓
[OK]    deploy.ademasistemas.com → 24.199.105.64 ✓

━━━  Firewall UFW  ━━━
────────────────────────────────────────────────────
[OK]    UFW: 80/tcp y 443/tcp ya estan abiertos.

━━━  Panel local  ━━━
────────────────────────────────────────────────────
[OK]    http://127.0.0.1:5000/ → respondiendo ✓

━━━  Proxy en puertos 80/443  ━━━
────────────────────────────────────────────────────
[OK]    Nginx detectado en 80/443 → el script puede gestionar la config

━━━  Resumen  ━━━
────────────────────────────────────────────────────
[OK]    DNS infra:     OK
[OK]    DNS deploy:    OK
[OK]    UFW 80/tcp:    abierto
[OK]    UFW 443/tcp:   abierto
[OK]    Panel local:   activo
[OK]    Todo en orden. El nodo esta listo para operar por dominio.
```

## Ejemplo de salida JSON correcta

```json
{
  "ok": true,
  "infra_domain": "infra.ademasistemas.com",
  "deploy_domain": "deploy.ademasistemas.com",
  "server_ip": "24.199.105.64",
  "dns": {
    "infra_resolved": "24.199.105.64",
    "deploy_resolved": "24.199.105.64",
    "infra_points_to_server": true,
    "deploy_points_to_server": true
  },
  "firewall": {
    "ufw_http": "open",
    "ufw_https": "open",
    "http_open": true,
    "https_open": true,
    "panel_port_public_required": false
  },
  "panel": {
    "local_url": "http://127.0.0.1:5000/",
    "responding": true
  },
  "proxy": {
    "detected": "nginx",
    "mode": "A"
  }
}
```
