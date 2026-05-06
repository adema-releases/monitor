# Changelist Release 1.1.0

Fecha: 2026-05-06
Tipo de release: Mejora de documentacion publica, onboarding Ubuntu 24.04/Coolify y hardening operativo del panel

## Resumen Ejecutivo

La release 1.1.0 ordena la presentacion publica del proyecto y convierte la documentacion en una ruta clara para levantar un nodo desde una VM Ubuntu 24.04 limpia con Coolify, Adema Core y panel web operativo.

El foco principal es mejorar confianza tecnica y reducir friccion de adopcion:

- Repositorio publico normalizado a `adema-releases/monitor`.
- Producto mantenido como `Adema Core`.
- Camino principal documentado: Ubuntu 24.04 -> Docker/PostgreSQL/rclone -> Coolify -> monitor -> panel web -> backup/restore probado.
- Ejemplos publicos saneados con valores demo y placeholders neutros.
- Recomendacion de acceso al panel sin tokens en URL.
- Defaults interactivos alineados con la documentacion publica.

## Detalle de Cambios

### 1) Normalizacion de identidad publica y repositorio

Implementado:

- Reemplazo de referencias publicas a `https://github.com/adema-releases/adema-core` por `https://github.com/adema-releases/monitor`.
- Definicion explicita de identidad publica:
  - Producto: `Adema Core`.
  - Repo publico: `adema-releases/monitor`.
  - Carpeta operativa sugerida: `/home/adema/monitor`.
- Actualizacion de cabeceras y comentarios en scripts para apuntar al repositorio correcto.

Impacto:

- Evita que usuarios copien comandos de clone hacia un repo inexistente, privado o inconsistente.
- Mejora confianza inicial del usuario tecnico al alinear README, docs, scripts y pagina publica.

Archivos:

- `README.md`
- `docs/index.html`
- `docs/01-new-node.md`
- `SECURITY.md`
- `run_monitor.sh`
- `setup_web_panel.sh`
- `web_manager.py`
- `monitor/lib/common.sh`
- `monitor/create_tenant.sh`
- `monitor/status_snapshot.sh`
- `monitor/test_tenant_db.sh`

### 2) Ruta publica clara para VM Ubuntu 24.04 + Coolify

Implementado:

- Nueva seccion principal en README: `Ruta recomendada: Ubuntu 24.04 + Coolify + Adema Core`.
- Runbook de nuevo nodo renombrado y reorientado a Ubuntu 24.04 + Coolify.
- Documentacion de resultado esperado al finalizar:
  - Coolify instalado.
  - Repo clonado en `/home/adema/monitor`.
  - Variables generadas.
  - Secretos fuera del repo.
  - Panel web activo como `adema-web-panel.service`.
  - Backup, monitoreo y restore validados.
- Quickstart actualizado con:

```bash
git clone https://github.com/adema-releases/monitor
cd monitor
sudo find . -type f -name "*.sh" -exec chmod 755 {} \;
sudo bash run_monitor.sh
sudo bash setup_web_panel.sh
```

Impacto:

- Cualquier persona puede seguir una secuencia de instalacion desde VM limpia hasta nodo operativo.
- Se reduce ambiguedad entre instalacion del monitor, instalacion de Coolify y puesta en marcha del panel web.

Archivos:

- `README.md`
- `docs/README.md`
- `docs/01-new-node.md`
- `docs/index.html`

### 3) Saneamiento de ejemplos publicos y modo demo

Implementado:

- Reemplazo de valores con informacion operativa o interna por placeholders demo.
- Valores publicos sugeridos:
  - `PROJECT_CODE=demo`
  - `CLUSTER_ID=CLUSTER-DEMO-01`
  - `DB_NAME_PREFIX=demo_db`
  - `DB_USER_PREFIX=demo_user`
  - `BACKUP_REMOTE=r2:demo-backups`
  - `BREVO_RECIPIENT=ops@example.com`
  - `BREVO_SENDER=no-reply@example.com`
  - `BREVO_SENDER_NAME="Adema Core Demo"`
- Eliminacion de ejemplos ligados a nombres internos, correos reales, remotes productivos o identificadores especificos.
- Actualizacion de `monitor/.monitor.env.example` para que sea una plantilla publica neutra.
- Actualizacion de defaults de `run_monitor.sh` para que el asistente interactivo coincida con la documentacion.

Impacto:

- Reduce inteligencia operativa expuesta en un repositorio publico.
- Facilita copiar/pegar ejemplos sin arrastrar naming interno.
- Evita inconsistencia entre lo que documenta el README y lo que muestra el asistente.

Archivos:

