# Monitor Django Multi-Proyecto

Este repositorio contiene scripts Bash para operar y monitorear multiples proyectos Django desplegados en contenedores.

## Estado Open Source

Proyecto listo para uso publico con:

- Licencia MIT: `LICENSE`
- Politica de seguridad: `SECURITY.md`
- Guia de contribucion: `CONTRIBUTING.md`
- Codigo de conducta: `CODE_OF_CONDUCT.md`
- Historial de cambios: `CHANGELOG.md`

## Documentacion Operativa

Guia por tarea en la carpeta `docs/`:

- `docs/index.html`: landing y runbook para GitHub Pages (documentacion publica del proyecto).

- `docs/01-new-node.md`: provision y bootstrap de nodo nuevo.
- `docs/02-create-tenant.md`: alta de tenant.
- `docs/03-delete-tenant.md`: eliminacion segura de tenant.
- `docs/04-backup-restore.md`: backup y restauracion.
- `docs/05-health-and-alerts.md`: snapshot, test DB, monitor y centinela.
- `docs/06-web-panel.md`: instalacion y operacion del panel web seguro.

## Higiene Open Source

- Nunca subas `monitor/.monitor.secrets` ni `monitor/.monitor.env`.
- Usa `monitor/.monitor.env.example` como plantilla publica.
- Reemplaza IPs reales en docs por placeholders como `[TU_IP_AQUI]`.
- Mantener `DB_NAME_PREFIX` y `DB_USER_PREFIX` evita acoplar naming real de infraestructura.

## Quickstart (5 minutos)

```bash
git clone https://github.com/adema-releases/monitor
cd monitor
sudo bash run_monitor.sh
sudo bash setup_web_panel.sh
```

Despues valida:

```bash
bash monitor/status_snapshot.sh
sudo systemctl status adema-web-panel.service
```

## Estructura

- `run_monitor.sh`: launcher interactivo principal.
- `setup_cron.sh`: instalador interactivo de cron para produccion.
- `monitor/lib/common.sh`: libreria comun (carga configuracion, secretos y funciones auxiliares).
- `monitor/.monitor.env.example`: plantilla de configuracion.

### Scripts estandar (nombres recomendados)

- `monitor/create_tenant.sh`: crea DB, usuario y volumenes por tenant.
- `monitor/delete_tenant.sh`: elimina DB, usuario y volumenes por tenant.
- `monitor/backup_project.sh`: backup logico + sync remoto + pruning local.
- `monitor/restore_tenant.sh`: restaura DB y volumenes para un tenant.
- `monitor/test_tenant_db.sh`: prueba conectividad y permisos SQL.
- `monitor/monitor_report.sh`: reporte operativo por email (Brevo).
- `monitor/sentinel_ram.sh`: alerta de RAM por email (Brevo).

## Prerrequisitos

En la VM Linux donde corren los contenedores:

- Bash
- Docker
- PostgreSQL cliente (`psql`, `pg_dump`)
- `rclone` configurado con el remote usado en `BACKUP_REMOTE`
- `curl`
- `openssl`
- permisos para usar `sudo -u postgres`

## Configuracion inicial

### Opcion recomendada (interactiva)

1. Ejecutar launcher:

```bash
sudo bash run_monitor.sh
```

2. Elegir opcion `1) Configurar variables y secretos`.
3. Completar valores.
4. Se generan/actualizan:
- `monitor/.monitor.env`
- `monitor/.monitor.secrets`

### Opcion manual

1. Copiar plantilla:

```bash
cp monitor/.monitor.env.example monitor/.monitor.env
```

2. Editar `monitor/.monitor.env`.
3. Crear `monitor/.monitor.secrets` con:

```bash
BREVO_API_KEY=tu_api_key
```

4. Proteger secretos:

```bash
chmod 600 monitor/.monitor.secrets
```

## Variables importantes

En `monitor/.monitor.env`:

- `PROJECT_CODE`: codigo del proyecto (ejemplo `miapp`).
- `CLUSTER_ID`: identificador del cluster/nodo.
- `DB_NAME_PREFIX`: prefijo de DB (ejemplo `miapp_db`).
- `DB_USER_PREFIX`: prefijo de usuario SQL (ejemplo `user_miapp`).
- `VOLUME_PREFIX`: prefijo de volumenes Docker.
- `VOLUME_FOLDERS`: carpetas por tenant (default `license logs media`).
- `BACKUP_DIR`: directorio local de backups.
- `BACKUP_REMOTE`: remote y path base de rclone (ejemplo `r2:miapp-backups`).
- `BREVO_RECIPIENT`, `BREVO_SENDER`, `BREVO_SENDER_NAME`: datos email.
- `DB_HOST`: host PostgreSQL para tests.
- `RAM_THRESHOLD_MB`: umbral de alerta RAM.

En `monitor/.monitor.secrets`:

- `BREVO_API_KEY`

## Comandos directos

Todos se ejecutan desde la raiz del repo.

### Crear tenant

```bash
sudo bash monitor/create_tenant.sh cli001
```

Con password fija (opcional):

