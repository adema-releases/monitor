# Provision y Bootstrap Del Nodo Ubuntu 24.04 + Coolify

Este documento esta pensado para que cualquier persona con una VM Ubuntu 24.04 limpia pueda levantar Coolify, clonar Adema Core desde el repo publico `adema-releases/monitor`, configurar el monitor y dejar el panel web operativo de forma repetible.

Resultado esperado al terminar:

- Coolify instalado y con onboarding inicial completado.
- Repo clonado en `/home/adema/monitor`.
- Variables demo/productivas generadas en `monitor/.monitor.env`.
- Secretos guardados fuera del repo.
- Panel web activo como `adema-web-panel.service`.
- Backup, monitoreo y restore validados antes de produccion.

## 1. Crear nodo con patron de nombre

Antes de abrir la VM, define un patron de nombre para no desordenarte cuando escales.

- Recomendado: `NODO_XXX`
- Ejemplos: `NODO_001`, `NODO_MAD_01`, `NODO_AR_02`

Usa ese mismo patron en:

- nombre de VPS en proveedor cloud
- hostname del servidor
- nombre del nodo en Coolify
- etiquetas internas o inventario

## 2. Abrir VM y actualizar Ubuntu

Conecta por SSH al nodo nuevo y actualiza todo el sistema.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y && sudo apt autoclean -y
```

## 3. Instalar dependencias base

Instala paquetes para contenedores, base de datos, backup remoto y seguridad minima.

```bash
# Instalar motor oficial de Docker y Compose V2
curl -fsSL https://get.docker.com | sh

# Instalar resto de dependencias del stack Adema
sudo apt install -y postgresql postgresql-contrib rclone openssl git ufw fail2ban
```

## 4. Instalar Coolify

Instala Coolify en el nodo:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

Cuando termine:

- identifica IP publica del nodo (por ejemplo con `curl -4 ifconfig.me`)
- abre la URL que muestra el instalador (en tu caso `http://IP_PUBLICA:3000`)
- si no responde, revisa firewall y habilita puerto `3000/tcp` con UFW
- crea usuario administrador en Coolify
- guarda URL, usuario, password y tokens en tu gestor de claves

## 5. Completar onboarding inicial de Coolify

En el asistente de primera entrada de Coolify (`Choose Server Type`), selecciona segun tu escenario:

- `This Machine`: recomendado para este runbook. Despliega en el mismo nodo donde corre Coolify.
- `Remote Server`: para conectar uno o varios nodos externos por SSH.
- `Hetzner Cloud`: aprovisionamiento directo en Hetzner.

Para tu flujo actual:

1. Selecciona `This Machine`.
2. Continua con `Deploy/Next`.
3. Crea el primer proyecto con `Create My First Project`.

## 6. Clonar monitor y configurar secretos

```bash
# 1. Crear el usuario de operaciones y su espacio de trabajo
sudo useradd -m -s /bin/bash adema
sudo usermod -aG sudo adema

# 2. Clonar el repo publico en la ruta correcta (fuera de root)
sudo -u adema git clone https://github.com/adema-releases/monitor /home/adema/monitor
cd /home/adema/monitor

# 3. Asegurar permisos de ejecucion de scripts
sudo find . -type f -name "*.sh" -exec chmod 755 {} \;

# 4. Lanzar configuracion y panel web
sudo bash run_monitor.sh
sudo bash setup_web_panel.sh
```

Este comando previene errores `Permission denied` cuando se ejecutan opciones del launcher (por ejemplo reporte/centinela).

En primera ejecucion, `run_monitor.sh` abrira asistente interactivo. Es normal ver prompts como:

- `PROJECT_CODE [demo]:`
- `CLUSTER_ID [CLUSTER-DEMO-01]:`
- `DB_NAME_PREFIX [demo_db]:`
- `DB_USER_PREFIX [demo_user]:`
- `BACKUP_REMOTE [r2:demo-backups]:`

Si quieres aceptar el valor sugerido, presiona Enter. Si necesitas personalizar, escribe el valor y Enter.

En `run_monitor.sh` usa la opcion de configuracion y completa al menos:

