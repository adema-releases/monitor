# Configuracion de Dominios por Nodo

Esta guia reemplaza el flujo antiguo de `infra.*` con Nginx del host. La arquitectura actual es:

```text
Cloudflare DNS -> Coolify/Traefik -> Apps
```

Coolify/Traefik es el unico responsable del trafico publico `80/443`.

## Dominios objetivo

| Dominio | Destino |
|---|---|
| `ademasistemas.com` | Web institucional |
| `www.ademasistemas.com` | Alias web institucional |
| `deploy.ademasistemas.com` | Panel Coolify |
| `monitor.ademasistemas.com` | Adema Monitor |
| `clientes.ademasistemas.com` | CRM interno |
| `api.ademasistemas.com` | API central |
| `creditos.ademasistemas.com` | Gestion de Creditos |
| `stock.ademasistemas.com` | Stock |
| `academy.ademasistemas.com` | Academia |
| `infra.ademasistemas.com` | Legacy/deprecated |

## 1. Configurar Cloudflare

Crear o confirmar:

```text
A      @      147.182.204.206
A      *      147.182.204.206
CNAME  www    ademasistemas.com
```

No tocar MX/TXT/DKIM/SPF/DMARC/Brevo/Zoho existentes.

Usar DNS only durante la emision inicial de SSL. Luego se puede evaluar proxied si no rompe validaciones ni websockets.

## 2. Configurar dominios del nodo

Ejemplo en `/etc/adema/domains.env`:

```bash
BASE_DOMAIN=ademasistemas.com
ROOT_DOMAIN=ademasistemas.com
WWW_DOMAIN=www.ademasistemas.com
COOLIFY_DOMAIN=deploy.ademasistemas.com
MONITOR_DOMAIN=monitor.ademasistemas.com
CLIENTES_DOMAIN=clientes.ademasistemas.com
API_DOMAIN=api.ademasistemas.com
CREDITOS_DOMAIN=creditos.ademasistemas.com
STOCK_DOMAIN=stock.ademasistemas.com
ACADEMY_DOMAIN=academy.ademasistemas.com
MONITOR_INTERNAL_PORT=5000
PUBLIC_PROXY_MODE=coolify-traefik
```

Tambien se puede generar con:

```bash
sudo bash monitor/setup_domains.sh
```

## 3. Firewall

Permitir solamente lo necesario para el borde publico:

```bash
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP for Coolify Traefik'
sudo ufw allow 443/tcp comment 'HTTPS for Coolify Traefik'
sudo ufw status
```

No abrir publicamente:

- `5000/tcp`;
- `5432/tcp`;
- `6379/tcp`.

## 4. Coolify

En Coolify crear recursos separados:

- `adema-monitor` con `https://monitor.ademasistemas.com` y puerto interno `5000`;
- `adema-web` con `https://ademasistemas.com` y alias `https://www.ademasistemas.com`;
- futuras apps con dominios propios.

El monitor no debe publicarse como puerto host. Coolify/Traefik debe enrutarlo.

## 5. Nginx host

Nginx del host queda legacy/deprecated. No debe estar activo si Coolify/Traefik maneja `80/443`.

Para desactivarlo con backup:

```bash
sudo bash scripts/disable_host_nginx.sh
```

Para modo legacy explicito:

```bash
sudo bash monitor/setup_domains.sh --proxy-mode host-nginx
```

Ese modo requiere confirmacion manual y no es el flujo recomendado.

## 6. Diagnostico

```bash
bash monitor/setup_domains.sh --check
bash scripts/diagnose_node.sh
```

El estado final no debe decir "todo en orden" si:

- UFW tiene `80/443` cerrados;
- Nginx host esta activo compitiendo con Traefik;
- Docker o Coolify no estan activos;
- `5000`, `5432` o `6379` estan expuestos publicamente;
- `monitor.ademasistemas.com` o `deploy.ademasistemas.com` no resuelven.