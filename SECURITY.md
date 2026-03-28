# Security Policy

## Reportar una vulnerabilidad

Si encuentras una vulnerabilidad de seguridad, no abras un issue publico.

Reporta en privado con:

- Descripcion del problema
- Impacto esperado
- Pasos para reproducir
- Version/commit afectado
- Evidencia (logs, request/response, etc.)

Canal recomendado: crear un Security Advisory en GitHub para este repositorio.

## Tiempo de respuesta objetivo

- Acuse de recibo inicial: dentro de 72 horas
- Evaluacion inicial: dentro de 7 dias habiles
- Plan de mitigacion/correccion: segun severidad

## Alcance

Este proyecto incluye scripts de operacion de infraestructura y un panel web ligero.
Las vulnerabilidades relacionadas con secretos, ejecucion de comandos y permisos se consideran de alta prioridad.

## Buenas practicas para despliegues

- No subir `monitor/.monitor.secrets` ni `monitor/.monitor.env`
- Rotar `ADEMA_WEB_TOKEN` periodicamente
- Limitar acceso al panel web con firewall o VPN
- Probar restore en entorno de staging antes de usar produccion