- `DB_NAME_PREFIX`
- `DB_USER_PREFIX`
- `BACKUP_REMOTE`
- `BREVO_RECIPIENT`
- `BREVO_SENDER`

En este paso guarda tambien:

- password de DB por tenant
- `ADEMA_WEB_TOKEN`
- `BREVO_API_KEY`

### Primera ejecucion de run_monitor.sh (modo demo publico)

Para documentacion publica, usa valores neutros como estos. En produccion reemplazalos por los datos reales de tu organizacion y guardalos fuera del repo.

| Prompt | Valor sugerido | Razon tecnica |
|---|---|---|
| PROJECT_CODE | demo | Estandariza naming de proyecto en todo el nodo. |
| CLUSTER_ID | CLUSTER-DEMO-01 | Identificador unico del nodo para inventario y alertas. |
| DB_PREFIX | demo | Uniforma nombre logico de bases y recursos. |
| DB_NAME_PREFIX | demo_db | Prefijo interno de DB para separar entornos. |
| DB_USER_PREFIX | demo_user | Prefijo de usuarios SQL consistente y auditable. |
| VOLUME_BASE_PATH | Presionar Enter | Mantiene path estandar de Docker. |
| VOLUME_PREFIX | demo | Ordena volumenes por proyecto. |
| VOLUME_FOLDERS | Presionar Enter | Conserva defaults recomendados: license logs media. |
| BACKUP_DIR | /var/lib/demo/backups_locales | Ubicacion segura para dumps locales. |
| BACKUP_RETENTION_DAYS | 30 | Retencion operativa de ejemplo. |
| BACKUP_REMOTE | r2:demo-backups | Remote rclone de ejemplo para continuidad. |
| BREVO_RECIPIENT | ops@example.com | Buzon de alertas de ejemplo. |
| BREVO_SENDER | no-reply@example.com | Sender de ejemplo para alertas. |
| BREVO_SENDER_NAME | Adema Core Demo | Identificacion clara del origen de correo. |
| DB_HOST | (vacio para auto) | Auto-deteccion de IP docker0 para alcanzar host PostgreSQL. |
| RAM_THRESHOLD_MB | 450 | Alerta temprana para evitar degradacion por memoria. |
| EXCLUDE_CONTAINER_REGEX | coolify\|NAME | Evita ruido monitoreando contenedores de sistema. |

Diccionario rapido:

- BACKUP_REMOTE: r2:demo-backups
- DB_PREFIX: demo
- DB_HOST: dejar vacio para auto-deteccion docker0
- RETENTION: 30 days

Nota: cuando pida BREVO_API_KEY, pega tu clave real de Brevo (no se muestra en pantalla).

## 7. Enlazar repositorio en Coolify

Desde el panel de Coolify:

1. Ve a `Sources`.
2. Agrega origen GitHub/GitLab.
3. Autoriza el repositorio que quieres desplegar.
4. Crea recurso/app Django usando ese repo.

Si tienes repo personal y repo fork/base, define claramente cual es:

- repo fuente para deploy (produccion)
- repo base para sincronizar cambios

## 8. Validacion inicial y cron

Verifica estado del nodo:

```bash
bash monitor/status_snapshot.sh
sudo systemctl status adema-web-panel.service
sudo bash monitor/monitor_report.sh
sudo bash monitor/sentinel_ram.sh
```

Luego programa tareas operativas:

```bash
sudo bash setup_cron.sh
```

Antes de usar el nodo como productivo, ejecuta al menos un backup y un restore de prueba en un tenant de staging.

## 9. Ajuste de autenticacion PostgreSQL para redes Docker/Coolify

Si tus apps en contenedores obtienen IPs del segmento interno `10.0.x.x`, agrega una regla de acceso en `pg_hba.conf` para evitar rechazos de autenticacion.

```bash
# Autoriza red interna Docker/Coolify con SCRAM
echo "host    all             all             10.0.0.0/16            scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
```

Aplica y valida cambios:

```bash
sudo systemctl restart postgresql
sudo ss -nltp | grep 5432
```

Nota: ajusta el CIDR si tu red interna real es distinta a `10.0.0.0/16`.
