# README_SEGURIDAD.md

Guia practica para operar este repo como **ADEMA Node Lite**: una VM por nodo, PostgreSQL local por nodo, Coolify local, backups por nodo y tenants aislados por base/usuario. Esta guia esta escrita para uso propio de ADEMA, no para armar una plataforma cloud generica.

## 1. Arquitectura recomendada: ADEMA Node Lite

Objetivo por nodo:

- 1 VM Ubuntu/Debian limpia.
- Docker instalado en el host.
- Coolify en el mismo nodo.
- PostgreSQL local en el mismo nodo.
- 10 a 15 tenants por nodo.
- Hasta 10 nodos operados con runbooks simples.
- Backups locales temporales + rclone remoto, idealmente con `rclone crypt`.
- Panel web opcional, protegido y nunca expuesto directo a internet.

Flujo esperado:

```bash
curl -fsSL https://raw.githubusercontent.com/adema-releases/monitor/main/bootstrap.sh | sudo bash
sudo adema-node doctor
sudo adema-node create-tenant cliente001
sudo adema-node generate-env cliente001
sudo adema-node backup
```

Instalacion alternativa mas auditable:

```bash
sudo git clone https://github.com/adema-releases/monitor.git /opt/adema-node
cd /opt/adema-node
sudo bash bootstrap_node.sh
```

Topologia recomendada:

```text
Internet
  -> Cloudflare DNS / proxy
  -> Cloudflare Access, VPN, Tailscale o allowlist IP
  -> HTTPS 443 en Coolify/Traefik
  -> apps de tenants

Panel web opcional:
infra.tudominio.com
  -> Cloudflare Access / VPN / Tailscale / allowlist IP
  -> HTTPS obligatorio
  -> proxy interno hacia 127.0.0.1:5000
  -> token interno del panel como segunda barrera

PostgreSQL:
apps Docker/Coolify -> red interna -> PostgreSQL local del nodo:5432
Internet -> bloqueado
```

Decisiones base:

- No centralizar PostgreSQL en una VM unica.
- No abrir PostgreSQL a internet.
- No usar superuser para apps.
- Crear una DB por tenant.
- Crear un usuario por tenant.
- Usar password unico por tenant.
- Usar SCRAM (`scram-sha-256`).
- Mantener backups por nodo.

### Identidad unica del nodo

Cada VM debe tener una identidad propia en:

```bash
/etc/adema/node.env
```

Este archivo se crea durante `bootstrap_node.sh` si no existe y se conserva en ejecuciones posteriores. Define identidad del nodo; `monitor/.monitor.env` queda para configuracion operativa del monitor.

Prioridad de configuracion:

- `/etc/adema/node.env`: identidad del nodo, dominios principales y `BACKUP_REMOTE` unico.
- `monitor/.monitor.env`: paths, prefijos, email, retencion, rclone config y ajustes operativos.

Contenido minimo:

```bash
ADEMA_NODE_ID=gdc-node-001
ADEMA_NODE_UUID=xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
ADEMA_NODE_NAME="GDC Node 001"
CLUSTER_ID=GDC-NODE-001
PROJECT_CODE=gdc
ADEMA_BASE_DOMAIN=gdc.tudominio.com
ADEMA_INFRA_DOMAIN=infra.gdc.tudominio.com
ADEMA_DEPLOY_DOMAIN=deploy.gdc.tudominio.com
BACKUP_REMOTE=adema-crypt:backups/gdc-node-001
NODE_CREATED_AT=2026-05-14T00:00:00Z
```

Como elegir `ADEMA_NODE_ID`:

- Bueno: `gdc-node-001`, `adema-uy-001`, `creditos-prod-01`.
- Peligroso: `demo`, `test`, `default`, `node`, `local`, `ubuntu`, `CLUSTER-LOCAL`, `CLUSTER-DEMO-01`.
- Formato permitido: letras, numeros, guion y guion bajo.
- Debe aparecer dentro de `BACKUP_REMOTE` para que los backups de dos nodos no compartan el mismo path.

Ejemplos correctos de `BACKUP_REMOTE`:

```bash
BACKUP_REMOTE=adema-crypt:gdc-node-001
BACKUP_REMOTE=adema-crypt:backups/gdc-node-001
BACKUP_REMOTE=r2-adema:nodos/gdc-node-001
```

Ejemplos peligrosos:

```bash
BACKUP_REMOTE=adema-crypt:backups
BACKUP_REMOTE=r2:demo-backups
BACKUP_REMOTE=s3:adema
```

