# Configuracion de Dominios por Nodo

Este documento explica como pasar de acceder al panel por `http://IP:5000` a acceder por `https://infra.tudominio.com`, y como dejar a Coolify disponible en `https://deploy.tudominio.com`.

## Por que dejar de usar IP:puerto

Acceder por `http://IP:5000` tiene varios problemas en un entorno productivo:

- La URL cambia si cambia el VPS.
- No es HTTPS, por lo que el token viaja sin cifrar.
- Es difícil de recordar, compartir y documentar.
- Herramientas de monitoreo, alertas y automatizaciones dependen de una URL estable.

Con un dominio propio mas proxy reverso:

- La URL es estable y legible.
- SSL/TLS se gestiona automaticamente con certbot o Coolify.
- El panel queda detrás del proxy: el puerto 5000 **no necesita** estar abierto al mundo.

---

## Mapa de acceso objetivo

| Dominio                         | Destino                          |
|---------------------------------|----------------------------------|
| `https://infra.tudominio.com`   | Adema Core (panel web)           |
| `https://deploy.tudominio.com`  | Coolify                          |

---

## 1. Variables necesarias

El script `monitor/setup_domains.sh` lee las siguientes variables de entorno.
Puedes definirlas en `/etc/adema/domains.env` o exportarlas antes de correr el script.

```bash
ADEMA_BASE_DOMAIN=ademasistemas.com
ADEMA_INFRA_DOMAIN=infra.ademasistemas.com      # default: infra.$ADEMA_BASE_DOMAIN
ADEMA_DEPLOY_DOMAIN=deploy.ademasistemas.com    # default: deploy.$ADEMA_BASE_DOMAIN
ADEMA_PANEL_PORT=5000                           # default: 5000
ADEMA_PANEL_BIND=127.0.0.1                      # default: 127.0.0.1
```

Para guardar la configuracion permanentemente:

```bash
sudo bash monitor/setup_domains.sh   # el asistente ofrece guardar en /etc/adema/domains.env
```

---

## 2. Crear registros DNS en Cloudflare

Entra al panel de Cloudflare → selecciona tu dominio → **DNS → Registros**.

Para obtener la IP pública del servidor:

```bash
curl -4 ifconfig.me
```

### Opción recomendada: registro wildcard (para dominios dedicados al nodo)

Si el dominio se usa exclusivamente para este nodo (por ejemplo `ademawebsites.com.ar`), el enfoque más práctico es un **registro wildcard** que cubre todos los subdominios de forma automática:

| Campo     | Valor                                         |
|-----------|-----------------------------------------------|
| Tipo      | `A`                                           |
| Nombre    | `*` (asterisco)                               |
| Contenido | IP pública del servidor (ej: `24.199.105.64`) |
| TTL       | Auto                                          |
| Proxy     | **Nube gris (DNS only)**                      |

**Registro raíz (opcional pero recomendado):**

| Campo     | Valor                                         |
|-----------|-----------------------------------------------|
| Tipo      | `A`                                           |
| Nombre    | `@` (o el dominio raíz)                       |
| Contenido | IP pública del servidor (ej: `24.199.105.64`) |
| TTL       | Auto                                          |
| Proxy     | **Nube gris (DNS only)**                      |

Con estos dos registros, `infra.tudominio.com`, `deploy.tudominio.com` y cualquier subdominio que configures en Coolify quedan resueltos automáticamente sin agregar otro registro en Cloudflare.

> **El wildcard solo resuelve DNS.** Cada aplicación en Coolify sigue necesitando tener su dominio configurado en la UI de Coolify (o en el archivo Traefik) para que el proxy la enrute correctamente.

### Alternativa: registros A explícitos (para dominios compartidos)

Si el dominio ya tiene otros servicios en subdominios que apuntan a proveedores distintos, usá registros A explícitos por subdominio. Ambos enfoques pueden coexistir: el wildcard cubre los subdominios que no tengan un registro propio, y los registros explícitos tienen prioridad sobre el wildcard.

