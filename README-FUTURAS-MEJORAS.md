# Adema Core - Futuras Mejoras

Estado actual: funcional y estable para operacion.

Este documento deja priorizadas las mejoras de seguridad y madurez para implementar en una fase posterior.

## Objetivo

Pasar de un baseline seguro-operativo a un baseline de produccion madura con controles adicionales.

## Roadmap Priorizado

### Prioridad Alta

1. Eliminar token por query string
- Riesgo actual: el token en URL puede filtrarse en historial, proxies o logs.
- Mejora: deshabilitar completamente el login por `?token=` y usar solo header o almacenamiento local post-login.

2. HTTPS y reverse proxy
- Riesgo actual: transporte en HTTP.
- Mejora: publicar el panel detras de Nginx o Caddy con TLS, redireccion HTTP->HTTPS y cabeceras de seguridad.

3. Rate limiting distribuido
- Riesgo actual: `memory://` funciona en instancia unica.
- Mejora: usar Redis como backend de Flask-Limiter para escalar a multiples workers/instancias.

4. Endurecer autenticacion PostgreSQL
- Mejora: automatizar gestion de `pg_hba.conf` para CIDR de red interna detectada y validar reglas antes de reiniciar.

### Prioridad Media

5. Hardening de sistema y servicio
- Aplicar restricciones adicionales en systemd (capabilities, paths, user isolation segun factibilidad).
- Revisar y minimizar sudoers periodicamente.

6. Auditoria y trazabilidad
- Correlacion de eventos con `request_id`.
- Registros estructurados para acciones criticas (create, delete, backup, restore).

7. Observabilidad
- Endpoint de health extendido para dependencia DB y permisos de scripts.
- Monitoreo de tasa de errores y alertas de disponibilidad del panel.

### Prioridad Baja

8. UX de seguridad
- Boton copiar al portapapeles en modal de credenciales.
- Checklist visual de estado de hardening en el panel.

9. Automatizacion de despliegue seguro
- Script de deploy con backup + validacion sintactica + restart atomico + rollback rapido.

## Criterios de Cierre (Done)

Cada mejora se considera completa cuando incluye:

- Cambio de codigo.
- Documentacion actualizada.
- Validacion operativa reproducible.
- Nota en changelog de la release correspondiente.

## Sugerencia de Versionado

- Mejoras de hardening sin romper contratos API: patch/minor (segun alcance).
- Cambios incompatibles de autenticacion o flujo: major/minor con guia de migracion.
