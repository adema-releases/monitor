#!/usr/bin/env python3
import hmac
import json
import os
import re
import shutil
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from subprocess import PIPE, STDOUT, Popen, run
from typing import Dict, List, Optional

from flask import Flask, jsonify, request, Response


ROOT_DIR = Path(__file__).resolve().parent
MONITOR_DIR = ROOT_DIR / "monitor"
STATUS_SCRIPT = MONITOR_DIR / "status_snapshot.sh"
CREATE_SCRIPT = MONITOR_DIR / "create_tenant.sh"
TEST_DB_SCRIPT = MONITOR_DIR / "test_tenant_db.sh"
BACKUP_SCRIPT = MONITOR_DIR / "backup_project.sh"

JOBS_DIR = ROOT_DIR / ".web_jobs"
JOBS_DIR.mkdir(exist_ok=True)

CLIENT_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
DB_PASSWORD_RE = re.compile(r"^[a-zA-Z0-9@#%+=:._-]{8,128}$")

TOKEN = os.getenv("ADEMA_WEB_TOKEN", "").strip()
HOST = os.getenv("ADEMA_WEB_HOST", "0.0.0.0")
PORT = int(os.getenv("ADEMA_WEB_PORT", "5000"))
MAX_CONCURRENT_JOBS = int(os.getenv("ADEMA_MAX_JOBS", "4"))
MIN_BACKUP_FREE_MB = int(os.getenv("ADEMA_MIN_BACKUP_FREE_MB", "500"))
ENV_FILE_PATH = os.getenv("ADEMA_ENV_FILE", "/etc/adema/web_panel.env")

if not TOKEN:
    raise RuntimeError("ADEMA_WEB_TOKEN no esta definido.")

app = Flask(__name__)


@dataclass
class Job:
    id: str
    action: str
    created_at: str
    status: str
    return_code: Optional[int]
    command: List[str]
    log_path: str
    error: Optional[str] = None


jobs: Dict[str, Job] = {}
jobs_lock = threading.Lock()
_executor = ThreadPoolExecutor(max_workers=MAX_CONCURRENT_JOBS, thread_name_prefix="adema-job")


