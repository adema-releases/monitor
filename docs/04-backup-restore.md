# Backup y Restore

## Backup del proyecto

```bash
sudo bash monitor/backup_project.sh
```

Incluye:

- Backup logico de todas las DB con prefijo del proyecto
- Copia `latest` por DB
- Sync remoto de DB y volumenes por tenant
- Pruning local por retencion

## Restore de tenant

```bash
sudo bash monitor/restore_tenant.sh cli001 2026-03-27 archivo.sql.gz
```

Si faltan argumentos, el script los solicita.

## Checklist posterior a restore

```bash
bash monitor/test_tenant_db.sh cli001
```

- Confirmar que el tenant levanta en Coolify.
- Confirmar presencia de media/logs/licencias.
