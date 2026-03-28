# 08 – Federación: Nodo Maestro

## Concepto

Un **Nodo Maestro** (o "Control Plane") consulta el endpoint `/api/health` de
cada nodo esclavo para consolidar una vista global de toda la infraestructura de
Adema Sistemas.

```
┌─────────────────────────────────┐
│         NODO MAESTRO            │
│  (Flask / web_manager.py)       │
│                                 │
│  GET /api/federation/overview   │
│                                 │
│    ┌────────┐  ┌────────┐       │
│    │ node-1 │  │ node-2 │  ...  │
│    └───┬────┘  └───┬────┘       │
└────────┼───────────┼────────────┘
         │           │
   GET /api/health   GET /api/health
         │           │
   ┌─────▼──┐  ┌─────▼──┐
   │ Nodo 1 │  │ Nodo 2 │
   └────────┘  └────────┘
```

## Configuración propuesta

Añadir en `/etc/adema/web_panel.env` del nodo maestro:

```env
# Lista de nodos separados por coma
ADEMA_FEDERATION_NODES=https://node1.adema.com:5000,https://node2.adema.com:5000
# Token para autenticarse contra los nodos esclavos (puede ser distinto por nodo)
ADEMA_FEDERATION_TOKEN=<token-compartido>
# Timeout por nodo en segundos
ADEMA_FEDERATION_TIMEOUT=10
```

## Endpoint: `GET /api/federation/overview`

Devuelve un JSON con el estado de cada nodo:

```json
{
  "timestamp": "2026-03-28T12:00:00Z",
  "nodes": [
    {
      "url": "https://node1.adema.com:5000",
      "status": "ok",
      "data": { /* respuesta de /api/health */ }
    },
    {
      "url": "https://node2.adema.com:5000",
      "status": "unreachable",
      "error": "ConnectionTimeout after 10s"
    }
  ]
}
```

## Implementación mínima (para agregar a `web_manager.py`)

```python
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

FEDERATION_NODES = [
    n.strip()
    for n in os.getenv("ADEMA_FEDERATION_NODES", "").split(",")
    if n.strip()
]
FEDERATION_TOKEN = os.getenv("ADEMA_FEDERATION_TOKEN", TOKEN)
FEDERATION_TIMEOUT = int(os.getenv("ADEMA_FEDERATION_TIMEOUT", "10"))


def _poll_node(url: str) -> dict:
    try:
        resp = requests.get(
            f"{url}/api/health",
            headers={"X-ADEMA-TOKEN": FEDERATION_TOKEN},
            timeout=FEDERATION_TIMEOUT,
            verify=True,
        )
        resp.raise_for_status()
        return {"url": url, "status": "ok", "data": resp.json()}
    except Exception as exc:
        return {"url": url, "status": "unreachable", "error": str(exc)}


@app.get("/api/federation/overview")
def api_federation_overview():
    if not FEDERATION_NODES:
        return jsonify({"error": "No hay nodos configurados."}), 404

    results = []
    with ThreadPoolExecutor(max_workers=min(len(FEDERATION_NODES), 10)) as pool:
        futures = {pool.submit(_poll_node, url): url for url in FEDERATION_NODES}
        for future in as_completed(futures):
            results.append(future.result())

    return jsonify({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "nodes": results,
    })
```

## Seguridad

- Los nodos esclavos **solo** exponen `/api/health` (lectura). El maestro no
  puede ejecutar operaciones destructivas de forma remota.
- Utilizar HTTPS obligatorio entre nodos. Configurar `verify=True` en requests.
- El `ADEMA_FEDERATION_TOKEN` **NO** debería ser el mismo que el token local
  de cada nodo. Generar uno exclusivo para la federación.
- Si se requiere gestión remota (crear/borrar tenants), implementar un
  mecanismo de "action request" con confirmación humana.

## Alerta centralizada

El nodo maestro puede ejecutar un cron que invoque `/api/federation/overview`
y envíe un email consolidado vía Brevo cuando algún nodo esté `unreachable`
o su disco supere el 90% de uso.
