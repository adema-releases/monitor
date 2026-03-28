# Changelist Release 1.0.2

Fecha: 2026-03-28
Tipo de release: Ajuste operativo de seguridad PostgreSQL (Docker/Coolify)

## Resumen

Esta release formaliza en documentacion un ajuste clave de produccion:

- Autorizacion de red interna de contenedores en `pg_hba.conf` para el segmento `10.0.0.0/16`.
- Metodo de autenticacion `scram-sha-256` alineado con el hardening definido en 1.0.1.
- Reinicio y validacion de capa PostgreSQL luego del cambio.

## Cambio Operativo Estandar

Comando de alta de regla en `pg_hba.conf`:

```bash
echo "host    all             all             10.0.0.0/16            scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
```

Aplicacion del cambio:

```bash
sudo systemctl restart postgresql
sudo ss -nltp | grep 5432
```

## Motivo Tecnico

En despliegues con Coolify/Docker, los contenedores app pueden tomar IPs del segmento interno `10.0.x.x`.
Si ese rango no esta permitido en `pg_hba.conf`, la app no autentica contra PostgreSQL aunque el usuario/DB esten correctamente creados.

## Impacto

- Reduce fallos de conexion post-deploy por reglas incompletas en capa de autenticacion PostgreSQL.
- Mejora escalabilidad: no requiere agregar IP por contenedor manualmente.
- Mantiene estandar de seguridad al exigir `scram-sha-256`.

## Archivos de Documentacion Actualizados

- `docs/01-new-node.md`
- `docs/02-create-tenant.md`
- `CHANGELOG.md`

## Checklist de Validacion

1. Confirmar regla presente en `pg_hba.conf`.
2. Reiniciar `postgresql`.
3. Verificar escucha en `5432`.
4. Reintentar alta/deploy de tenant.
5. Confirmar conectividad SQL desde contenedor/app.

## Versionado

- Version: 1.0.2
- Clasificacion: Patch operativo y de documentacion de seguridad
