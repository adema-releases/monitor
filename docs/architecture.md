# Arquitectura ADEMA con Coolify/Traefik

El repositorio `monitor` tiene dos responsabilidades separadas:

1. Bootstrap y diagnostico del nodo: preparar servidor, verificar DNS, firewall, Docker, Coolify, puertos y estructura base.
2. Monitor como app: correr dentro de Coolify, publicado en `monitor.ademasistemas.com`, sin manejar directamente `80/443`.

## Flujo publico

```text
Cloudflare DNS
    |
    | A @ -> IP nodo
    | A * -> IP nodo
    v
Coolify / Traefik
    |-- ademasistemas.com          -> web institucional
    |-- www.ademasistemas.com      -> alias web institucional
    |-- deploy.ademasistemas.com   -> panel Coolify
    |-- monitor.ademasistemas.com  -> Adema Monitor
    |-- clientes.ademasistemas.com -> CRM interno
    |-- api.ademasistemas.com      -> API central
    |-- creditos.ademasistemas.com -> Gestion de Creditos
    |-- stock.ademasistemas.com    -> producto de stock
    `-- academy.ademasistemas.com  -> academia
```

Cloudflare solo resuelve DNS. Coolify/Traefik es el unico responsable del trafico publico HTTP/HTTPS en `80/443`.

## Por que no usamos Nginx del host

Nginx del host compite por los mismos puertos que Traefik (`80/443`). Si ambos intentan escuchar esos puertos, uno de los dos falla o queda una ruta ambigua para certificados y websockets.

El modo recomendado es `coolify-traefik`. El modo `host-nginx` queda solo como legacy/deprecated y requiere confirmacion explicita.

## Por que no usamos certbot del host

Coolify/Traefik gestiona certificados desde su propio proxy. Ejecutar `certbot --nginx` en el host mezcla dos capas de proxy y puede romper el ownership de certificados, redirecciones y renovaciones.

En esta arquitectura, si falta certbot en el host no importa.

## Publicacion de apps

Cada app se crea como recurso separado en Coolify:

- dominio propio;
- puerto interno propio;
- variables propias;
- base de datos Postgres propia o servicio Postgres propio;
- credenciales separadas;
- backups futuros por app/DB.

El monitor escucha internamente en `0.0.0.0:5000` dentro del contenedor. Coolify detecta ese puerto y Traefik publica `https://monitor.ademasistemas.com`.

No se debe publicar `5000` como puerto host.

## Dominios

| Dominio | Recurso |
|---|---|
| `ademasistemas.com` | Web institucional |
| `www.ademasistemas.com` | Alias web institucional |
| `deploy.ademasistemas.com` | Panel Coolify |
| `monitor.ademasistemas.com` | Adema Monitor |
| `clientes.ademasistemas.com` | CRM interno |
| `api.ademasistemas.com` | API central |
| `creditos.ademasistemas.com` | Gestion de Creditos |
| `stock.ademasistemas.com` | Producto stock |
| `academy.ademasistemas.com` | Academia |
| `infra.ademasistemas.com` | Legacy/deprecated |

## Seguridad de red

Permitido publicamente:

- `22/tcp` para SSH;
- `80/tcp` para Traefik HTTP/ACME;
- `443/tcp` para Traefik HTTPS.

No exponer publicamente:

- `5000/tcp` monitor interno;
- `5432/tcp` Postgres;
- `6379/tcp` Redis;
- Docker socket.
