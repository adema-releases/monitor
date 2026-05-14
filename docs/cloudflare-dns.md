# Cloudflare DNS para ADEMA

Cloudflare debe resolver DNS. El trafico HTTP/HTTPS lo recibe Coolify/Traefik en el nodo.

## Registros esperados

| Tipo | Nombre | Contenido | Proxy inicial |
|---|---|---|---|
| `A` | `@` | `147.182.204.206` | DNS only |
| `A` | `*` | `147.182.204.206` | DNS only |
| `CNAME` | `www` | `ademasistemas.com` | DNS only |

El wildcard `A *` hace que nuevos subdominios resuelvan al nodo, pero no publica apps por si solo. Cada dominio debe configurarse tambien en el recurso correspondiente de Coolify.

## Registros que no se tocan

No modificar registros existentes de correo o validacion:

- MX;
- TXT;
- DKIM;
- SPF;
- DMARC;
- Brevo;
- Zoho;
- cualquier validacion externa activa.

## DNS only vs proxied

Recomendacion inicial: usar DNS only hasta que Coolify/Traefik emita y estabilice SSL.

Cloudflare proxied puede ocultar la IP real y afectar validaciones ACME, websockets o configuraciones de apps. Cuando SSL este estable, se puede evaluar activar proxied dominio por dominio.

Si el diagnostico muestra una IP de Cloudflare en lugar de `147.182.204.206`, no siempre es bloqueo, pero debe quedar como `[WARN]` durante la puesta en marcha.

## Verificacion

```bash
dig +short ademasistemas.com
dig +short monitor.ademasistemas.com
dig +short deploy.ademasistemas.com
bash scripts/diagnose_node.sh
```