| Campo     | Valor                                         |
|-----------|-----------------------------------------------|
| Tipo      | `A`                                           |
| Nombre    | `infra`                                       |
| Contenido | IP pública del servidor (ej: `24.199.105.64`) |
| TTL       | Auto                                          |
| Proxy     | **Nube gris (DNS only)**                      |

| Campo     | Valor                                         |
|-----------|-----------------------------------------------|
| Tipo      | `A`                                           |
| Nombre    | `deploy`                                      |
| Contenido | IP pública del servidor (ej: `24.199.105.64`) |
| TTL       | Auto                                          |
| Proxy     | **Nube gris (DNS only)**                      |

### ¿Por qué "DNS only" y no proxied?

Coolify usa Traefik con certificados Let's Encrypt (ACME). La validación ACME requiere que el servidor pueda responder directamente en el puerto 80. Si el proxy de Cloudflare está activo (nube naranja), Cloudflare intercepta el tráfico y la validación puede fallar.

Una vez que el SSL esté activo y estable, podés activar el proxy de Cloudflare si lo deseás. Pero para el flujo inicial, usá **DNS only**.

---

## 3. Verificar propagacion DNS

Cuando hayas creado los registros, verifica que ya apuntan al servidor. La propagacion puede tomar entre 1 y 15 minutos con TTL bajo.

```bash
dig +short infra.tudominio.com
dig +short deploy.tudominio.com
```

Ambos deben devolver la IP pública del servidor. Si devuelven otra IP o nada, espera y vuelve a intentar.

Con el script:

```bash
bash monitor/setup_domains.sh --check
```

---

## 4. Abrir puertos 80 y 443 en UFW

El proxy reverso necesita que los puertos HTTP y HTTPS esten abiertos. El puerto 5000 **no debe** abrirse publicamente.

```bash
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw status
```

Verifica que SSH siga abierto:

```bash
sudo ufw allow OpenSSH
```

Si UFW no esta habilitado y quieres activarlo:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable
sudo ufw status
```

---

## 5. Verificar panel local

Antes de configurar el proxy, confirma que el panel responde en localhost:

```bash
curl -I http://127.0.0.1:5000/
```

Respuesta esperada: `HTTP/1.1 200 OK` o `HTTP/1.1 401 Unauthorized` (ambas son correctas: el panel esta vivo).

Si no responde:

```bash
sudo systemctl status adema-web-panel.service
sudo journalctl -u adema-web-panel.service -n 80 --no-pager
```

Si el servicio no existe, ejecuta el instalador:

```bash
sudo bash setup_web_panel.sh
```

---

## 6. Configuracion del proxy reverso

Hay dos modos segun lo que ya este corriendo en el servidor.

### Detectar modo automaticamente

```bash
sudo ss -tulpn | grep -E ':80|:443'
```

Si aparece `traefik` o `coolify` → **Modo B**.  
Si el resultado esta vacio → **Modo A**.

---

### Modo A: Nginx del host (puertos 80/443 libres)

Usa este modo si Coolify NO esta usando los puertos 80/443, o si corres Adema Core en un servidor sin Coolify.

**Instalar Nginx:**

```bash
sudo apt install -y nginx
```

**Generar la config con el asistente:**

```bash
sudo bash monitor/setup_domains.sh
```

El script genera `/etc/nginx/sites-available/adema-core.conf` con este contenido:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name infra.tudominio.com;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_read_timeout 90;
        proxy_buffering off;
    }
}
```

**Verificar y recargar:**

```bash
sudo nginx -t
sudo nginx -s reload
```

