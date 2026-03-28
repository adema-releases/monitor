# Changelog

Todos los cambios relevantes de este proyecto se documentan aqui.

## Unreleased

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
