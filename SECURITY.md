# Security Policy

Proyecto: Adema Core  
Repositorio oficial: https://github.com/adema-releases/monitor

## Supported Versions

Se considera soportada la rama estable mas reciente (`main`) y los ultimos tags de release.

## Reporting a Vulnerability

No abras issues publicos para vulnerabilidades.

Canales recomendados (en orden):

1. GitHub Security Advisory privado en este repositorio.
2. Si no es posible, abrir un contacto privado con el equipo mantenedor y luego migrar a Advisory.

Incluye este minimo de informacion:

- Tipo de vulnerabilidad y componente afectado.
- Impacto (confidencialidad, integridad, disponibilidad).
- Pasos de reproduccion detallados.
- Version, commit o tag afectado.
- Evidencia tecnica (logs saneados, payloads, capturas).
- Propuesta de mitigacion si ya la tienes.

## Response Targets

- Acuse de recibo inicial: hasta 72 horas.
- Triaging inicial: hasta 7 dias habiles.
- Plan de mitigacion: segun severidad y riesgo operacional.

## Disclosure Process

- Se valida impacto y alcance antes de publicar detalles.
- Se coordina ventana de parcheo con mantenedores.
- La divulgacion publica se realiza cuando exista mitigacion razonable.

## Scope

Incluye:

- Scripts de provision, backup, restore y monitoreo.
- Panel web Flask (`web_manager.py`) y endpoints `/api/*`.
- Integraciones de autenticacion por token, sudoers y systemd.

Se consideran prioridad alta:

- Exposicion de secretos o credenciales.
- Bypass de autenticacion/autorizacion.
- Ejecucion de comandos no autorizada.
- Escalada de privilegios o reglas de firewall inseguras.

## Security Best Practices

- No publicar `monitor/.monitor.secrets` ni `monitor/.monitor.env`.
- Rotar `ADEMA_WEB_TOKEN` periodicamente.
- Limitar acceso al panel con red privada, VPN, tunnel seguro o firewall con allowlist de IPs.
- Evitar `?token=` en URLs reales; para API usar `Authorization: Bearer TU_TOKEN` o `X-ADEMA-TOKEN: TU_TOKEN`.
- Mantener logs sin passwords ni tokens.
- Probar backup y restore en staging antes de produccion.
- Mantener PostgreSQL con SCRAM (`password_encryption = 'scram-sha-256'`).
