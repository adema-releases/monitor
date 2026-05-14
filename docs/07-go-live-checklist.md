# Go-Live Checklist (Nodo Nuevo)

Checklist final antes de dar de alta la primera app en el nodo.

## 1. Estado base del servidor

- [ ] Ubuntu actualizado
- [ ] Docker operativo
- [ ] PostgreSQL operativo
- [ ] rclone configurado y autenticado

## 2. Configuracion monitor

- [ ] `monitor/.monitor.env` completo
- [ ] `monitor/.monitor.secrets` con API key valida
- [ ] `bash monitor/status_snapshot.sh` devuelve JSON valido

## 3. Panel web

- [ ] Monitor publicado como app en Coolify
- [ ] `https://monitor.ademasistemas.com/healthz` responde
- [ ] Token guardado de forma segura
- [ ] Puerto `5000` no expuesto publicamente
- [ ] Coolify/Traefik maneja `80/443`
- [ ] Nginx del host deshabilitado o inactivo

## 3.1 DNS y proxy

- [ ] Cloudflare tiene `A @` hacia la IP del nodo
- [ ] Cloudflare tiene `A *` hacia la IP del nodo
- [ ] `deploy.ademasistemas.com` apunta al panel Coolify
- [ ] `monitor.ademasistemas.com` apunta al monitor ADEMA
- [ ] MX/TXT/DKIM/SPF/DMARC/Brevo/Zoho no fueron modificados

## 4. Prueba funcional minima

- [ ] Crear tenant de prueba
- [ ] Correr test DB del tenant
- [ ] Correr backup manual
- [ ] Correr restore en tenant de staging

## 5. Observabilidad

- [ ] `setup_cron.sh` instalado
- [ ] Logs en `logs/` generandose
- [ ] Llega email de `monitor_report.sh`
- [ ] Llega alerta de `sentinel_ram.sh` al superar umbral (si aplica)

## 6. Criterio de pase a produccion

Puedes considerar el nodo listo si:

1. Snapshot, panel y scripts de tenant funcionan.
2. Backup + restore fueron probados una vez.
3. Alertas y reporte por email estan validados.
