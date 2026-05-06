# Changelist Release 1.1.2

Fecha: 2026-05-06
Tipo de release: Ajuste visual del panel web operativo segun manual de marca

## Resumen Ejecutivo

La release 1.1.2 actualiza la estetica del panel web operativo de Adema Core para alinearlo con el manual de marca de Adema Sistemas, manteniendo la simplicidad del flujo actual.

El foco principal es que el monitor servido por `ip:puerto` deje de verse generico y pase a comunicar una identidad visual consistente sin modificar la logica operativa del backend.

## Detalle de Cambios

### 1) Nueva capa visual del panel web

Implementado:

- Paleta basada en azul profundo, cian electrico, azul Adema, blanco y grises frios.
- Fondo claro tecnologico con grilla sutil para dar identidad sin distraer del uso operativo.
- Header principal en navy profundo con isotipo de Adema y contraste reforzado.
- Tarjetas de metricas con borde cian, jerarquia visual clara y lectura rapida.
- Paneles con radio de 8px, sombra suave y bordes consistentes.

Impacto:

- El panel administrativo se siente coherente con Adema Sistemas.
- Se mantiene una interfaz simple, escaneable y orientada a operaciones.

Archivos:

- `web_manager.py`
- `static/logo/logo.png`
- `static/logo/Diseño sin título (26).png`
- `static/logo/favicon.ico`

### 2) Estandarizacion de controles y estados

Implementado:

- Sistema de botones reusable para acciones principales, secundarias, exito, advertencia y peligro.
- Inputs y textareas con foco visual cian y bordes consistentes.
- Badges de estado tipo `pill` para `sin job activo`, `doble seguridad` y estados de eliminacion.
- Tabla de tenants y papelera con acciones dinamicas alineadas al nuevo estilo.
- Consola de logs oscura con borde cian y texto de alta legibilidad.

Impacto:

- Acciones criticas como backup, alta, restauracion y borrado definitivo son mas faciles de identificar.
- Las filas renderizadas desde JavaScript ya no conservan estilos visuales anteriores.

Archivos:

- `web_manager.py`

### 3) Login y modales alineados a marca

Implementado:

- Pantalla de login centrada con logo Adema y boton principal cian/azul.
- Modal de borrado definitivo actualizado con fondo oscuro translucido y tarjeta consistente.
- Modal de credenciales de conexion ajustado al nuevo sistema visual.
- Uso de assets existentes de `static/logo/` sin incorporar dependencias nuevas.

Impacto:

- El primer contacto con el panel ya muestra identidad Adema.
- Las operaciones sensibles mantienen confirmacion reforzada sin cambios de contrato.

Archivos:

- `web_manager.py`
- `static/logo/logo.png`

## Compatibilidad y Riesgos

Compatibilidad:

- No se modifican endpoints, rutas, permisos, tokens ni contratos de API.
- No se cambian scripts operativos de tenant, backup, restore o snapshot.
- El panel sigue usando los assets existentes bajo `/static/logo/`.

Riesgos operativos controlados:

- El cambio depende de que los archivos de logo existan en `static/logo/`, como ya ocurre en el repo.
- Las tablas mantienen scroll horizontal en pantallas chicas para preservar datos operativos sin solapes.

## Checklist de Validacion

1. Abrir el panel en `http://IP:5000` y confirmar que el login carga el logo Adema.
2. Iniciar sesion con `ADEMA_WEB_TOKEN` y validar que la cabecera usa el isotipo y fondo navy.
3. Verificar lectura de tarjetas de Host, RAM, Disco y Contenedores.
4. Confirmar que `Gestion de Tenants`, `Papelera de Tenants`, `Formulario de Alta` y `Logs en tiempo real` mantienen layout correcto.
5. Confirmar que botones dinamicos de tenants y papelera usan el nuevo estilo.
6. Validar en movil que no haya solapes; las tablas pueden desplazarse horizontalmente.
7. Ejecutar validacion de sintaxis de `web_manager.py` antes de publicar.

## Versionado

- Version: 1.1.2
- Clasificacion: Patch visual de panel web
