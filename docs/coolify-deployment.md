# Despliegue en Coolify

## 1. Crear proyecto

En Coolify crear un proyecto llamado `ADEMA Core`.

## 2. Publicar el monitor

Crear un recurso para el monitor:

- tipo: Docker/Compose desde repositorio;
- repo: `adema-releases/monitor`;
- compose: `compose.yml`;
- dominio: `https://monitor.ademasistemas.com`;
- puerto interno detectado: `5000`;
- sin publicar puerto host.

Variables minimas:

```bash
ADEMA_WEB_TOKEN=generar_token_largo
BASE_DOMAIN=ademasistemas.com
MONITOR_DOMAIN=monitor.ademasistemas.com
COOLIFY_DOMAIN=deploy.ademasistemas.com
PUBLIC_PROXY_MODE=coolify-traefik
```

Healthcheck esperado:

```text
GET /healthz -> 200
```

## 3. Publicar web institucional

Crear recurso separado para la web institucional:

- dominio principal: `https://ademasistemas.com`;
- alias: `https://www.ademasistemas.com`;
- base de datos: `db_adema_web` si la app la requiere.

## 4. Crear apps futuras

Crear un recurso por app:

| Recurso | Dominio | DB sugerida |
|---|---|---|
| `adema-clientes` | `clientes.ademasistemas.com` | `db_adema_clientes` |
| `adema-api` | `api.ademasistemas.com` | `db_adema_api` |
| `gestion-creditos` | `creditos.ademasistemas.com` | `db_gestion_creditos` |
| `adema-stock` | `stock.ademasistemas.com` | `db_adema_stock` |
| `academia-adema` | `academy.ademasistemas.com` | `db_academia_adema` |

Cada recurso debe tener credenciales propias. No compartir usuarios, passwords ni archivos `.env` entre apps.

## 5. Base de datos por app

Preferencia operativa:

- un servicio Postgres separado por app si se quiere aislamiento fuerte;
- o una instancia Postgres administrada con una DB y usuario separados por app.

No abrir Postgres publicamente. El acceso debe ocurrir por red interna de Coolify/Docker o por canal privado controlado.

## 6. Verificacion post deploy

```bash
bash scripts/diagnose_node.sh
curl -I https://monitor.ademasistemas.com/healthz
sudo ss -tulpn | grep -E ':80|:443|:5000|:5432|:6379'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

Resultado esperado:

- Traefik/Coolify usa `80/443`;
- Nginx host no esta activo;
- `5000` no esta publicado en el host;
- `5432` y `6379` no estan publicados publicamente;
- `monitor.ademasistemas.com` responde por HTTPS.