**Instalar SSL con certbot:**

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d infra.tudominio.com
```

certbot modifica la config de Nginx para redirigir HTTP → HTTPS automaticamente.

**Renovacion automatica** (certbot lo configura solo, pero puedes verificar):

```bash
sudo certbot renew --dry-run
```

---

### Modo B: Coolify como proxy (Traefik en 80/443)

Usa este modo cuando Coolify ya esta corriendo y gestiona HTTPS con Traefik.

**No instales Nginx del host**: tendrian conflicto en los puertos 80/443.

**Opcion 1 — Configuracion manual en Coolify UI**

1. Entra a Coolify (`http://IP:3000` o tu dominio de deploy).
2. Crea un nuevo servicio de tipo **Generic** o **HTTP Proxy**.
3. Asigna:
   - **Domain**: `https://infra.tudominio.com`
   - **Proxy to**: `http://127.0.0.1:5000`
4. Coolify genera automaticamente el certificado SSL via Let's Encrypt.

**Opcion 2 — Configuracion Traefik manual**

Si prefieres gestionarlo via archivo, crea:

```
/etc/coolify/proxy/dynamic/adema-core.yml
```

Con este contenido (ajusta los valores):

```yaml
http:
  routers:
    adema-core:
      rule: "Host(`infra.tudominio.com`)"
      service: adema-core-svc
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt

  services:
    adema-core-svc:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:5000"
```

Reinicia el proxy de Coolify o espera que Traefik recargue la config dinamica.

Verifica en los logs de Traefik:

```bash
docker logs coolify-proxy --tail 50
```

---

## 7. Validacion final

Cuando este todo configurado:

```bash
# Verificar estado completo
bash monitor/setup_domains.sh --check

# Verificar HTTPS manualmente
curl -I https://infra.tudominio.com/

# Verificar desde el panel (API)
curl -H "X-ADEMA-TOKEN: TU_TOKEN" https://infra.tudominio.com/api/domain/status
```

Respuesta esperada del endpoint:

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

---

## 8. Ejemplos de salida del script

### DNS todavia sin propagar

```
━━━  Verificacion DNS  ━━━
────────────────────────────────────────────────────
[WARN]  infra.ademasistemas.com → 76.76.21.21 (esperado: 24.199.105.64)
[INFO]  Todavia no apunta al servidor. Agrega el registro A en Cloudflare y espera la propagacion DNS.
[WARN]  deploy.ademasistemas.com → 76.76.21.21 (esperado: 24.199.105.64)
```

### Panel local sin respuesta

```
━━━  Panel local  ━━━
────────────────────────────────────────────────────
[WARN]  El panel en http://127.0.0.1:5000/ no esta respondiendo.
[INFO]  Verifica el estado del servicio:
  sudo systemctl status adema-web-panel.service
  sudo journalctl -u adema-web-panel.service -n 80 --no-pager
```

### Todo en orden

```
━━━  Resumen  ━━━
────────────────────────────────────────────────────
[OK]    DNS infra:     OK
[OK]    DNS deploy:    OK
[OK]    UFW 80/tcp:    abierto
[OK]    UFW 443/tcp:   abierto
[OK]    Panel local:   activo
[OK]    Todo en orden. El nodo esta listo para operar por dominio.
```

---

## 9. Notas de seguridad

- El puerto `5000` **no debe** estar abierto en UFW publicamente. El proxy reverso se encarga de enrutar el trafico.
- PostgreSQL (`5432`) tampoco debe estar abierto al mundo. El script de instalacion del panel lo configura correctamente.
- El `ADEMA_WEB_TOKEN` viaja siempre en HTTPS una vez que certbot esta activo.
- Si usas Cloudflare con proxy activo (nube naranja), el token no llega directamente al servidor; Cloudflare actua como intermediario. Esto puede ser util como capa extra, pero requiere validar que los headers `X-Forwarded-For` lleguen correctamente.

---

## 10. Acceso rápido de referencia

```
https://deploy.tudominio.com  → Coolify
https://infra.tudominio.com   → Adema Core

Script de configuracion: bash monitor/setup_domains.sh
Script de verificacion:  bash monitor/setup_domains.sh --check
Estado via API:          GET /api/domain/status
```
