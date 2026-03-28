# Changelist Release 1.0.1

Fecha: 2026-03-28
Tipo de release: Seguridad y hardening (Zero Trust)

## Resumen Ejecutivo

La release 1.0.1 migra el nodo desde un esquema de confianza interna a un enfoque Zero Trust, con foco en:

- Endurecimiento de PostgreSQL con SCRAM.
- Cierre de exposición de red para puerto 5432 con UFW.
- Eliminación de dependencias hardcodeadas a 172.17.0.1 mediante auto-detección docker0.
- Protección del panel web con rate limiting por IP.
- Higiene de logs para evitar persistencia de credenciales en texto plano.
- Normalización de marca y referencias al repositorio oficial Adema Core.

## Detalle de Cambios

### 1) Seguridad PostgreSQL (SCRAM)

Implementado:

- Configuración automática de password_encryption = 'scram-sha-256' en postgresql.conf detectado por SHOW config_file.
- Recarga de configuración PostgreSQL con pg_reload_conf() tras aplicar cambio.
- Creación de usuarios tenant con SET password_encryption = 'scram-sha-256' y WITH ENCRYPTED PASSWORD.

Impacto:

- Nuevos usuarios DB quedan bajo estándar SCRAM SHA-256.
- Se reduce superficie de riesgo frente a esquemas de hash antiguos.

Archivos:

- monitor/lib/common.sh
- monitor/create_tenant.sh

### 2) Hardening de Red y Auto-detección docker0

Implementado:

- Función centralizada de detección de IP en interfaz docker0.
- DB_HOST se resuelve por prioridad: DB_HOST explícito, DB_DOCKER0_IP, detección docker0, fallback 127.0.0.1.
- Eliminación de lógica acoplada a 172.17.0.1 en pruebas de conectividad.
- Exposición del host DB efectivo y docker0_ip en snapshot de salud.

Firewall UFW:

- Se instala y configura UFW en setup_web_panel.sh.
- Se habilita acceso 5432/tcp solo para:
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
- Se bloquea el resto con deny in to any port 5432 proto tcp.
- Se remueven reglas abiertas previas de tipo ALLOW IN Anywhere para 5432.

Impacto:

- PostgreSQL deja de estar abierto a redes no internas.
- Scripts de operación funcionan de forma portable sin IP fija de bridge.

Archivos:

- monitor/lib/common.sh
- monitor/test_tenant_db.sh
- monitor/status_snapshot.sh
- setup_web_panel.sh
- run_monitor.sh
- monitor/.monitor.env.example

### 3) Rate Limiting en Flask (Panel Web)

Implementado:

- Integración de Flask-Limiter en backend.
- Límite estricto de 10 requests por minuto por IP en:
  - /api/auth/check
  - /api/health
- Manejo estándar de error 429 con respuesta JSON.
- Registro de eventos de exceso de límite y accesos no autorizados en logs del servicio.

Impacto:

- Mitigación de abuso y brute-force de endpoints sensibles.

Archivos:

- web_manager.py
- setup_web_panel.sh (instalación de dependencia flask-limiter)

### 4) Higiene de Logs y Control de Secretos

Implementado:

- El flujo de alta de tenant desde API genera contraseña segura si no se envía una explícita.
- La contraseña generada se devuelve una sola vez al cliente (db_password_once).
- El script de creación soporta --no-password-output para impedir volcado en logs persistentes.
- Redacción de argumentos sensibles en metadatos de jobs (passwords ocultas).

Impacto:

- Evita persistencia accidental de contraseñas en logs de texto plano.
- Mantiene usabilidad operativa mostrando el secreto solo al momento de creación.

Archivos:

- web_manager.py
- monitor/create_tenant.sh

### 5) Política de Seguridad (SECURITY.md)

Implementado:

- Se reemplazó el contenido por una plantilla más estándar para disclosure responsable.
- Incluye versiones soportadas, canales de reporte, tiempos objetivo, alcance y buenas prácticas.

Archivos:

- SECURITY.md

### 6) Refactor de Marca y Referencias Oficiales

Implementado:

- Comentarios y cabeceras de scripts actualizados a Adema Core.
- Referencias de documentación alineadas al repositorio oficial.
- Eliminación de referencias residuales a marca anterior en documentación principal.

Archivos:

- README.md
- docs/index.html
- docs/01-new-node.md
- docs/08-master-node-federation.md
- run_monitor.sh
- setup_web_panel.sh
- monitor/lib/common.sh
- monitor/test_tenant_db.sh
- monitor/status_snapshot.sh
- monitor/create_tenant.sh
- web_manager.py

## Compatibilidad y Riesgos

Compatibilidad:

- No se introdujeron cambios de contrato incompatibles en endpoints existentes, salvo endurecimiento de límites en auth/health.

Riesgos operativos controlados:

- Si existía una regla UFW abierta para 5432, ahora queda restringida.
- Entornos que dependían de host hardcodeado 172.17.0.1 pasan a auto-detección docker0 o fallback seguro.

## Checklist de Post-release

1. Ejecutar setup_web_panel.sh para aplicar UFW y dependencias nuevas.
2. Reiniciar servicio adema-web-panel.service.
3. Validar rate limiting en /api/auth/check y /api/health (respuesta 429 tras exceder 10/min por IP).
4. Crear tenant de prueba y verificar:
   - Password visible una sola vez en UI.
   - Sin password en logs persistentes de jobs.
5. Confirmar reglas UFW de 5432 restringidas a rangos internos.

## Versionado

- Versión: 1.0.1
- Clasificación: Patch de seguridad y hardening