- `README.md`
- `docs/index.html`
- `docs/01-new-node.md`
- `monitor/.monitor.env.example`
- `run_monitor.sh`

### 4) Hardening de acceso al panel web y uso de token

Implementado:

- Documentacion actualizada para evitar recomendar `?token=` en URLs reales.
- Recomendacion explicita para API y automatizaciones:
  - `Authorization: Bearer TU_TOKEN`
  - `X-ADEMA-TOKEN: TU_TOKEN`
- Mensajes de instalacion y rotacion del panel ajustados para mostrar URL base + token, no URL directa con token en query string.
- Recomendaciones reforzadas:
  - Panel detras de VPN, tunnel seguro o allowlist de IPs.
  - Puerto `5000` solo accesible desde IPs autorizadas.
  - Rotacion periodica del token.
  - Logs sin passwords ni tokens.

Impacto:

- Reduce riesgo de filtracion de token por historial, logs, capturas o referers.
- Mantiene compatibilidad tecnica con el panel actual, pero cambia la practica recomendada hacia un flujo mas seguro.

Archivos:

- `docs/06-web-panel.md`
- `SECURITY.md`
- `setup_web_panel.sh`
- `rotate_web_token.sh`
- `README.md`

### 5) Validacion operacional minima reforzada

Implementado:

- README y runbook remarcan que un nodo no debe considerarse productivo hasta probar backup y restore.
- Firewall recomendado para panel web actualizado desde apertura global de `5000/tcp` hacia allowlist por IP:

```bash
sudo ufw allow from [TU_IP_AUTORIZADA] to any port 5000 proto tcp
```

Impacto:

- Reduce riesgo de exponer panel administrativo a internet.
- Refuerza el criterio de continuidad: restore probado antes de salida productiva.

Archivos:

- `README.md`
- `docs/01-new-node.md`
- `docs/06-web-panel.md`
- `SECURITY.md`

### 6) Identidad visual publica segun manual de marca

Implementado:

- Uso de `static/logo/logo.png` en el hero de `docs/index.html`.
- Uso del isotipo de `static/logo/` en el header publico.
- Uso de `static/logo/favicon.ico` como favicon de la pagina.
- Estilo visual alineado al manual de marca:
  - Fondo navy profundo.
  - Blanco para lectura principal.
  - Cian y azul electrico como acentos.
  - Paneles oscuros con bordes cian finos.
  - Estetica tecnica con lineas tipo circuito.
  - Botones y bloques de codigo acordes a la paleta Adema.

Impacto:

- La pagina publica deja de sentirse generica y pasa a ser coherente con Adema Sistemas.
- El primer viewport comunica marca, infraestructura y confianza tecnica desde el inicio.

Archivos:

- `docs/index.html`
- `static/logo/logo.png`
- `static/logo/favicon.ico`

## Compatibilidad y Riesgos

Compatibilidad:

- No se introducen cambios incompatibles en endpoints existentes.
- El panel sigue aceptando los mecanismos ya implementados por backend, pero la documentacion y los mensajes operativos priorizan formulario/header sobre query param.
- Los nuevos defaults `demo` afectan solo configuraciones nuevas o ejecuciones donde no exista `monitor/.monitor.env` previo.

Riesgos operativos controlados:

- Si un operador esperaba copiar una URL con `?token=`, ahora debe abrir la URL base y pegar el token en el login.
- Si se dependia de defaults `django`, los entornos existentes no se ven afectados cuando ya existe `.monitor.env`; solo cambia la sugerencia inicial para instalaciones nuevas.

## Checklist de Validacion

1. Confirmar que no quedan referencias publicas a `adema-releases/adema-core`.
2. Confirmar que `README.md` clona `https://github.com/adema-releases/monitor`.
3. Confirmar que `docs/index.html` apunta al repo correcto en botones y enlaces.
4. Ejecutar una instalacion nueva y validar prompts demo del launcher:
   - `PROJECT_CODE [demo]`
   - `CLUSTER_ID [CLUSTER-DEMO-01]`
   - `BACKUP_REMOTE [r2:demo-backups]`
5. Ejecutar `setup_web_panel.sh` y confirmar que muestra URL base + token, sin URL directa con `?token=`.
6. Ejecutar `rotate_web_token.sh` y confirmar el mismo comportamiento.
7. Validar acceso al panel por formulario y API con header.
8. Verificar backup y restore en tenant de staging antes de produccion.
9. Abrir `docs/index.html` y confirmar que cargan logo, isotipo y favicon desde `static/logo/`.

## Versionado

- Version: 1.1.0
- Clasificacion: Minor de documentacion publica, onboarding operativo y hardening de seguridad