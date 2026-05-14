# Documentacion Operativa

Esta carpeta contiene guias practicas para operar el nodo de forma segura y repetible.

La idea principal del proyecto es crear una estructura que permita, mediante Coolify, alojar multiples apps Django de manera automatizada sobre VPS. Esta documentacion esta escrita para que otro desarrollador Django pueda levantar un nodo rapido, con estandares de seguridad y procesos claros.

Camino principal para una instalacion nueva: VM Ubuntu 24.04 -> Docker/PostgreSQL/rclone -> Coolify -> `adema-releases/monitor` -> panel web seguro -> backup/restore probado.

## Indice

1. [Provision y bootstrap del nodo Ubuntu 24.04 + Coolify](01-new-node.md)
2. [Crear tenant](02-create-tenant.md)
3. [Eliminar tenant](03-delete-tenant.md)
4. [Backup y restore](04-backup-restore.md)
5. [Monitoreo, test y centinela](05-health-and-alerts.md)
6. [Panel web seguro](06-web-panel.md)
7. [Checklist de salida a produccion](07-go-live-checklist.md)
8. [Federacion de nodos con master](08-master-node-federation.md)
9. [Arquitectura Coolify/Traefik](architecture.md)
10. [DNS en Cloudflare](cloudflare-dns.md)
11. [Despliegue en Coolify](coolify-deployment.md)
12. [Configuracion de dominios](09-domain-setup.md)

## Convenciones

- Ejecuta comandos desde la raiz del repo.
- Para operaciones de DB, volumenes y permisos, usa `sudo`.
- Antes de producir cambios destructivos, confirma en entorno de staging.
- Para nuevos nodos, usa un patron de nombre (`NODO_XXX`) para estandarizar inventario y operacion futura.