```bash
sudo bash monitor/create_tenant.sh cli001 "PasswordSegura123"
```

### Borrar tenant

```bash
sudo bash monitor/delete_tenant.sh cli001
```

### Backup del proyecto

```bash
sudo bash monitor/backup_project.sh
```

### Restaurar tenant

```bash
sudo bash monitor/restore_tenant.sh cli001 2026-03-27 miapp_db_cli001_2026-03-27_03-30.sql.gz
```

Si no pasas argumentos, los pide en forma interactiva.

### Test de DB tenant

```bash
bash monitor/test_tenant_db.sh cli001
```

Si no pasas password, la pide en oculto.

### Reporte operativo por email

```bash
sudo bash monitor/monitor_report.sh
```

### Alerta de RAM por email

```bash
sudo bash monitor/sentinel_ram.sh
```

## Uso desde launcher interactivo

```bash
sudo bash run_monitor.sh
```

Menu:

1. Configurar variables y secretos
2. Crear tenant
3. Borrar tenant
4. Ejecutar backup
5. Restaurar tenant
6. Testear DB
7. Enviar reporte de monitor
8. Ejecutar centinela de RAM
9. Instalar/actualizar cron de produccion
0. Salir

## Cron de produccion

### Opcion recomendada (automatica)

Ejecutar:

```bash
sudo bash setup_cron.sh
```

El asistente pregunta:

- hora/minuto del backup diario
- frecuencia del reporte monitor
- frecuencia del sentinel

Luego instala o actualiza 3 jobs en el crontab del usuario actual.

### Opcion manual (ejemplo exacto)

Abrir crontab:

```bash
crontab -e
```

Agregar (ajustando ruta del repo):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 2 * * * cd /opt/monitor && /bin/bash /opt/monitor/monitor/backup_project.sh >> /opt/monitor/logs/backup_project.log 2>&1
0 */6 * * * cd /opt/monitor && /bin/bash /opt/monitor/monitor/monitor_report.sh >> /opt/monitor/logs/monitor_report.log 2>&1
*/10 * * * * cd /opt/monitor && /bin/bash /opt/monitor/monitor/sentinel_ram.sh >> /opt/monitor/logs/sentinel_ram.log 2>&1
```

## Validacion de cron

### 1) Confirmar jobs instalados

```bash
crontab -l
```

### 2) Confirmar carpeta de logs

```bash
ls -lah logs
```

### 3) Forzar prueba manual de cada job

```bash
sudo bash monitor/backup_project.sh
sudo bash monitor/monitor_report.sh
sudo bash monitor/sentinel_ram.sh
```

### 4) Revisar salidas de logs

```bash
tail -n 100 logs/backup_project.log
tail -n 100 logs/monitor_report.log
tail -n 100 logs/sentinel_ram.log
```

### 5) Validar envio de email

Comprobar llegada de emails de reporte/alerta al destinatario configurado en `BREVO_RECIPIENT`.

## Validacion completa (checklist)

### 1) Validar configuracion

```bash
cat monitor/.monitor.env
cat monitor/.monitor.secrets
```

Revisar que no haya valores vacios en `DB_NAME_PREFIX`, `DB_USER_PREFIX`, `BACKUP_REMOTE`, `BREVO_RECIPIENT`, `BREVO_SENDER`, `BREVO_API_KEY`.

### 2) Validar alta y conectividad

1. Crear tenant:

```bash
sudo bash monitor/create_tenant.sh cli001
```

2. Guardar password mostrada.
3. Probar DB:

```bash
bash monitor/test_tenant_db.sh cli001
```

### 3) Validar backup

```bash
sudo bash monitor/backup_project.sh
```

Comprobar en `BACKUP_DIR` que exista:

- historial `.sql.gz`
- `*_latest.sql.gz`

### 4) Validar monitoreo y alertas

```bash
sudo bash monitor/monitor_report.sh
sudo bash monitor/sentinel_ram.sh
```

Verificar recepcion de emails en `BREVO_RECIPIENT`.

### 5) Validar restore

1. Ejecutar restore de un backup real:

```bash
sudo bash monitor/restore_tenant.sh cli001 2026-03-27 archivo.sql.gz
```

2. Volver a correr test DB:

```bash
bash monitor/test_tenant_db.sh cli001
```

### 6) Validar borrado (solo entorno de prueba)

```bash
sudo bash monitor/delete_tenant.sh cli001
```

Comprobar que no existan DB/usuario/volumenes del tenant.

## Troubleshooting rapido

- Error `permission denied`: ejecutar con `sudo`.
- Error `psql: could not connect`: revisar `DB_HOST`, servicio Postgres y firewall local.
- Error `rclone`: validar remote con `rclone listremotes` y credenciales.
- No llega email: revisar `BREVO_API_KEY`, remitente, destinatario y limites de proveedor.
- Credenciales incorrectas en test: usar la password generada al crear tenant o la configurada manualmente.

## Recomendacion operativa

- Usar siempre los nombres estandar nuevos.
- Mantener scripts legacy solo temporalmente.
- No versionar `monitor/.monitor.secrets`.
