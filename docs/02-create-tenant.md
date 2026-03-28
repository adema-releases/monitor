# Crear Tenant

## Alta rapida

```bash
sudo bash monitor/create_tenant.sh cli001
```

El script crea:

- Base de datos: `<DB_NAME_PREFIX>_cli001`
- Usuario SQL: `<DB_USER_PREFIX>_cli001`
- Volumenes por carpeta en `VOLUME_FOLDERS`

## Alta con password fija

```bash
sudo bash monitor/create_tenant.sh cli001 "PasswordSegura123"
```

## Verificacion de conectividad y permisos

```bash
bash monitor/test_tenant_db.sh cli001
```

Si no pasas password, se solicita en modo oculto.

## Errores comunes

- `permission denied`: ejecutar con `sudo`.
- Error de `psql`: validar `DB_HOST` y estado de PostgreSQL.
