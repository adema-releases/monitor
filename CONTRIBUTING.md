# Contributing Guide

Gracias por contribuir a este proyecto.

## Flujo recomendado

1. Crea una rama desde `main`
2. Realiza cambios pequenos y enfocados
3. Asegura que la documentacion este alineada
4. Abre un Pull Request con contexto claro

## Estilo de cambios

- Mantener scripts Bash simples y auditables
- No introducir dependencias pesadas sin justificacion
- Priorizar configuracion por variables (`DB_NAME_PREFIX`, `DB_USER_PREFIX`, etc.)
- Evitar cambios destructivos no solicitados

## Checklist antes de PR

- [ ] No se suben secretos (`.monitor.secrets`, `.monitor.env`)
- [ ] Documentacion actualizada (`README.md` y/o `docs/`)
- [ ] No hay referencias a IPs reales en docs publicas
- [ ] Comandos de ejemplo funcionan desde la raiz del repo

## Mensajes de commit sugeridos

Usar formato claro tipo Conventional Commits:

- `feat:` nuevas funcionalidades
- `fix:` correcciones
- `docs:` documentacion
- `chore:` tareas de mantenimiento
- `refactor:` mejoras internas sin cambio funcional

## Alcance de issues/PRs

Aceptamos mejoras en:

- Provision y operacion de tenants
- Backup/restore
- Monitoreo y alertas
- Hardening del panel web
- Documentacion y runbooks