Cada remote/path debe tener un manifiesto:

```bash
$BACKUP_REMOTE/node_manifest.json
```

Incluye `ADEMA_NODE_ID`, `ADEMA_NODE_UUID`, nombre, cluster, proyecto, hostname, IP publica detectada, `created_at` y `updated_at`. Si el manifiesto remoto existe y tiene otro `ADEMA_NODE_UUID`, el backup se bloquea salvo `--force`.

Si clonaste una VM por error:

1. Apagala o aislala de red si puede escribir backups.
2. Revisa identidad:

```bash
sudo cat /etc/adema/node.env
sudo adema-node doctor
```

3. Si es realmente un nodo nuevo, cambia `ADEMA_NODE_ID`, `CLUSTER_ID`, dominios y `BACKUP_REMOTE` a paths nuevos.
4. Regenera solo el UUID con confirmacion explicita:

```bash
cd /opt/adema-node
sudo bash bootstrap_node.sh --regenerate-node-identity
```

5. Ejecuta:

```bash
sudo adema-node doctor
sudo adema-node backup
```

No uses `--force` en backup para resolver una duda. Usalo solo si confirmaste que ese remote debe reasignarse al nodo actual.

## 2. Matriz de riesgos

| Riesgo | Impacto | Probabilidad | Mitigacion | Prioridad |
|---|---:|---:|---|---:|
| Panel web expuesto directo en `:5000` | Alto | Media | Bind `127.0.0.1`, HTTPS detras de Cloudflare Access/VPN/Tailscale/allowlist, token interno | P0 |
| Token del panel por query string | Alto | Media | Usar `Authorization: Bearer` o `X-ADEMA-TOKEN`; `ADEMA_ALLOW_QUERY_TOKEN=0` | P0 |
| Sudoers NOPASSWD demasiado amplio | Alto | Media | Permitir solo `/bin/bash script-especifico *`; scripts root-owned y no editables por usuario runtime | P0 |
| Scripts destructivos editables por usuario del panel | Alto | Media | `web_manager.py` y scripts criticos root-owned, chmod 644/755, repo en `/opt/adema-node` | P0 |
| Restore pisa una DB activa | Alto | Media | Bloquear si hay contenedores activos; exigir `--allow-active` solo con validacion manual | P0 |
| Restore de archivo incorrecto o manipulado | Alto | Baja/Media | Validar fecha, nombre `.sql.gz`, DB_USER, manifiesto SHA256, auditoria y confirmacion fuerte | P0 |
| Backups remotos sin cifrado adicional | Alto | Media | Usar bucket privado como minimo; preferir `rclone crypt`; manifiesto/hash/retencion | P1 |
| PostgreSQL escuchando publicamente | Alto | Baja/Media | UFW deny 5432, permitir solo redes internas necesarias, revisar `ss` y `ufw status` | P0 |
| Apps usando superuser | Alto | Media | Usuario por tenant sin superuser, owner de DB/schema limitado al tenant | P0 |
| Falta de auditoria | Medio | Media | JSONL local `/var/log/adema-node/audit.jsonl` sin passwords | P1 |
| Un nodo aloja demasiados tenants | Medio | Media | Mantener 10-15 tenants por nodo, monitorear disco/RAM/backup/restore | P2 |
| Alta disponibilidad prematura | Medio | Media | Priorizar backups, restore probado y reprovisionamiento rapido | P2 |

## 3. Checklist de hardening para produccion

Nodo:

```bash
sudo adema-node doctor
sudo ufw status verbose
sudo ss -ltnp | grep -E ':5432|:5000|:80|:443'
sudo systemctl status docker postgresql --no-pager
```

PostgreSQL:

```bash
sudo -u postgres psql -t -A -c "SHOW password_encryption;"
sudo -u postgres psql -t -A -c "SHOW listen_addresses;"
sudo -u postgres psql -c "\du"
```

Debe cumplirse:

- `password_encryption = scram-sha-256`.
- Puerto 5432 no abierto a internet.
- UFW activo.
- Acceso permitido solo desde redes Docker/Coolify/LAN necesarias.
- DB por tenant.
- Usuario por tenant.
- Password unico por tenant.
- Apps sin superuser.

Permisos:

