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
- Error de autenticacion desde contenedor (`no pg_hba.conf entry` o similar):

```bash
echo "host    all             all             10.0.0.0/16            scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql
sudo ss -nltp | grep 5432
```

Si tu red Docker/Coolify usa otro segmento, reemplaza `10.0.0.0/16` por el CIDR real.
