# Provision y Bootstrap Del Nodo

## 1. Preparar servidor

Ejemplo base: Ubuntu 24.04 LTS con Docker, PostgreSQL y rclone configurado.

```bash
sudo apt update
sudo apt install -y docker.io postgresql postgresql-contrib rclone curl openssl
```

## 2. Clonar repositorio

```bash
git clone https://github.com/adema-releases/monitor
cd monitor
```

## 3. Configurar entorno monitor

```bash
sudo bash run_monitor.sh
```

En el menu:

- Opcion 1 para variables y secretos.
- Completar al menos `DB_NAME_PREFIX`, `DB_USER_PREFIX`, `BACKUP_REMOTE`, `BREVO_RECIPIENT`, `BREVO_SENDER`.

## 4. Validacion inicial

```bash
sudo bash monitor/monitor_report.sh
sudo bash monitor/sentinel_ram.sh
```

## 5. Programar cron de produccion

```bash
sudo bash setup_cron.sh
```