def _extract_token() -> str:
    header_token = request.headers.get("X-ADEMA-TOKEN", "").strip()
    if header_token:
        return header_token

    auth = request.headers.get("Authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()

    return request.args.get("token", "").strip()


@app.before_request
def validate_token() -> Optional[Response]:
    # La pagina principal es HTML estatico sin datos sensibles;
    # los datos se obtienen via /api/* que SI requiere token.
  if request.path in ["/", "/favicon.ico"]:
        return None

  provided = _extract_token()
  if provided and hmac.compare_digest(provided, TOKEN):
      return None

  if request.path.startswith("/api/"):
      return jsonify({"error": "unauthorized"}), 401
  return Response("Unauthorized", status=401)


def _run_snapshot() -> dict:
    cmd = ["sudo", "-n", "/bin/bash", str(STATUS_SCRIPT)]
    result = run(cmd, cwd=str(ROOT_DIR), capture_output=True, text=True, check=False, timeout=25)
    if result.returncode != 0:
        raise RuntimeError(f"status_snapshot fallo: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"JSON invalido en status_snapshot: {exc}") from exc


def _ensure_client_id(client_id: str) -> str:
    value = (client_id or "").strip()
    if not CLIENT_ID_RE.fullmatch(value):
        raise ValueError("CLIENT_ID invalido. Solo letras, numeros, guion y guion bajo.")
    return value


def _ensure_password(password: str) -> str:
    value = (password or "").strip()
    if not DB_PASSWORD_RE.fullmatch(value):
        raise ValueError("DB_PASSWORD invalida para esta API.")
    return value


def _enqueue_job(action: str, command: List[str]) -> Job:
    job_id = uuid.uuid4().hex[:12]
    log_path = JOBS_DIR / f"{job_id}.log"
    now = datetime.now(timezone.utc).isoformat()
    job = Job(
        id=job_id,
        action=action,
        created_at=now,
        status="queued",
        return_code=None,
        command=command,
        log_path=str(log_path),
    )

    with jobs_lock:
        jobs[job_id] = job

    _executor.submit(_run_job_worker, job_id)
    return job


def _run_job_worker(job_id: str) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
    if not job:
        return

    with jobs_lock:
        job.status = "running"

    log_file = Path(job.log_path)
    try:
        with log_file.open("w", encoding="utf-8") as lf:
            lf.write(f"[INFO] Ejecutando: {job.action} (job_id={job_id})\n")
            lf.flush()

            process = Popen(
                job.command,
                cwd=str(ROOT_DIR),
                stdout=PIPE,
                stderr=STDOUT,
                text=True,
                bufsize=1,
            )

            if process.stdout:
                for line in process.stdout:
                    lf.write(line)
                    lf.flush()

            return_code = process.wait()

        with jobs_lock:
            job.status = "success" if return_code == 0 else "failed"
            job.return_code = return_code
    except Exception as exc:
        with jobs_lock:
            job.status = "failed"
            job.return_code = -1
            job.error = str(exc)
        with log_file.open("a", encoding="utf-8") as lf:
            lf.write(f"\n[ERROR] {exc}\n")


@app.get("/")
def index() -> Response:
    html = """<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Adema Control Center</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    body { background: radial-gradient(circle at 10% 10%, #d9f99d 0%, #f8fafc 45%, #cbd5e1 100%); }
    .panel { backdrop-filter: blur(6px); }
  </style>
</head>
<body class="min-h-screen text-slate-900">
  <main class="max-w-6xl mx-auto p-4 md:p-8 space-y-6">

    <!-- LOGIN: visible por defecto -->
    <section id="loginSection" class="panel bg-white/80 border border-slate-200 rounded-2xl p-8 shadow-sm max-w-lg mx-auto mt-20">
      <h1 class="text-2xl font-black tracking-tight mb-1">Adema Control Center</h1>
      <p class="text-slate-500 text-sm mb-5">Ingresa tu token de acceso para continuar.</p>
      <div class="flex flex-col gap-3">
        <input id="tokenInput" type="password" class="w-full border rounded-xl px-3 py-2" placeholder="ADEMA_WEB_TOKEN" />
        <button id="saveTokenBtn" class="bg-lime-600 hover:bg-lime-700 text-white rounded-xl px-4 py-2 font-semibold">Ingresar</button>
        <p id="loginError" class="text-red-600 text-sm hidden">Token invalido. Verifica e intenta de nuevo.</p>
      </div>
    </section>

    <!-- PANEL: oculto hasta autenticacion -->
    <div id="panelSection" class="hidden space-y-6">
      <header class="panel bg-white/80 border border-slate-200 rounded-2xl p-5 shadow-sm flex items-center justify-between">
        <div>
          <h1 class="text-2xl md:text-3xl font-black tracking-tight">Adema Control Center</h1>
          <p class="text-slate-600 mt-1">MVP operativo para gestionar nodo Django + PostgreSQL.</p>
        </div>
        <button id="logoutBtn" class="bg-red-600 hover:bg-red-700 text-white rounded-xl px-4 py-2 font-semibold text-sm">Cerrar sesion</button>
      </header>

      <section class="grid md:grid-cols-4 gap-4">
        <article class="panel bg-white/80 border rounded-2xl p-4 shadow-sm">
          <h2 class="text-xs uppercase tracking-wider text-slate-500">Host</h2>
          <p id="hostName" class="text-lg font-bold">-</p>
        </article>
        <article class="panel bg-white/80 border rounded-2xl p-4 shadow-sm">
          <h2 class="text-xs uppercase tracking-wider text-slate-500">RAM</h2>
          <p id="ramUsage" class="text-lg font-bold">-</p>
        </article>
        <article class="panel bg-white/80 border rounded-2xl p-4 shadow-sm">
          <h2 class="text-xs uppercase tracking-wider text-slate-500">Disco /</h2>
          <p id="diskUsage" class="text-lg font-bold">-</p>
        </article>
        <article class="panel bg-white/80 border rounded-2xl p-4 shadow-sm">
          <h2 class="text-xs uppercase tracking-wider text-slate-500">Contenedores</h2>
          <p id="containersCount" class="text-lg font-bold">-</p>
        </article>
      </section>

      <section class="panel bg-white/80 border rounded-2xl p-5 shadow-sm space-y-4">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-xl font-bold">Gestion de Tenants</h2>
          <button id="backupBtn" class="bg-slate-900 hover:bg-slate-700 text-white rounded-xl px-4 py-2 font-semibold">Backup Now</button>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-slate-500 border-b">
                <th class="py-2">CLIENT_ID</th>
                <th class="py-2">DB</th>
                <th class="py-2">Acciones</th>
              </tr>
            </thead>
            <tbody id="tenantsBody"></tbody>
          </table>
        </div>
      </section>

      <section class="panel bg-white/80 border rounded-2xl p-5 shadow-sm space-y-3">
        <h2 class="text-xl font-bold">Formulario de Alta</h2>
        <div class="grid md:grid-cols-3 gap-3">
          <input id="clientIdInput" class="border rounded-xl px-3 py-2" placeholder="cli001" />
          <input id="clientPassInput" class="border rounded-xl px-3 py-2" placeholder="DB password opcional" />
          <button id="createTenantBtn" class="bg-emerald-600 hover:bg-emerald-700 text-white rounded-xl px-4 py-2 font-semibold">Crear Infraestructura</button>
        </div>
        <p class="text-xs text-slate-500">Si no envias password, create_tenant.sh generara una automaticamente.</p>
      </section>

      <section class="panel bg-slate-900 text-slate-100 border border-slate-700 rounded-2xl p-5 shadow-sm">
        <div class="flex items-center justify-between gap-3 mb-2">
          <h2 class="text-xl font-bold">Logs en tiempo real</h2>
          <span id="jobStatus" class="text-xs bg-slate-700 px-2 py-1 rounded">sin job activo</span>
        </div>
        <pre id="logOutput" class="text-xs whitespace-pre-wrap h-72 overflow-auto bg-black/30 rounded-xl p-3"></pre>
      </section>
    </div>

  </main>

  <script>
    let activeJobId = null;
    let activeOffset = 0;
    let healthInterval = null;

    const loginSection = document.getElementById("loginSection");
    const panelSection = document.getElementById("panelSection");
    const loginError = document.getElementById("loginError");

    function getToken() {
      return localStorage.getItem("adema_token") || "";
    }

    function setToken(token) {
      localStorage.setItem("adema_token", token);
    }

    function showLogin() {
      loginSection.classList.remove("hidden");
      panelSection.classList.add("hidden");
      loginError.classList.add("hidden");
      if (healthInterval) { clearInterval(healthInterval); healthInterval = null; }
    }

    function showPanel() {
      loginSection.classList.add("hidden");
      panelSection.classList.remove("hidden");
    }

    async function api(path, options = {}) {
      const headers = Object.assign({}, options.headers || {}, {
        "Content-Type": "application/json",
        "X-ADEMA-TOKEN": getToken()
      });
      const res = await fetch(path, Object.assign({}, options, { headers }));
      if (!res.ok) {
        const err = await res.text();
        const e = new Error(err || `HTTP ${res.status}`);
        e.status = res.status;
        throw e;
      }
      return res.json();
    }

    function renderHealth(data) {
      const host = data.host || {};
      document.getElementById("hostName").textContent = host.hostname || "-";
      const ram = host.ram || {};
      document.getElementById("ramUsage").textContent = `${ram.used_mb || 0} / ${ram.total_mb || 0} MB`;
      document.getElementById("diskUsage").textContent = host.disk_root_usage || "-";
      const containers = data.containers || {};
      document.getElementById("containersCount").textContent = containers.running || 0;

      const rows = (data.databases || []).map((db) => {
        const cid = db.client_id || "";
        return `<tr class="border-b border-slate-200"><td class="py-2 font-semibold">${cid}</td><td class="py-2">${db.db_name}</td><td class="py-2"><button class="bg-cyan-700 hover:bg-cyan-800 text-white px-3 py-1 rounded test-db" data-client="${cid}">Test DB</button></td></tr>`;
      }).join("");
      document.getElementById("tenantsBody").innerHTML = rows || '<tr><td colspan="3" class="py-3 text-slate-500">No hay tenants detectados.</td></tr>';

      document.querySelectorAll(".test-db").forEach((btn) => {
        btn.addEventListener("click", async () => {
          const clientId = btn.dataset.client;
          const dbPassword = prompt(`DB_PASSWORD para ${clientId}`);
          if (!dbPassword) return;
          const resp = await api("/api/tenant/test-db", {
            method: "POST",
            body: JSON.stringify({ client_id: clientId, db_password: dbPassword })
          });
          activateJob(resp.job_id);
        });
      });
    }

    async function refreshHealth() {
      try {
        const data = await api("/api/health");
        renderHealth(data);
      } catch (err) {
        if (err.status === 401) {
          showLogin();
          loginError.classList.remove("hidden");
          loginError.textContent = "Sesion expirada o token invalido.";
          return;
        }

        document.getElementById("hostName").textContent = "error de backend";
        document.getElementById("ramUsage").textContent = "-";
        document.getElementById("diskUsage").textContent = "-";
        document.getElementById("containersCount").textContent = "-";
      }
    }

    async function tryLogin(tokenOverride = null) {
      const t = (tokenOverride ?? document.getElementById("tokenInput").value).trim();
      if (!t) return;
      setToken(t);
      try {
        await api("/api/auth/check");
        showPanel();
        await refreshHealth();
        healthInterval = setInterval(refreshHealth, 15000);
      } catch (err) {
        localStorage.removeItem("adema_token");
        loginError.classList.remove("hidden");
        if (err.status === 401) {
          loginError.textContent = "Token invalido. Verifica e intenta de nuevo.";
        } else {
          loginError.textContent = "Autenticacion OK pero fallo backend. Revisa sudoers/servicio.";
        }
      }
    }

    async function activateJob(jobId) {
      activeJobId = jobId;
      activeOffset = 0;
      document.getElementById("logOutput").textContent = "";
      await pollActiveJob();
    }

    async function pollActiveJob() {
      if (!activeJobId) return;
      try {
        const data = await api(`/api/jobs/${activeJobId}/log?offset=${activeOffset}`);
        activeOffset = data.offset;
        document.getElementById("jobStatus").textContent = `${data.status} (rc=${data.return_code})`;
        if (data.chunk) {
          const out = document.getElementById("logOutput");
          out.textContent += data.chunk;
          out.scrollTop = out.scrollHeight;
        }
        if (data.status === "running" || data.status === "queued") {
          setTimeout(pollActiveJob, 1200);
        }
      } catch (err) {
        document.getElementById("jobStatus").textContent = "error leyendo log";
      }
    }

    document.getElementById("saveTokenBtn").addEventListener("click", tryLogin);
    document.getElementById("tokenInput").addEventListener("keydown", (e) => {
      if (e.key === "Enter") tryLogin();
    });

    document.getElementById("logoutBtn").addEventListener("click", () => {
      localStorage.removeItem("adema_token");
      showLogin();
      document.getElementById("tokenInput").value = "";
    });

    document.getElementById("createTenantBtn").addEventListener("click", async () => {
      const clientId = document.getElementById("clientIdInput").value.trim();
      const dbPassword = document.getElementById("clientPassInput").value.trim();
      const payload = { client_id: clientId };
      if (dbPassword) payload.db_password = dbPassword;

      const resp = await api("/api/tenant/create", {
        method: "POST",
        body: JSON.stringify(payload)
      });

      activateJob(resp.job_id);
      setTimeout(refreshHealth, 3000);
    });

    document.getElementById("backupBtn").addEventListener("click", async () => {
      const resp = await api("/api/backup/now", {
        method: "POST",
        body: JSON.stringify({})
      });
      activateJob(resp.job_id);
    });

    // Auto-login si hay token guardado o en la URL
    const tokenFromQuery = new URLSearchParams(window.location.search).get("token");
    if (tokenFromQuery) {
      setToken(tokenFromQuery);
      window.history.replaceState({}, '', window.location.pathname);
    }
    const storedToken = getToken();
    if (storedToken) {
      tryLogin(storedToken);
    }
  </script>
</body>
</html>
"""
    return Response(html, mimetype="text/html")


@app.get("/api/health")
def api_health() -> Response:
    try:
        snapshot = _run_snapshot()
        return jsonify(snapshot)
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/api/auth/check")
def api_auth_check() -> Response:
    # Si el request llega aqui, el token ya fue validado en before_request.
    return jsonify({"ok": True})


@app.post("/api/tenant/create")
def api_create_tenant() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
        command = ["sudo", "-n", "/bin/bash", str(CREATE_SCRIPT), client_id]

        db_password = payload.get("db_password", "")
        if db_password:
            command.append(_ensure_password(db_password))

        job = _enqueue_job("create_tenant", command)
        return jsonify({"ok": True, "job_id": job.id})
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400


@app.post("/api/tenant/test-db")
def api_test_tenant_db() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
        db_password = _ensure_password(payload.get("db_password", ""))
        command = ["sudo", "-n", "/bin/bash", str(TEST_DB_SCRIPT), client_id, db_password]
        job = _enqueue_job("test_tenant_db", command)
        return jsonify({"ok": True, "job_id": job.id})
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400


@app.post("/api/backup/now")
def api_backup_now() -> Response:
    backup_dir = os.getenv("BACKUP_DIR", "/var/lib/django/backups_locales")
    try:
        usage = shutil.disk_usage(backup_dir)
        free_mb = usage.free // (1024 * 1024)
        if free_mb < MIN_BACKUP_FREE_MB:
            return jsonify({
                "error": f"Espacio insuficiente: {free_mb}MB libres, minimo {MIN_BACKUP_FREE_MB}MB."
            }), 507
    except OSError:
        pass

    command = ["sudo", "-n", "/bin/bash", str(BACKUP_SCRIPT)]
    job = _enqueue_job("backup_now", command)
    return jsonify({"ok": True, "job_id": job.id})


@app.post("/api/admin/rotate-token")
def api_rotate_token() -> Response:
    global TOKEN
    payload = request.get_json(silent=True) or {}
    new_token = (payload.get("new_token") or "").strip()

    if len(new_token) < 32:
        return jsonify({"error": "new_token debe tener al menos 32 caracteres."}), 400

    file_updated = False
    try:
        env_path = Path(ENV_FILE_PATH)
        if env_path.is_file():
            lines = env_path.read_text(encoding="utf-8").splitlines()
            for i, line in enumerate(lines):
                if line.startswith("ADEMA_WEB_TOKEN="):
                    lines[i] = f"ADEMA_WEB_TOKEN={new_token}"
            env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            file_updated = True
    except OSError:
        pass

    TOKEN = new_token
    msg = "Token rotado en memoria."
    if file_updated:
        msg += " Archivo de configuracion actualizado."
    else:
        msg += " No se pudo actualizar el archivo; actualice manualmente y reinicie."
    return jsonify({"ok": True, "message": msg, "file_updated": file_updated})


@app.get("/api/jobs")
def api_jobs() -> Response:
    with jobs_lock:
        rows = [asdict(job) for job in jobs.values()]
    return jsonify({"jobs": rows})


@app.get("/api/jobs/<job_id>")
def api_job(job_id: str) -> Response:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({"error": "job_not_found"}), 404
        data = asdict(job)
    return jsonify(data)


@app.get("/api/jobs/<job_id>/log")
def api_job_log(job_id: str) -> Response:
    offset_raw = request.args.get("offset", "0").strip()
    try:
        offset = max(0, int(offset_raw))
    except ValueError:
        return jsonify({"error": "offset_invalido"}), 400

    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return jsonify({"error": "job_not_found"}), 404
        status = job.status
        return_code = job.return_code
        error = job.error
        log_path = Path(job.log_path)

    if not log_path.exists():
        return jsonify(
            {
                "job_id": job_id,
                "status": status,
                "return_code": return_code,
                "error": error,
                "offset": 0,
                "chunk": "",
            }
        )

    file_size = log_path.stat().st_size
    if offset > file_size:
        offset = file_size

    with log_path.open("rb") as f:
        f.seek(offset)
        chunk = f.read().decode("utf-8", errors="replace")
        new_offset = f.tell()

    return jsonify(
        {
            "job_id": job_id,
            "status": status,
            "return_code": return_code,
            "error": error,
            "offset": new_offset,
            "chunk": chunk,
        }
    )


if __name__ == "__main__":
    app.run(host=HOST, port=PORT)
