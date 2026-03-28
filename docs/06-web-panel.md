# Panel Web Seguro

## Instalacion

```bash
sudo bash setup_web_panel.sh
```

Este instalador:

- Crea usuario de servicio `adema` si no existe
- Prepara virtualenv e instala Flask
- Genera `ADEMA_WEB_TOKEN` en `/etc/adema/web_panel.env`
- Configura sudoers con allowlist minima de scripts
- Levanta `adema-web-panel.service` en systemd

## Servicio

```bash
sudo systemctl status adema-web-panel.service
sudo journalctl -u adema-web-panel.service -n 100 --no-pager
```

## Acceso

- URL: `http://[TU_IP_AQUI]:5000/`
- Se requiere token en cada request

## Endpoints API principales

- `GET /api/health`
- `POST /api/tenant/create`
- `POST /api/tenant/test-db`
- `POST /api/backup/now`
- `GET /api/jobs/<job_id>/log`

## Recomendaciones

1. Exponer el panel detras de VPN o firewall de IP permitidas.
2. Rotar token periodicamente.
3. Revisar sudoers despues de cambios de rutas.
