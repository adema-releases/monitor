# Changelog

Todos los cambios relevantes de este proyecto se documentan aqui.

## Unreleased

## 1.2.0 - 2026-05-07

### Added

- Nuevo script `monitor/setup_domains.sh`: asistente interactivo para configurar acceso por dominio al panel y a Coolify, con verificacion DNS, UFW, panel local y deteccion de conflicto con Coolify/Traefik.
- Nuevo modo `--check --json` en `setup_domains.sh` para devolver estado estructurado en JSON (usado por la API).
- Nuevo endpoint `GET /api/domain/status` en el panel web: ejecuta el chequeo de dominios y devuelve el estado en JSON.
- Nueva seccion visual "Dominios del nodo" en el dashboard del panel web con badges de estado en tiempo real.
- Nueva documentacion operativa: `docs/09-domain-setup.md`.

### Changed

- `setup_web_panel.sh`: agrega permiso sudoers para `setup_domains.sh` al allowlist de scripts autorizados.
- `README.md`: nueva seccion "Acceso por dominio" con tabla y comandos de referencia.
- `web_manager.py`: nuevas constantes `SETUP_DOMAINS_SCRIPT`, `ADEMA_INFRA_DOMAIN`, `ADEMA_DEPLOY_DOMAIN`.

### Compatibility

- No se rompen instalaciones existentes: el panel sigue accesible por `IP:5000` si no se configura dominio.
- No se instala ningun proxy si Coolify/Traefik ya gestiona 80/443.
- No se abren puertos UFW automaticamente.

### Docs

- Nuevo changelist detallado en `CHANGESET-1.2.0.md`.
- Nueva guia operativa en `docs/09-domain-setup.md`.

## 1.1.2 - 2026-05-06

### Changed

- Se actualiza la estetica del panel web operativo para alinearla con el manual de marca de Adema Sistemas.
- Se incorporan estilos consistentes para header, login, metricas, tablas, formularios, modales, botones y consola de logs.
- Se ajustan los botones y estados renderizados dinamicamente desde JavaScript para que usen el nuevo sistema visual.

### Compatibility

- No se modifican endpoints, tokens, scripts operativos ni contratos de API.

### Docs

- Nuevo changelist detallado en `CHANGESET-1.1.2.md`.

## 1.0.2 - 2026-03-28

### Security

- Se documenta hardening de `pg_hba.conf` para redes internas Docker/Coolify con autenticacion `scram-sha-256`.
- Se incorpora procedimiento de reinicio y validacion de PostgreSQL tras cambios de capa de autenticacion.

### Changed

- Se formaliza el flujo de alta de tenants cuando la red de contenedores usa segmento `10.0.0.0/16`.

### Docs

- Nuevo changelist detallado en `CHANGESET-1.0.2.md`.
- Actualizadas guias operativas de bootstrap y alta de tenant con comandos de `pg_hba.conf`.

## 1.0.1 - 2026-03-28

### Security

- PostgreSQL endurecido a SCRAM SHA-256 para nuevos usuarios tenant.
- Hardening de red con UFW: puerto 5432 permitido solo desde rangos internos Docker y denegado para el resto.
- Rate limiting por IP (10/min) en endpoints sensibles del panel: /api/auth/check y /api/health.
- Manejo y logging explícito de eventos 429 por exceso de límite.
- Higiene de logs: contraseñas de tenants no quedan en logs persistentes y se muestran una sola vez al crear recurso.

### Changed

- Auto-detección de IP docker0 para evitar dependencia de 172.17.0.1 en scripts operativos.
- Snapshot de salud enriquecido con docker0_ip y host/puerto DB efectivos.
- Refactor de marca y cabeceras a Adema Core con referencias al repositorio oficial.
- SECURITY.md actualizado a plantilla estándar de reporte de vulnerabilidades.

### Docs

- Changelist detallado de release en CHANGESET-1.0.1.md

### Added

- Estructura estandar open source: LICENSE, SECURITY.md, CONTRIBUTING.md y CODE_OF_CONDUCT.md
- Documentacion operativa completa en `docs/`
- Landing publica en `docs/index.html`
- Panel web seguro con token y ejecucion controlada de scripts

### Security

- Exclusiones en `.gitignore` para secretos y artefactos locales
- Guias para no exponer IPs reales ni credenciales
