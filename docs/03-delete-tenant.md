# Eliminar Tenant

## Borrado completo

```bash
sudo bash monitor/delete_tenant.sh cli001
```

El script solicita confirmacion interactiva y luego elimina:

- Base de datos del tenant
- Usuario SQL del tenant
- Volumenes fisicos del tenant

## Recomendacion de seguridad

1. Ejecutar backup antes de borrar.
2. Validar el `CLIENT_ID` dos veces.
3. Ejecutar en ventana de mantenimiento.
