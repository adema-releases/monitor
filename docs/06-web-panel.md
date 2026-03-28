# Panel Web Seguro

## Instalacion

```bash
sudo bash setup_web_panel.sh
```

Este instalador:

- Crea usuario de servicio `adema` si no existe
- Prepara virtualenv e instala Flask + Flask-Limiter + Waitress
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

## Papelera de tenants y borrado definitivo (desde panel)

El panel implementa borrado en 2 fases para evitar eliminaciones accidentales:

1. **Mover a papelera** desde la tabla de tenants activos.
2. **Borrado definitivo** solo desde la seccion **Papelera de Tenants**.

### Flujo recomendado en UI

1. En **Gestion de Tenants**, click en `Mover a papelera`.
2. El tenant desaparece de la tabla principal y pasa a **Papelera de Tenants**.
3. Desde papelera puedes:
	- `Restaurar` (vuelve a la tabla principal), o
	- `Borrar definitivo` (abre modal de doble confirmacion).
4. Para borrar definitivo, el panel exige:
	- escribir el `CLIENT_ID` exacto,
	- escribir la frase de confirmacion mostrada (por defecto `BORRAR TENANT`).

Si ambas validaciones son correctas, se encola el job de borrado real y puedes seguirlo en **Logs en tiempo real**.

### Frase de confirmacion

La frase se controla por variable de entorno:

```bash
ADEMA_DELETE_CONFIRM_TEXT="BORRAR TENANT"
```

Si no se define, el valor por defecto es `BORRAR TENANT`.

### Errores comunes al borrar desde papelera

- `confirmacion_invalida`: frase mal escrita.
- `confirmacion_client_id_invalida`: CLIENT_ID no coincide.
- `tenant_no_esta_en_papelera`: intentaste borrar un tenant fuera de papelera.
- `delete_sudoers_missing`: falta permiso sudo para `delete_tenant.sh`.

En caso de permisos incompletos:

```bash
sudo bash setup_web_panel.sh
```

## Recomendaciones

1. Exponer el panel detras de VPN o firewall de IP permitidas.
2. Rotar token periodicamente.
3. Revisar sudoers despues de cambios de rutas.

## Recuperar token actual

Si perdiste el token y tienes acceso root al nodo:

```bash
sudo grep '^ADEMA_WEB_TOKEN=' /etc/adema/web_panel.env
```

Tambien puedes ver URL + token directo en:

```bash
sudo bash setup_web_panel.sh
```

Nota: este comando reinstala/actualiza componentes del panel y vuelve a imprimir URL/token.

## Rotar token (recomendado)

Desde el launcher interactivo:

1. Ejecuta `sudo bash run_monitor.sh`
2. Elige `10) Regenerar token del panel web`

Por comando directo:

```bash
sudo bash rotate_web_token.sh
```

Si quieres definir un token manual:

```bash
sudo bash rotate_web_token.sh "TU_TOKEN_LARGO_Y_SEGURO"
```

El script actualiza `/etc/adema/web_panel.env`, reinicia `adema-web-panel.service` y muestra la URL final con `?token=`.

## Reinstalar o reparar panel web

Desde el launcher interactivo:

1. Ejecuta `sudo bash run_monitor.sh`
2. Elige `11) Instalar/actualizar panel web`

Por comando directo:

```bash
sudo bash setup_web_panel.sh
```

Esto vuelve a validar entorno Python, sudoers y unidad systemd del panel.

## Reinicio y chequeo rapido (opciones nuevas)

- `12) Reiniciar servicio panel web`
- `13) Ver estado servicio panel web`

Comandos equivalentes:

```bash
sudo systemctl restart adema-web-panel.service
sudo systemctl --no-pager --full status adema-web-panel.service | sed -n '1,25p'
```

## Troubleshooting rapido

### Error `unauthorized` o `token invalido`

1. Verifica el token activo:

```bash
sudo grep '^ADEMA_WEB_TOKEN=' /etc/adema/web_panel.env
```

2. Si dudas del valor, regenera token:

```bash
sudo bash rotate_web_token.sh
```

### Panel no abre (timeout/refused)

```bash
sudo systemctl status adema-web-panel.service --no-pager
sudo journalctl -u adema-web-panel.service -n 120 --no-pager
sudo ss -lntp | grep ':5000'
```

Si no hay listener en `:5000`, reinstala y reinicia:

```bash
sudo bash setup_web_panel.sh
sudo systemctl restart adema-web-panel.service
```

### Warning `This is a development server` en logs

Si ves este warning en `journalctl`, el servicio aun esta arrancando con `python web_manager.py` (servidor dev de Flask).

Reaplica instalador para migrar a Waitress (WSGI para produccion):

```bash
sudo bash setup_web_panel.sh
sudo systemctl daemon-reload
sudo systemctl restart adema-web-panel.service
```

Verifica que el `ExecStart` quede con `waitress-serve`:

```bash
sudo systemctl cat adema-web-panel.service
```

Salida esperada (resumen):

```text
ExecStart=/home/adema/monitor/.venv_web_panel/bin/waitress-serve --listen=0.0.0.0:5000 web_manager:app
```

Nota: desde esta version los recursos `/static/*` son publicos para evitar 401 de imagenes/logo en la pantalla de login.

### Error de dependencia: `No module named flask_limiter`

Si el servicio no levanta despues de actualizar y en `journalctl` aparece un error similar a:

- `ModuleNotFoundError: No module named 'flask_limiter'`

instala la dependencia en el virtualenv del panel y reinicia el servicio:

```bash
/home/adema/monitor/.venv_web_panel/bin/pip install flask-limiter
sudo systemctl restart adema-web-panel.service
sudo journalctl -u adema-web-panel.service -n 80 --no-pager
```

Alternativa recomendada (reaplica instalador completo):

```bash
sudo bash setup_web_panel.sh
```

### El backend responde pero falla crear/borrar tenant

Suele ser permisos de sudoers fuera de sincronia:

```bash
sudo bash setup_web_panel.sh
sudo visudo -cf /etc/sudoers.d/adema-monitor-web
```

### El panel funciona local pero no desde Internet

1. Verifica firewall:

```bash
sudo ufw status
sudo ufw allow 5000/tcp
```

2. Confirma reglas del proveedor cloud (Security Group / ACL).