```bash
sudo stat -c '%U %G %a %n' /opt/adema-node /opt/adema-node/web_manager.py
sudo stat -c '%U %G %a %n' /opt/adema-node/monitor/create_tenant.sh
sudo stat -c '%U %G %a %n' /opt/adema-node/monitor/delete_tenant.sh
sudo stat -c '%U %G %a %n' /opt/adema-node/monitor/restore_tenant.sh
sudo stat -c '%U %G %a %n' /opt/adema-node/.web_jobs
sudo stat -c '%U %G %a %n' /etc/adema/tenants
```

Debe cumplirse:

- Scripts criticos root-owned.
- `web_manager.py` root-owned.
- Usuario runtime del panel no puede editar scripts.
- `.web_jobs` escribible solo por usuario del panel.
- `/etc/adema/tenants/*.env` root-only (`600`).
- configs/secrets con permisos minimos.

Panel web:

```bash
sudo systemctl status adema-web-panel.service --no-pager
sudo ss -ltnp | grep ':5000'
sudo cat /etc/adema/web_panel.env
```

Debe cumplirse:

- `ADEMA_WEB_HOST=127.0.0.1` salvo que este en red privada controlada.
- `ADEMA_ALLOW_QUERY_TOKEN=0`.
- HTTPS obligatorio si se publica por dominio.
- No abrir `5000/tcp` publicamente.
- Acceso recomendado: `infra.tudominio.com -> Cloudflare Access / VPN / Tailscale / allowlist IP -> token interno`.

Backups:

```bash
sudo rclone listremotes --config /root/.config/rclone/rclone.conf
sudo adema-node backup
sudo tail -n 50 /var/log/adema-node/backup_project.log
```

Debe cumplirse:

- Remote accesible.
- `BACKUP_REMOTE` incluye `ADEMA_NODE_ID`.
- `$BACKUP_REMOTE/node_manifest.json` pertenece al mismo `ADEMA_NODE_UUID`.
- Manifiestos `.manifest.json` con `sha256`.
- Retencion local configurada.
- Restore probado en staging o tenant de prueba.

Auditoria:

```bash
sudo tail -n 20 /var/log/adema-node/audit.jsonl
```

Eventos esperados:

- `bootstrap`.
- `doctor`.
- `create_tenant`.
- `delete_tenant`.
- `backup`.
- `restore`.
- `rotate_token`.
- `generate_env`.
- `node_identity_created`.
- `node_identity_loaded`.
- `node_identity_regenerated`.
- `remote_manifest_created`.
- `remote_manifest_mismatch`.
- `doctor_node_identity_ok`.
- `doctor_node_identity_warn`.
- `doctor_node_identity_error`.

No debe haber passwords en auditoria.

## 4. Comandos concretos

Instalar nodo desde VM limpia:

```bash
curl -fsSL https://raw.githubusercontent.com/adema-releases/monitor/main/bootstrap.sh | sudo bash
```

Usar branch/tag especifico:

```bash
export ADEMA_NODE_REF=v1.0.0
curl -fsSL https://raw.githubusercontent.com/adema-releases/monitor/main/bootstrap.sh | sudo -E bash
```

Instalacion revisable:

```bash
sudo git clone https://github.com/adema-releases/monitor.git /opt/adema-node
cd /opt/adema-node
sudo bash bootstrap_node.sh
```

Validar nodo:

```bash
sudo adema-node doctor
```

Crear tenant y obtener variables para Coolify:

```bash
sudo adema-node create-tenant cliente001
```

Regenerar variables desde archivo root-only:

```bash
sudo adema-node generate-env cliente001
sudo adema-node generate-env cliente001 --no-password-output
```

Backup:

```bash
sudo adema-node backup
```

Backup con remote reasignado manualmente, solo ante recuperacion controlada:

```bash
sudo adema-node backup --force
```

Restore seguro:

```bash
sudo adema-node restore-tenant cliente001 2026-05-14 adema_db_cliente001_2026-05-14_02-15.sql.gz
```

Si el tenant esta activo, primero detener app en Coolify. Solo usar `--allow-active` si ya validaste que no hay escrituras.

## 5. Restore seguro

El restore debe cumplir:

- Fecha validada en formato `YYYY-MM-DD`.
- Archivo validado como `.sql.gz` sin rutas ni espacios.
- `DB_USER` esperado existente.
- Backup pre-restore automatico salvo `--no-pre-backup` explicito.
- Bloqueo si hay contenedores activos del tenant, salvo `--allow-active`.
- Confirmacion fuerte: `RESTORE CLIENT_ID`.
- Auditoria local.
- Verificacion SHA256 si existe manifiesto.
- Preferir restore primero en staging si el backup viene de produccion o el cambio es delicado.

