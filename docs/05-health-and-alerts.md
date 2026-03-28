# Monitoreo, Test y Centinela

## Snapshot read-only del nodo

```bash
bash monitor/status_snapshot.sh
```

Devuelve JSON con:

- Salud del host (RAM, swap, disco, load)
- Estado de contenedores (docker stats)
- Lista de DB detectadas

No envia emails.

## Reporte operativo por email

```bash
sudo bash monitor/monitor_report.sh
```

## Centinela de RAM por email

```bash
sudo bash monitor/sentinel_ram.sh
```

## Test de DB por tenant

```bash
bash monitor/test_tenant_db.sh cli001
```