## 6. Backups cifrados

Opciones:

| Opcion | Seguridad | Operacion | Recomendacion ADEMA |
|---|---:|---:|---|
| Bucket privado sin cifrado adicional | Media | Simple | Minimo aceptable solo si el proveedor y permisos estan muy bien configurados |
| `rclone crypt` | Alta | Simple | Recomendado: buen balance seguridad/simplicidad |
| `age`/`gpg` por archivo | Alta | Media/Alta | Util si se necesita control criptografico externo, mas operativo |
| Backup con manifiesto/hash/retencion | Integridad/operacion | Simple | Mantener siempre; no reemplaza cifrado |

Migrar a `rclone crypt`:

```bash
sudo rclone config --config /root/.config/rclone/rclone.conf
```

Crear un remote base privado, por ejemplo `r2-adema`. Luego crear un remote crypt encima:

```text
name> adema-crypt
Storage> crypt
remote> r2-adema:adema-backups
filename_encryption> standard
directory_name_encryption> true
password> generar y guardar en gestor de secretos
password2> generar o dejar vacio segun politica
```

Actualizar entorno:

```bash
sudo sed -i 's|^BACKUP_REMOTE=.*|BACKUP_REMOTE=adema-crypt:nodos/gdc-node-001|' /etc/adema/node.env
sudo adema-node backup
sudo rclone lsf adema-crypt:nodos/gdc-node-001 --config /root/.config/rclone/rclone.conf
```

Guardar la password de `rclone crypt` fuera del nodo. Sin esa password no hay restore.

## 7. Que conviene hacer ahora

- Usar `/opt/adema-node` como ruta operativa.
- Definir `ADEMA_NODE_ID`, `CLUSTER_ID` y `BACKUP_REMOTE` reales antes del primer backup.
- Ejecutar `sudo adema-node doctor` despues de bootstrap.
- Crear tenants con `sudo adema-node create-tenant CLIENT_ID`.
- Pegar en Coolify las variables generadas.
- Probar login, DB y backup por cada tenant nuevo.
- Configurar `rclone crypt` antes de datos reales sensibles.
- Mantener el panel web apagado si no hace falta.
- Si se usa panel, publicarlo solo detras de Cloudflare Access/VPN/Tailscale/allowlist + HTTPS.

## 8. Que conviene hacer despues

- Dashboard solo lectura para ver estado de hasta 10 nodos.
- Alertas simples por disco, backup fallido y RAM.
- Restore de staging automatizado para practicar recuperacion.
- Rotacion periodica de tokens/passwords.
- Runbook por incidente: perdida de nodo, restore de tenant, backup corrupto.

## 9. Que NO conviene hacer todavia

- Kubernetes.
- Docker Swarm.
- DB central compartida para todos los nodos.
- Panel maestro con acciones destructivas remotas.
- Alta disponibilidad prematura.
- Multi-cloud complejo.
- Orquestacion global sobredimensionada.

Para el volumen esperado, la mejor inversion es que cada nodo sea repetible, auditable y facil de reconstruir.

## 10. Validacion final en la primera VM Ubuntu

En este repo se puede revisar Python en Windows, pero la validacion Bash real debe correr en la VM Ubuntu/Debian:

```bash
cd /opt/adema-node
find . -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n ./adema-node
python3 -m py_compile web_manager.py
sudo adema-node doctor
sudo adema-node create-tenant test001 --env-output
sudo adema-node backup
```

Salida esperada de `doctor`:

OK:

- identidad de nodo valida;
- UUID presente;
- backup remote unico;
- manifiesto remoto compatible;
- dominios correctos o advertencia clara si usan proxy/CDN.

WARN:

- dominio no configurado;
- `PROJECT_CODE` generico en modo desarrollo (`ADEMA_DEV_MODE=1`);
- panel web instalado pero no protegido por proxy/VPN;
- hostname/IP actual distinto del manifiesto remoto por cambio esperado de IP.

ERROR:

- `node.env` inexistente;
- `ADEMA_NODE_UUID` faltante o invalido;
- `BACKUP_REMOTE` generico o sin `ADEMA_NODE_ID`;
- manifiesto remoto pertenece a otro `ADEMA_NODE_UUID`;
- `CLUSTER_ID` demo/default en modo produccion;
- PostgreSQL expuesto publicamente o firewall sin proteccion efectiva.