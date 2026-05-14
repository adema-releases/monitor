#!/usr/bin/env python3
"""Adema Core web manager.

Repo oficial: https://github.com/adema-releases/monitor
"""

import hmac
import json
import logging
import os
import re
import secrets
import shutil
import tempfile
import threading
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from subprocess import PIPE, STDOUT, Popen, TimeoutExpired, run
from typing import Dict, List, Optional

from flask import Flask, jsonify, request, Response
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address


ROOT_DIR = Path(__file__).resolve().parent
# Ruta absoluta esperada en produccion; permite override por variable de entorno.
MONITOR_DIR = Path(os.getenv("ADEMA_MONITOR_DIR", "/opt/adema-node/monitor")).resolve()
STATUS_SCRIPT = MONITOR_DIR / "status_snapshot.sh"
CREATE_SCRIPT = MONITOR_DIR / "create_tenant.sh"
TEST_DB_SCRIPT = MONITOR_DIR / "test_tenant_db.sh"
BACKUP_SCRIPT = MONITOR_DIR / "backup_project.sh"
DELETE_SCRIPT = MONITOR_DIR / "delete_tenant.sh"

JOBS_DIR = ROOT_DIR / ".web_jobs"
JOBS_DIR.mkdir(exist_ok=True)
TRASH_FILE = ROOT_DIR / ".tenant_trash.json"

CLIENT_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
DB_PASSWORD_RE = re.compile(r"^[a-zA-Z0-9@#%+=:._-]{8,128}$")

TOKEN = os.getenv("ADEMA_WEB_TOKEN", "").strip()
HOST = os.getenv("ADEMA_WEB_HOST", "127.0.0.1")
PORT = int(os.getenv("ADEMA_WEB_PORT", "5000"))
ALLOW_QUERY_TOKEN = os.getenv("ADEMA_ALLOW_QUERY_TOKEN", "0").strip().lower() in {"1", "true", "yes", "si"}
MAX_CONCURRENT_JOBS = int(os.getenv("ADEMA_MAX_JOBS", "4"))
MIN_BACKUP_FREE_MB = int(os.getenv("ADEMA_MIN_BACKUP_FREE_MB", "500"))
SNAPSHOT_TIMEOUT_SEC = int(os.getenv("ADEMA_SNAPSHOT_TIMEOUT_SEC", "12"))
ENV_FILE_PATH = os.getenv("ADEMA_ENV_FILE", "/etc/adema/web_panel.env")
DELETE_CONFIRM_TEXT = (os.getenv("ADEMA_DELETE_CONFIRM_TEXT", "BORRAR TENANT") or "BORRAR TENANT").strip()
MONITOR_ENV_PATH = Path(os.getenv("MONITOR_ENV_FILE", str(MONITOR_DIR / ".monitor.env"))).resolve()
NODE_ENV_PATH = Path(os.getenv("ADEMA_NODE_ENV_FILE", "/etc/adema/node.env")).resolve()
SETUP_DOMAINS_SCRIPT = ROOT_DIR / "monitor" / "setup_domains.sh"

BASE_DOMAIN = os.getenv("BASE_DOMAIN", os.getenv("ADEMA_BASE_DOMAIN", "")).strip()
MONITOR_DOMAIN = os.getenv("MONITOR_DOMAIN", os.getenv("ADEMA_INFRA_DOMAIN", "")).strip()
COOLIFY_DOMAIN = os.getenv("COOLIFY_DOMAIN", os.getenv("ADEMA_DEPLOY_DOMAIN", "")).strip()
ADEMA_INFRA_DOMAIN = os.getenv("ADEMA_INFRA_DOMAIN", MONITOR_DOMAIN).strip()
ADEMA_DEPLOY_DOMAIN = os.getenv("ADEMA_DEPLOY_DOMAIN", COOLIFY_DOMAIN).strip()

if not TOKEN:
    raise RuntimeError("ADEMA_WEB_TOKEN no esta definido.")

app = Flask(__name__)
logging.basicConfig(
    level=os.getenv("ADEMA_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

limiter = Limiter(
  get_remote_address,
  app=app,
  default_limits=[],
  storage_uri=os.getenv("ADEMA_RATE_LIMIT_STORAGE", "memory://"),
)


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
trash_lock = threading.Lock()
_executor = ThreadPoolExecutor(max_workers=MAX_CONCURRENT_JOBS, thread_name_prefix="adema-job")


def _extract_token() -> str:
    header_token = request.headers.get("X-ADEMA-TOKEN", "").strip()
    if header_token:
        return header_token

    auth = request.headers.get("Authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()

    if ALLOW_QUERY_TOKEN:
      return request.args.get("token", "").strip()

    return ""


@app.before_request
def validate_token() -> Optional[Response]:
  # Recursos publicos sin datos sensibles.
  if request.path in ["/", "/favicon.ico", "/robots.txt", "/healthz"] or request.path.startswith("/static/"):
        return None

  provided = _extract_token()
  if provided and hmac.compare_digest(provided, TOKEN):
    return None

  app.logger.warning("Intento no autorizado a %s desde ip=%s", request.path, request.remote_addr)
  if request.path.startswith("/api/"):
    return jsonify({"error": "unauthorized"}), 401
  return Response("Unauthorized", status=401)


@app.errorhandler(429)
def handle_rate_limit(_exc: Exception) -> Response:
    app.logger.warning("Rate limit excedido en %s desde ip=%s", request.path, request.remote_addr)
    return jsonify({"error": "too_many_requests", "message": "Rate limit excedido"}), 429


def _run_snapshot() -> dict:
    cmd = ["sudo", "-n", "/bin/bash", str(STATUS_SCRIPT)]
    try:
        result = run(
            cmd,
            cwd=str(ROOT_DIR),
            capture_output=True,
            text=True,
            check=False,
            timeout=SNAPSHOT_TIMEOUT_SEC,
        )
    except TimeoutExpired as exc:
        raise RuntimeError(f"status_snapshot timeout tras {SNAPSHOT_TIMEOUT_SEC}s") from exc

    if result.returncode != 0:
        raise RuntimeError(f"status_snapshot fallo: {result.stderr.strip()}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"JSON invalido en status_snapshot: {exc}") from exc


def _can_run_delete_without_password() -> bool:
    # Valida que el usuario del servicio pueda ejecutar delete_tenant.sh via sudo sin password.
    # Evitamos encolar un job que sabemos que fallara por permisos.
    cmd = ["sudo", "-n", "-l"]
    result = run(cmd, cwd=str(ROOT_DIR), capture_output=True, text=True, check=False, timeout=6)
    if result.returncode != 0:
        return False

    listing = f"{result.stdout}\n{result.stderr}"
    script_path = re.escape(str(DELETE_SCRIPT))
    rule_re = rf"NOPASSWD:\s*/bin/bash\s+{script_path}(?:\s+\*)?"
    return re.search(rule_re, listing) is not None


def _load_trash_items_unlocked() -> List[dict]:
    if not TRASH_FILE.exists():
        return []

    try:
        payload = json.loads(TRASH_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []

    items = payload.get("items", []) if isinstance(payload, dict) else []
    if not isinstance(items, list):
        return []

    sanitized: List[dict] = []
    for row in items:
        if not isinstance(row, dict):
            continue
        client_id = (row.get("client_id") or "").strip()
        if not CLIENT_ID_RE.fullmatch(client_id):
            continue
        sanitized.append(
            {
                "client_id": client_id,
                "db_name": (row.get("db_name") or "").strip(),
                "moved_at": (row.get("moved_at") or "").strip(),
                "delete_job_id": (row.get("delete_job_id") or "").strip(),
                "delete_requested_at": (row.get("delete_requested_at") or "").strip(),
            }
        )
    return sanitized


def _save_trash_items_unlocked(items: List[dict]) -> None:
    payload = {"items": items}
    tmp_path = TRASH_FILE.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp_path.replace(TRASH_FILE)


def _reconcile_trash_items_unlocked(items: List[dict]) -> List[dict]:
    changed = False
    result: List[dict] = []
    for item in items:
        delete_job_id = (item.get("delete_job_id") or "").strip()
        if not delete_job_id:
            result.append(item)
            continue

        with jobs_lock:
            job = jobs.get(delete_job_id)

        if job and job.status == "success":
            changed = True
            continue

        if job and job.status == "failed":
            item = dict(item)
            item["delete_job_id"] = ""
            item["delete_requested_at"] = ""
            changed = True

        result.append(item)

    if changed:
        _save_trash_items_unlocked(result)
    return result


def _list_trash_items() -> List[dict]:
    with trash_lock:
        items = _load_trash_items_unlocked()
        items = _reconcile_trash_items_unlocked(items)
    return sorted(items, key=lambda x: x.get("moved_at", ""), reverse=True)


def _move_tenant_to_trash(client_id: str, db_name: str) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    with trash_lock:
        items = _load_trash_items_unlocked()
        for item in items:
            if item.get("client_id") == client_id:
                item["db_name"] = db_name or item.get("db_name", "")
                item["moved_at"] = now
                item["delete_job_id"] = ""
                item["delete_requested_at"] = ""
                _save_trash_items_unlocked(items)
                return item

        item = {
            "client_id": client_id,
            "db_name": db_name,
            "moved_at": now,
            "delete_job_id": "",
            "delete_requested_at": "",
        }
        items.append(item)
        _save_trash_items_unlocked(items)
        return item


def _restore_tenant_from_trash(client_id: str) -> bool:
    with trash_lock:
        items = _load_trash_items_unlocked()
        kept: List[dict] = []
        restored = False
        for item in items:
            if item.get("client_id") != client_id:
                kept.append(item)
                continue

            if item.get("delete_job_id"):
                kept.append(item)
                continue

            restored = True

        if restored:
            _save_trash_items_unlocked(kept)
        return restored


def _mark_trash_delete_requested(client_id: str, job_id: str) -> bool:
    now = datetime.now(timezone.utc).isoformat()
    with trash_lock:
        items = _load_trash_items_unlocked()
        found = False
        for item in items:
            if item.get("client_id") == client_id:
                item["delete_job_id"] = job_id
                item["delete_requested_at"] = now
                found = True
                break
        if found:
            _save_trash_items_unlocked(items)
        return found


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


def _redact_command(command: List[str]) -> List[str]:
    redacted = list(command)
    if len(redacted) >= 4 and redacted[0:3] == ["sudo", "-n", "/bin/bash"]:
        script_name = Path(redacted[3]).name
        if script_name in {"create_tenant.sh", "test_tenant_db.sh"} and len(redacted) >= 6:
            redacted[5] = "***REDACTED***"
    return redacted


def _generate_db_password() -> str:
    # 24 chars URL-safe y compatible con DB_PASSWORD_RE.
    return secrets.token_urlsafe(18).replace("-", "A").replace("_", "B")[:24]


def _load_key_value_file(path: Path) -> Dict[str, str]:
  values: Dict[str, str] = {}
  if not path.is_file():
    return values

  try:
    lines = path.read_text(encoding="utf-8").splitlines()
  except OSError:
    return values

  for raw in lines:
    line = raw.strip().rstrip("\r")
    if not line or line.startswith("#") or "=" not in line:
      continue

    key, value = line.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not key:
      continue

    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
      value = value[1:-1]

    values[key] = value

  return values


def _load_monitor_env_values() -> Dict[str, str]:
  monitor_values = _load_key_value_file(MONITOR_ENV_PATH)
  node_values = _load_key_value_file(NODE_ENV_PATH)

  values = dict(monitor_values)
  for key in [
    "ADEMA_NODE_ID",
    "ADEMA_NODE_UUID",
    "ADEMA_NODE_NAME",
    "CLUSTER_ID",
    "PROJECT_CODE",
    "ADEMA_BASE_DOMAIN",
    "ADEMA_INFRA_DOMAIN",
    "ADEMA_DEPLOY_DOMAIN",
    "BACKUP_REMOTE",
  ]:
    if node_values.get(key):
      values[key] = node_values[key]

  if node_values.get("ADEMA_BASE_DOMAIN"):
    values["BASE_DOMAIN"] = node_values["ADEMA_BASE_DOMAIN"]
  return values


def _detect_docker0_ip() -> str:
  try:
    result = run(
      ["ip", "-o", "-4", "addr", "show", "docker0"],
      cwd=str(ROOT_DIR),
      capture_output=True,
      text=True,
      check=False,
      timeout=3,
    )
  except (OSError, TimeoutExpired):
    return ""

  if result.returncode != 0:
    return ""

  line = (result.stdout or "").strip().splitlines()
  if not line:
    return ""

  parts = line[0].split()
  if len(parts) < 4:
    return ""

  return parts[3].split("/", 1)[0].strip()


def _build_connection_bundle(client_id: str, db_password: str) -> Dict[str, str]:
  env_values = _load_monitor_env_values()
  project_code = env_values.get("PROJECT_CODE") or "django"
  db_prefix = env_values.get("DB_PREFIX") or project_code
  db_name_prefix = env_values.get("DB_NAME_PREFIX") or f"{db_prefix}_db"
  db_user_prefix = env_values.get("DB_USER_PREFIX") or f"user_{db_prefix}"
  db_port = (env_values.get("DB_PORT") or "5432").strip() or "5432"
  volume_base_path = env_values.get("VOLUME_BASE_PATH") or "/var/lib/docker/volumes"
  volume_prefix = env_values.get("VOLUME_PREFIX") or db_prefix
  base_domain = env_values.get("BASE_DOMAIN") or env_values.get("ADEMA_BASE_DOMAIN") or ""

  db_host = _detect_docker0_ip()
  if not db_host:
    db_host = (env_values.get("DB_HOST") or "").strip() or "127.0.0.1"

  db_name = f"{db_name_prefix}_{client_id}"
  db_user = f"{db_user_prefix}_{client_id}"
  volume_ns = f"{volume_prefix}_{client_id}"
  encoded_user = urllib.parse.quote(db_user, safe="")
  encoded_password = urllib.parse.quote(db_password, safe="")
  encoded_db = urllib.parse.quote(db_name, safe="")

  return {
    "project_code": project_code,
    "client_id": client_id,
    "db_host": db_host,
    "db_port": db_port,
    "db_name": db_name,
    "db_user": db_user,
    "db_password": db_password,
    "database_url": f"postgresql://{encoded_user}:{encoded_password}@{db_host}:{db_port}/{encoded_db}",
    "django_allowed_hosts": f"{client_id}.{base_domain}" if base_domain else "",
    "media_path": f"{volume_base_path}/{volume_ns}_media",
    "logs_path": f"{volume_base_path}/{volume_ns}_logs",
    "license_path": f"{volume_base_path}/{volume_ns}_license",
  }


def _write_secret_file(secret: str) -> Path:
    fd, path = tempfile.mkstemp(prefix="secret_", suffix=".txt", dir=str(JOBS_DIR))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(secret)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return Path(path)


def _extract_secret_file_path(command: List[str]) -> Optional[Path]:
    try:
        idx = command.index("--password-file")
    except ValueError:
        return None

    if idx + 1 >= len(command):
        return None

    try:
        secret_path = Path(command[idx + 1]).resolve()
    except OSError:
        return None

    if secret_path.parent != JOBS_DIR.resolve() or not secret_path.name.startswith("secret_"):
        return None

    return secret_path


def _enqueue_job(action: str, command: List[str], safe_command: Optional[List[str]] = None) -> Job:
    job_id = uuid.uuid4().hex[:12]
    log_path = JOBS_DIR / f"{job_id}.log"
    now = datetime.now(timezone.utc).isoformat()
    job = Job(
        id=job_id,
        action=f"Adema Core | {action}",
        created_at=now,
        status="queued",
        return_code=None,
        command=safe_command or _redact_command(command),
        log_path=str(log_path),
    )

    with jobs_lock:
        jobs[job_id] = job

    _executor.submit(_run_job_worker, job_id, command)
    return job


def _run_job_worker(job_id: str, exec_command: List[str]) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
    if not job:
        return

    with jobs_lock:
        job.status = "running"

    log_file = Path(job.log_path)
    try:
        with log_file.open("w", encoding="utf-8") as lf:
            lf.write(f"[ADEMA CORE][INFO] Ejecutando: {job.action} (job_id={job_id})\n")
            lf.flush()

            process = Popen(
                exec_command,
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
        app.logger.exception("Fallo ejecutando job %s", job_id)
    finally:
        secret_file = _extract_secret_file_path(exec_command)
        if secret_file and secret_file.exists():
            try:
                secret_file.unlink()
            except OSError:
                app.logger.warning("No se pudo eliminar archivo temporal de secreto: %s", secret_file)


@app.get("/")
def index() -> Response:
    html = """<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Adema Core - Control Center</title>
  <link rel="icon" type="image/x-icon" href="/static/logo/favicon.ico" />
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    :root {
      --adema-navy: #020b1d;
      --adema-ink: #07172f;
      --adema-cyan: #10d5ef;
      --adema-blue: #0667e8;
      --adema-sky: #e7faff;
      --adema-line: #d8e5ef;
      --adema-muted: #63738a;
      --adema-soft: #f7fbfd;
      --adema-danger: #dc2626;
      --adema-warning: #b96507;
      --adema-success: #059669;
      --adema-shadow: 0 18px 46px rgba(4, 19, 39, 0.10);
    }

    * { letter-spacing: 0 !important; }

    body {
      min-height: 100vh;
      background:
        linear-gradient(180deg, rgba(16, 213, 239, 0.15) 0%, rgba(247, 251, 253, 0.96) 36%, #edf3f8 100%),
        linear-gradient(90deg, rgba(6, 103, 232, 0.10), rgba(16, 213, 239, 0.08));
      color: var(--adema-ink);
      font-family: Inter, "Segoe UI", Arial, sans-serif;
    }

    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -1;
      pointer-events: none;
      background-image:
        linear-gradient(90deg, rgba(6, 103, 232, 0.055) 1px, transparent 1px),
        linear-gradient(0deg, rgba(6, 103, 232, 0.045) 1px, transparent 1px);
      background-size: 72px 72px;
      mask-image: linear-gradient(180deg, rgba(0, 0, 0, 0.75), transparent 72%);
    }

    .shell { width: min(1180px, calc(100vw - 32px)); }

    .panel {
      background: rgba(255, 255, 255, 0.92);
      border: 1px solid var(--adema-line);
      border-radius: 8px !important;
      box-shadow: var(--adema-shadow);
      backdrop-filter: blur(10px);
    }

    .brand-header {
      background:
        linear-gradient(135deg, rgba(2, 11, 29, 0.98), rgba(5, 29, 61, 0.96));
      border-color: rgba(16, 213, 239, 0.25);
      color: #fff;
    }

    .brand-mark {
      width: 52px;
      height: 52px;
      object-fit: contain;
      border-radius: 8px;
      filter: drop-shadow(0 8px 18px rgba(16, 213, 239, 0.22));
    }

    .brand-logo-login {
      width: 92px;
      height: 92px;
      object-fit: contain;
      margin: 0 auto;
      border-radius: 8px;
      filter: drop-shadow(0 14px 28px rgba(6, 103, 232, 0.22));
    }

    .brand-title { color: #fff; }
    .brand-subtitle { color: #b9c8da; }
    .section-title { color: var(--adema-ink); font-weight: 800; }
    .muted { color: var(--adema-muted); }

    .metric-card {
      min-height: 96px;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      border-left: 3px solid var(--adema-cyan);
    }

    .metric-label {
      color: var(--adema-muted);
      font-size: 0.72rem;
      font-weight: 800;
      text-transform: uppercase;
    }

    .metric-value {
      color: var(--adema-ink);
      font-size: 1.12rem;
      font-weight: 900;
      overflow-wrap: anywhere;
    }

    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 40px;
      border-radius: 8px !important;
      padding: 0.55rem 1rem;
      font-weight: 800;
      transition: transform 140ms ease, box-shadow 140ms ease, background-color 140ms ease, border-color 140ms ease;
      border: 1px solid transparent;
      white-space: nowrap;
    }

    .btn:hover { transform: translateY(-1px); }
    .btn:disabled { opacity: 0.55; cursor: not-allowed; transform: none; }

    .btn.text-xs {
      min-height: 32px;
      padding: 0.35rem 0.7rem;
    }

    .btn-primary {
      background: linear-gradient(135deg, var(--adema-cyan), var(--adema-blue));
      color: #00142b;
      box-shadow: 0 12px 24px rgba(6, 103, 232, 0.20);
    }

    .btn-dark { background: var(--adema-navy); color: #fff; }
    .btn-dark:hover { background: #09214a; }
    .btn-success { background: var(--adema-success); color: #fff; }
    .btn-success:hover { background: #047857; }
    .btn-warning { background: #f59e0b; color: #291500; }
    .btn-warning:hover { background: #d97706; }
    .btn-danger { background: var(--adema-danger); color: #fff; }
    .btn-danger:hover { background: #b91c1c; }
    .btn-soft { background: #eaf2f9; color: var(--adema-ink); border-color: var(--adema-line); }
    .btn-soft:hover { background: #dceaf5; }

    .input-control,
    input,
    textarea {
      border-radius: 8px !important;
      border: 1px solid var(--adema-line) !important;
      background: #fff;
      color: var(--adema-ink);
      outline: none;
      transition: border-color 140ms ease, box-shadow 140ms ease;
    }

    input:focus,
    textarea:focus {
      border-color: var(--adema-cyan) !important;
      box-shadow: 0 0 0 3px rgba(16, 213, 239, 0.18);
    }

    table { border-collapse: separate; border-spacing: 0; }
    thead tr { color: var(--adema-muted); border-color: var(--adema-line); }
    tbody tr { border-color: #e6eef5; }
    tbody tr:hover { background: rgba(16, 213, 239, 0.055); }

    .trash-panel {
      background: #fffaf0;
      border-color: #f4d69a;
      box-shadow: 0 18px 42px rgba(185, 101, 7, 0.08);
    }

    .trash-panel .section-title { color: #7c3d06; }
    .trash-note { color: #8a4a08; }

    .pill {
      border-radius: 8px;
      padding: 0.25rem 0.55rem;
      font-size: 0.75rem;
      font-weight: 800;
      background: #e7faff;
      color: #075985;
      border: 1px solid rgba(16, 213, 239, 0.30);
    }

    .terminal-panel {
      background: #020b1d;
      color: #ecfeff;
      border-color: rgba(16, 213, 239, 0.22);
    }

    .terminal-output {
      background: #010612;
      border: 1px solid rgba(16, 213, 239, 0.18);
      color: #b9f6ff;
      border-radius: 8px !important;
    }

    .modal-backdrop { background: rgba(2, 11, 29, 0.72); backdrop-filter: blur(6px); }
    .modal-card { border-radius: 8px !important; border: 1px solid var(--adema-line); }

    .rounded-2xl,
    .rounded-xl,
    .rounded { border-radius: 8px !important; }

    @media (max-width: 760px) {
      .shell { width: min(100vw - 24px, 1180px); }
      .brand-header { align-items: flex-start; }
      .brand-mark { width: 44px; height: 44px; }
      .btn { width: 100%; white-space: normal; }
      td .btn { width: auto; }
      th, td { min-width: 120px; }
    }
  </style>
</head>
<body>
  <main class="shell mx-auto p-4 md:p-8 space-y-6">

    <!-- LOGIN: visible por defecto -->
    <section id="loginSection" class="panel max-w-lg mx-auto mt-20 p-8 md:p-10 text-center">
      <div class="mb-5">
        <img src="/static/logo/logo.png" onerror="this.onerror=null;this.src='/static/img/logo_ademasistemas.png';" alt="Adema Core" class="brand-logo-login" />
      </div>
      <h1 class="text-2xl font-black text-slate-900">Adema Core</h1>
      <p class="muted text-sm mt-2 mb-6">Ingresa tu token de acceso para continuar.</p>
      <div class="flex flex-col gap-3">
        <input id="tokenInput" type="password" class="input-control w-full px-3 py-2.5" placeholder="ADEMA_WEB_TOKEN" />
        <button id="saveTokenBtn" class="btn btn-primary">Ingresar</button>
        <p id="loginError" class="text-red-600 text-sm hidden">Token invalido. Verifica e intenta de nuevo.</p>
      </div>
    </section>

    <!-- PANEL: oculto hasta autenticacion -->
    <div id="panelSection" class="hidden space-y-6">
      <header class="panel brand-header p-5 md:p-6 flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div class="flex items-center gap-4">
          <img src="/static/logo/Dise%C3%B1o%20sin%20t%C3%ADtulo%20(26).png" onerror="this.onerror=null;this.src='/static/logo/logo.png';" alt="Adema Core" class="brand-mark" />
          <div>
            <h1 class="brand-title text-2xl md:text-3xl font-black">Adema Core - Control Center</h1>
            <p class="brand-subtitle mt-1 text-sm md:text-base">Centro operativo Adema Core para gestionar nodo Django + PostgreSQL.</p>
          </div>
        </div>
        <button id="logoutBtn" class="btn btn-danger text-sm">Cerrar sesion</button>
      </header>

      <section class="grid md:grid-cols-4 gap-4">
        <article class="panel metric-card p-4">
          <h2 class="metric-label">Host</h2>
          <p id="hostName" class="metric-value">-</p>
        </article>
        <article class="panel metric-card p-4">
          <h2 class="metric-label">RAM</h2>
          <p id="ramUsage" class="metric-value">-</p>
        </article>
        <article class="panel metric-card p-4">
          <h2 class="metric-label">Disco /</h2>
          <p id="diskUsage" class="metric-value">-</p>
        </article>
        <article class="panel metric-card p-4">
          <h2 class="metric-label">Contenedores</h2>
          <p id="containersCount" class="metric-value">-</p>
        </article>
      </section>

      <!-- SECCION: Dominios del nodo -->
      <section id="domainsSection" class="panel p-5 space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <h2 class="section-title text-xl">Dominios del nodo</h2>
          <div class="flex items-center gap-3 flex-wrap">
            <span id="domainLastCheck" class="muted text-xs hidden"></span>
            <button id="checkDomainsBtn" class="btn btn-primary text-sm">Verificar estado</button>
          </div>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <article class="panel metric-card p-3">
            <h3 class="metric-label">Monitor</h3>
            <p id="domInfraDomain" class="metric-value text-sm" style="overflow-wrap:anywhere">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">Deploy</h3>
            <p id="domDeployDomain" class="metric-value text-sm" style="overflow-wrap:anywhere">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">IP publica</h3>
            <p id="domServerIp" class="metric-value text-sm">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">Panel local</h3>
            <p id="domPanelStatus" class="metric-value text-sm">-</p>
          </article>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <article class="panel metric-card p-3">
            <h3 class="metric-label">DNS monitor</h3>
            <p id="domDnsInfra" class="metric-value text-sm">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">DNS deploy</h3>
            <p id="domDnsDeploy" class="metric-value text-sm">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">HTTP 80 / 443</h3>
            <p id="domFirewallHttp" class="metric-value text-sm">-</p>
          </article>
          <article class="panel metric-card p-3">
            <h3 class="metric-label">Proxy</h3>
            <p id="domProxyMode" class="metric-value text-sm">-</p>
          </article>
        </div>
        <p id="domainStatusNote" class="muted text-xs">Haz click en &ldquo;Verificar estado&rdquo; para revisar DNS, firewall, Coolify/Traefik y puertos internos.</p>
      </section>

      <section class="panel p-5 space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <h2 class="section-title text-xl">Gestion de Tenants</h2>
          <button id="backupBtn" class="btn btn-dark">Backup Now</button>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left border-b">
                <th class="py-2">CLIENT_ID</th>
                <th class="py-2">DB</th>
                <th class="py-2">Acciones</th>
              </tr>
            </thead>
            <tbody id="tenantsBody"></tbody>
          </table>
        </div>
        <p class="muted text-xs">Mover a papelera oculta el tenant de esta tabla. El borrado definitivo se hace desde Papelera con confirmacion reforzada.</p>
      </section>

      <section class="panel trash-panel p-5 space-y-4">
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
          <h2 class="section-title text-xl">Papelera de Tenants</h2>
          <span class="pill">doble seguridad</span>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left border-b border-amber-200">
                <th class="py-2">CLIENT_ID</th>
                <th class="py-2">DB</th>
                <th class="py-2">Movido</th>
                <th class="py-2">Acciones</th>
              </tr>
            </thead>
            <tbody id="trashBody"></tbody>
          </table>
        </div>
        <p class="trash-note text-xs">Para borrar definitivo se debe escribir la frase exacta solicitada por el sistema.</p>
      </section>

      <section class="panel p-5 space-y-3">
        <h2 class="section-title text-xl">Formulario de Alta</h2>
        <div class="grid md:grid-cols-3 gap-3">
          <input id="clientIdInput" class="input-control px-3 py-2.5" placeholder="cli001" />
          <input id="clientPassInput" class="input-control px-3 py-2.5" placeholder="DB password opcional" />
          <button id="createTenantBtn" class="btn btn-success">Crear Infraestructura</button>
        </div>
        <p class="muted text-xs">Si no envias password, create_tenant.sh generara una automaticamente.</p>
      </section>

      <section class="panel terminal-panel p-5">
        <div class="flex items-center justify-between gap-3 mb-2">
          <h2 class="text-xl font-bold">Logs en tiempo real</h2>
          <span id="jobStatus" class="pill">sin job activo</span>
        </div>
        <pre id="logOutput" class="terminal-output text-xs whitespace-pre-wrap h-72 overflow-auto p-3"></pre>
      </section>
    </div>

    <div id="deleteTenantModal" class="modal-backdrop hidden fixed inset-0 z-50 p-4">
      <div class="modal-card max-w-lg mx-auto mt-16 md:mt-24 bg-white shadow-2xl">
        <div class="p-5 border-b border-slate-200">
          <h3 class="section-title text-xl">Confirmar Borrado Definitivo</h3>
          <p class="muted text-sm mt-1">Esta accion elimina base de datos, usuario SQL y volumenes del tenant.</p>
        </div>
        <div class="p-5 space-y-4">
          <p class="text-sm text-slate-700">Tenant objetivo: <span id="deleteTenantTarget" class="font-bold">-</span></p>

          <label class="block text-sm font-semibold text-slate-700" for="confirmClientIdInput">Escribe el CLIENT_ID exacto</label>
          <input id="confirmClientIdInput" class="input-control w-full px-3 py-2.5" placeholder="cli001" autocomplete="off" />

          <label class="block text-sm font-semibold text-slate-700" for="confirmPhraseInput">Escribe la frase de confirmacion</label>
          <p class="muted text-xs">Escriba la siguiente frase: <span id="deletePhraseHint" class="font-bold text-slate-900">BORRAR TENANT</span></p>
          <input id="confirmPhraseInput" class="input-control w-full px-3 py-2.5" placeholder="BORRAR TENANT" autocomplete="off" />

          <p id="deleteModalError" class="text-sm text-red-600 hidden"></p>
        </div>
        <div class="p-5 border-t border-slate-200 flex items-center justify-end gap-2">
          <button id="cancelDeleteBtn" class="btn btn-soft">Cancelar</button>
          <button id="confirmDeleteBtn" class="btn btn-danger">Eliminar definitivo</button>
        </div>
      </div>
    </div>

    <div id="connectionInfoModal" class="modal-backdrop hidden fixed inset-0 z-50 p-4">
      <div class="modal-card max-w-xl mx-auto mt-16 md:mt-24 bg-white shadow-2xl">
        <div class="p-5 border-b border-slate-200">
          <h3 class="section-title text-xl">Credenciales de Conexion</h3>
          <p class="muted text-sm mt-1">Guarda este dato ahora. No se mostrara nuevamente en el historial.</p>
        </div>
        <div class="p-5 space-y-3">
          <p class="text-sm text-slate-700">Tenant: <span id="connectionClientId" class="font-bold">-</span></p>
          <textarea id="connectionInfoText" readonly class="input-control w-full h-52 px-3 py-2 text-sm font-mono bg-slate-50"></textarea>
        </div>
        <div class="p-5 border-t border-slate-200 flex items-center justify-end gap-2">
          <button id="downloadConnectionBtn" class="btn btn-success">Descargar .txt</button>
          <button id="closeConnectionBtn" class="btn btn-soft">Cerrar</button>
        </div>
      </div>
    </div>

  </main>

  <script>
    let activeJobId = null;
    let activeOffset = 0;
    let healthInterval = null;
    let trashedClientIds = new Set();
    let deleteConfirmText = "BORRAR TENANT";
    let requireDeleteClientId = true;
    let lastHealthData = null;
    let pendingDeleteClientId = null;
    let connectionBundle = null;

    const loginSection = document.getElementById("loginSection");
    const panelSection = document.getElementById("panelSection");
    const loginError = document.getElementById("loginError");
    const deleteTenantModal = document.getElementById("deleteTenantModal");
    const deleteTenantTarget = document.getElementById("deleteTenantTarget");
    const confirmClientIdInput = document.getElementById("confirmClientIdInput");
    const confirmPhraseInput = document.getElementById("confirmPhraseInput");
    const deletePhraseHint = document.getElementById("deletePhraseHint");
    const deleteModalError = document.getElementById("deleteModalError");
    const confirmDeleteBtn = document.getElementById("confirmDeleteBtn");
    const connectionInfoModal = document.getElementById("connectionInfoModal");
    const connectionClientId = document.getElementById("connectionClientId");
    const connectionInfoText = document.getElementById("connectionInfoText");

    function buildConnectionText(bundle) {
      return [
        "Adema Core - Datos de conexion tenant",
        "====================================",
        `CLIENT_ID=${bundle.client_id || ""}`,
        `DB_HOST=${bundle.db_host || ""}`,
        `DB_PORT=${bundle.db_port || "5432"}`,
        `DB_NAME=${bundle.db_name || ""}`,
        `DB_USER=${bundle.db_user || ""}`,
        `DB_PASSWORD=${bundle.db_password || ""}`,
        `DATABASE_URL=${bundle.database_url || ""}`,
        `DJANGO_ALLOWED_HOSTS=${bundle.django_allowed_hosts || ""}`,
        `MEDIA_PATH=${bundle.media_path || ""}`,
        `LOGS_PATH=${bundle.logs_path || ""}`,
        `LICENSE_PATH=${bundle.license_path || ""}`,
      ].join("\\n");
    }

    function closeConnectionModal() {
      connectionBundle = null;
      connectionInfoText.value = "";
      connectionClientId.textContent = "-";
      connectionInfoModal.classList.add("hidden");
    }

    function openConnectionModal(bundle) {
      if (!bundle) return;
      connectionBundle = bundle;
      connectionClientId.textContent = bundle.client_id || "-";
      connectionInfoText.value = buildConnectionText(bundle);
      connectionInfoModal.classList.remove("hidden");
    }

    function downloadConnectionTxt() {
      if (!connectionBundle) return;
      const filenameBase = (connectionBundle.client_id || "tenant").replace(/[^a-zA-Z0-9_-]/g, "_");
      const blob = new Blob([buildConnectionText(connectionBundle) + "\\n"], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `${filenameBase}_db_connection.txt`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    }

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
      const contentType = (res.headers.get("content-type") || "").toLowerCase();
      let payload = null;
      let textPayload = "";

      if (contentType.includes("application/json")) {
        payload = await res.json();
      } else {
        textPayload = await res.text();
      }

      if (!res.ok) {
        const message = payload?.error || payload?.message || textPayload || `HTTP ${res.status}`;
        const e = new Error(message);
        e.status = res.status;
        e.payload = payload;
        throw e;
      }
      return payload !== null ? payload : {};
    }

    function showDeleteModalError(msg) {
      deleteModalError.textContent = msg;
      deleteModalError.classList.remove("hidden");
    }

    function clearDeleteModalError() {
      deleteModalError.textContent = "";
      deleteModalError.classList.add("hidden");
    }

    function closeDeleteModal() {
      pendingDeleteClientId = null;
      confirmClientIdInput.value = "";
      confirmPhraseInput.value = "";
      clearDeleteModalError();
      deleteTenantModal.classList.add("hidden");
    }

    function openDeleteModal(clientId) {
      pendingDeleteClientId = clientId;
      deleteTenantTarget.textContent = clientId;
      deletePhraseHint.textContent = deleteConfirmText;
      confirmClientIdInput.value = "";
      confirmPhraseInput.value = "";
      confirmPhraseInput.placeholder = deleteConfirmText;
      clearDeleteModalError();
      deleteTenantModal.classList.remove("hidden");
      setTimeout(() => confirmClientIdInput.focus(), 0);
    }

    async function submitDeleteModal() {
      if (!pendingDeleteClientId) return;

      const typedClientId = confirmClientIdInput.value.trim();
      const typedPhrase = confirmPhraseInput.value.trim();

      if (requireDeleteClientId && typedClientId !== pendingDeleteClientId) {
        showDeleteModalError("CLIENT_ID incorrecto. Debe coincidir exactamente.");
        return;
      }
      if (typedPhrase !== deleteConfirmText) {
        showDeleteModalError(`Frase incorrecta. Debes escribir exactamente: ${deleteConfirmText}`);
        return;
      }

      confirmDeleteBtn.disabled = true;
      try {
        const resp = await api("/api/tenant/delete-permanent", {
          method: "POST",
          body: JSON.stringify({
            client_id: pendingDeleteClientId,
            confirm_text: typedPhrase,
            confirm_client_id: typedClientId || pendingDeleteClientId,
          })
        });
        closeDeleteModal();
        await refreshTrash();
        activateJob(resp.job_id);
      } catch (err) {
        showDeleteModalError(err.message || "No se pudo iniciar el borrado definitivo.");
      } finally {
        confirmDeleteBtn.disabled = false;
      }
    }

    function escapeHtml(value) {
      return String(value || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/\"/g, "&quot;")
        .replace(/'/g, "&#39;");
    }

    function renderTenantsTable() {
      const databases = (lastHealthData?.databases || []).filter((db) => {
        const cid = (db.client_id || "").trim();
        return cid && !trashedClientIds.has(cid);
      });

      const rows = databases.map((db) => {
        const cid = escapeHtml(db.client_id || "");
        const dbName = escapeHtml(db.db_name || "");
        return `<tr class="border-b"><td class="py-2 font-semibold">${cid}</td><td class="py-2">${dbName}</td><td class="py-2 flex flex-wrap gap-2"><button class="btn btn-dark text-xs min-h-0 py-1 test-db" data-client="${cid}">Test DB</button><button class="btn btn-warning text-xs min-h-0 py-1 move-trash" data-client="${cid}" data-db="${dbName}">Mover a papelera</button></td></tr>`;
      }).join("");

      document.getElementById("tenantsBody").innerHTML = rows || '<tr><td colspan="3" class="py-3 muted">No hay tenants detectados.</td></tr>';

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

      document.querySelectorAll(".move-trash").forEach((btn) => {
        btn.addEventListener("click", async () => {
          const clientId = btn.dataset.client;
          const dbName = btn.dataset.db || "";
          const ok = confirm(`Se movera ${clientId} a la papelera. No se borra aun. Continuar?`);
          if (!ok) return;
          await api("/api/tenant/trash", {
            method: "POST",
            body: JSON.stringify({ client_id: clientId, db_name: dbName })
          });
          await refreshTrash();
          renderTenantsTable();
        });
      });
    }

    function renderTrash(items) {
      const rows = (items || []).map((item) => {
        const cid = escapeHtml(item.client_id || "");
        const dbName = escapeHtml(item.db_name || "-");
        const moved = item.moved_at ? new Date(item.moved_at).toLocaleString("es-AR") : "-";
        const status = item.delete_job_id
          ? `<span class="pill">eliminando...</span>`
          : "";
        return `<tr class="border-b border-amber-200"><td class="py-2 font-semibold">${cid}</td><td class="py-2">${dbName}</td><td class="py-2">${escapeHtml(moved)}</td><td class="py-2 flex flex-wrap gap-2"><button class="btn btn-success text-xs min-h-0 py-1 restore-tenant" data-client="${cid}" ${item.delete_job_id ? "disabled" : ""}>Restaurar</button><button class="btn btn-danger text-xs min-h-0 py-1 delete-tenant" data-client="${cid}" ${item.delete_job_id ? "disabled" : ""}>Borrar definitivo</button>${status}</td></tr>`;
      }).join("");

      document.getElementById("trashBody").innerHTML = rows || '<tr><td colspan="4" class="py-3 trash-note">La papelera esta vacia.</td></tr>';

      document.querySelectorAll(".restore-tenant").forEach((btn) => {
        btn.addEventListener("click", async () => {
          const clientId = btn.dataset.client;
          await api("/api/tenant/restore", {
            method: "POST",
            body: JSON.stringify({ client_id: clientId })
          });
          await refreshTrash();
          renderTenantsTable();
        });
      });

      document.querySelectorAll(".delete-tenant").forEach((btn) => {
        btn.addEventListener("click", async () => {
          const clientId = btn.dataset.client;
          openDeleteModal(clientId);
        });
      });
    }

    function renderHealth(data) {
      lastHealthData = data;
      const host = data.host || {};
      document.getElementById("hostName").textContent = host.hostname || "-";
      const ram = host.ram || {};
      document.getElementById("ramUsage").textContent = `${ram.used_mb || 0} / ${ram.total_mb || 0} MB`;
      document.getElementById("diskUsage").textContent = host.disk_root_usage || "-";
      const containers = data.containers || {};
      document.getElementById("containersCount").textContent = containers.running || 0;
      renderTenantsTable();
    }

    async function refreshTrash() {
      const data = await api("/api/tenant/trash");
      const items = data.items || [];
      deleteConfirmText = (data.confirm_text || "BORRAR TENANT").trim() || "BORRAR TENANT";
      deletePhraseHint.textContent = deleteConfirmText;
      confirmPhraseInput.placeholder = deleteConfirmText;
      requireDeleteClientId = data.require_client_id !== false;
      trashedClientIds = new Set(items.map((item) => (item.client_id || "").trim()).filter(Boolean));
      renderTrash(items);
    }

    async function refreshHealth() {
      try {
        const data = await api("/api/health");
        renderHealth(data);
      } catch (err) {
        if (err.status === 401) {
          localStorage.removeItem("adema_token");
          showLogin();
          loginError.classList.remove("hidden");
          loginError.textContent = "Sesion expirada o token invalido.";
          return;
        }

        document.getElementById("hostName").textContent = "error de backend";
        document.getElementById("ramUsage").textContent = "-";
        document.getElementById("diskUsage").textContent = "-";
        document.getElementById("containersCount").textContent = "-";
        document.getElementById("tenantsBody").innerHTML = '<tr><td colspan="3" class="py-3 muted">Sin datos de backend.</td></tr>';
      }
    }

    async function refreshPanelData() {
      await refreshHealth();
      try {
        await refreshTrash();
      } catch (err) {
        if (err.status === 401) {
          localStorage.removeItem("adema_token");
          showLogin();
          loginError.classList.remove("hidden");
          loginError.textContent = "Sesion expirada o token invalido.";
          return;
        }
      }
      renderTenantsTable();
    }

    async function tryLogin(tokenOverride = null) {
      const t = (tokenOverride ?? document.getElementById("tokenInput").value).trim();
      if (!t) return;
      setToken(t);
      try {
        await api("/api/auth/check");
        showPanel();
        await refreshPanelData();
        healthInterval = setInterval(refreshPanelData, 15000);
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
        } else {
          setTimeout(refreshPanelData, 800);
        }
      } catch (err) {
        document.getElementById("jobStatus").textContent = "error leyendo log";
      }
    }

    document.getElementById("saveTokenBtn").addEventListener("click", () => tryLogin());
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

      if (resp.connection_bundle) {
        openConnectionModal(resp.connection_bundle);
      }

      activateJob(resp.job_id);
      setTimeout(refreshPanelData, 3000);
    });

    document.getElementById("backupBtn").addEventListener("click", async () => {
      const resp = await api("/api/backup/now", {
        method: "POST",
        body: JSON.stringify({})
      });
      activateJob(resp.job_id);
    });

    document.getElementById("cancelDeleteBtn").addEventListener("click", closeDeleteModal);
    confirmDeleteBtn.addEventListener("click", submitDeleteModal);
    confirmPhraseInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") submitDeleteModal();
    });
    confirmClientIdInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") submitDeleteModal();
    });
    deleteTenantModal.addEventListener("click", (e) => {
      if (e.target === deleteTenantModal) closeDeleteModal();
    });
    document.getElementById("downloadConnectionBtn").addEventListener("click", downloadConnectionTxt);
    document.getElementById("closeConnectionBtn").addEventListener("click", closeConnectionModal);
    connectionInfoModal.addEventListener("click", (e) => {
      if (e.target === connectionInfoModal) closeConnectionModal();
    });

    // ── Dominios del nodo ──────────────────────────────────────────────────
    function domBadge(isOk, labelOk, labelFail) {
      const color = isOk ? 'var(--adema-success)' : 'var(--adema-danger)';
      return `<span style="color:${color};font-weight:900">${isOk ? escapeHtml(labelOk) : escapeHtml(labelFail)}</span>`;
    }

    async function refreshDomainStatus() {
      const btn = document.getElementById('checkDomainsBtn');
      const note = document.getElementById('domainStatusNote');
      btn.disabled = true;
      btn.textContent = 'Verificando...';
      note.textContent = 'Consultando...';

      try {
        const data = await api('/api/domain/status');

        document.getElementById('domInfraDomain').textContent  = data.monitor_domain || data.infra_domain || '-';
        document.getElementById('domDeployDomain').textContent = data.deploy_domain || '-';
        document.getElementById('domServerIp').textContent     = data.server_ip     || '-';

        const panelOk = data.panel?.responding === true;
        document.getElementById('domPanelStatus').innerHTML = domBadge(panelOk, 'Activo', 'Sin respuesta');

        const dnsInfraOk   = (data.dns?.monitor_points_to_server ?? data.dns?.infra_points_to_server) === true;
        const dnsDeployOk  = data.dns?.deploy_points_to_server === true;
        const dnsInfraProxy  = (data.dns?.monitor_via_proxy ?? data.dns?.infra_via_proxy) === true;
        const dnsDeployProxy = data.dns?.deploy_via_proxy === true;
        const dnsInfraLabel  = dnsInfraOk  ? 'OK' : (dnsInfraProxy  ? 'OK (vía CDN)' : 'Pendiente');
        const dnsDeployLabel = dnsDeployOk ? 'OK' : (dnsDeployProxy ? 'OK (vía CDN)' : 'Pendiente');
        document.getElementById('domDnsInfra').innerHTML  = domBadge(dnsInfraOk  || dnsInfraProxy,  dnsInfraLabel,  dnsInfraLabel);
        document.getElementById('domDnsDeploy').innerHTML = domBadge(dnsDeployOk || dnsDeployProxy, dnsDeployLabel, dnsDeployLabel);

        const httpOk  = data.firewall?.http_open  === true;
        const httpsOk = data.firewall?.https_open === true;
        const fwLabel = (httpOk && httpsOk) ? '80 + 443' : (!httpOk && !httpsOk ? 'Cerrado' : (httpOk ? '80 ok / 443 cerrado' : '80 cerrado / 443 ok'));
        document.getElementById('domFirewallHttp').innerHTML = domBadge(httpOk && httpsOk, fwLabel, fwLabel);

        const proxy = data.proxy?.detected || '';
        const proxyLabels = {
          'coolify-traefik': 'Coolify/Traefik',
          coolify: 'Coolify/Traefik',
          caddy: 'Caddy (no recomendado)',
          nginx: 'Nginx host activo',
          free: '80/443 libres'
        };
        const proxyLabel  = proxyLabels[proxy] || (proxy || '-');
        const proxyOk     = data.proxy?.ok === true || proxy === 'coolify-traefik' || proxy === 'coolify';
        document.getElementById('domProxyMode').innerHTML = domBadge(proxyOk, proxyLabel, proxyLabel);

        note.textContent = data.ok
          ? 'Nodo listo: Cloudflare DNS -> Coolify/Traefik -> apps.'
          : 'Requiere accion. Revisar UFW, Coolify/Traefik, Nginx host y puertos internos.';

        const lastCheckEl = document.getElementById('domainLastCheck');
        lastCheckEl.textContent = `Ultima verificacion: ${new Date().toLocaleTimeString('es-AR')}`;
        lastCheckEl.classList.remove('hidden');

      } catch (err) {
        if (err.status === 404 || (err.message || '').includes('script_not_found')) {
          note.textContent = 'setup_domains.sh no encontrado. Asegurate de usar el repositorio completo.';
        } else if (err.status === 401) {
          localStorage.removeItem('adema_token');
          showLogin();
        } else {
          note.textContent = `Error al verificar: ${err.message || 'sin detalle'}`;
        }
      } finally {
        btn.disabled = false;
        btn.textContent = 'Verificar estado';
      }
    }

    document.getElementById('checkDomainsBtn').addEventListener('click', refreshDomainStatus);

    // Auto-login solo desde almacenamiento local. Token por query string queda deshabilitado por seguridad.
    if (new URLSearchParams(window.location.search).get("token")) {
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
@limiter.limit("10 per minute")
def api_health() -> Response:
    try:
        snapshot = _run_snapshot()
        return jsonify(snapshot)
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500


@app.get("/healthz")
def healthz() -> Response:
    return jsonify({"ok": True, "service": "adema-monitor"})


@app.get("/api/auth/check")
@limiter.limit("10 per minute")
def api_auth_check() -> Response:
    # Si el request llega aqui, el token ya fue validado en before_request.
    return jsonify({"ok": True})


@app.post("/api/tenant/create")
def api_create_tenant() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
        db_password = (payload.get("db_password") or "").strip()
        if db_password:
            db_password = _ensure_password(db_password)
        else:
            db_password = _ensure_password(_generate_db_password())

        secret_file = _write_secret_file(db_password)

        command = [
            "sudo",
            "-n",
            "/bin/bash",
            str(CREATE_SCRIPT),
            client_id,
          "--password-file",
          str(secret_file),
            "--no-password-output",
        ]

        job = _enqueue_job("create_tenant", command)
        bundle = _build_connection_bundle(client_id, db_password)
        return jsonify({
            "ok": True,
            "job_id": job.id,
            "db_password_once": db_password,
            "connection_bundle": bundle,
        })
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


@app.get("/api/tenant/trash")
def api_tenant_trash() -> Response:
    items = _list_trash_items()
    return jsonify({"items": items, "confirm_text": DELETE_CONFIRM_TEXT, "require_client_id": True})


@app.post("/api/tenant/trash")
def api_move_tenant_to_trash() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
        db_name = (payload.get("db_name") or "").strip()
        item = _move_tenant_to_trash(client_id, db_name)
        return jsonify({"ok": True, "item": item})
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400


@app.post("/api/tenant/restore")
def api_restore_tenant_from_trash() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
        if _restore_tenant_from_trash(client_id):
            return jsonify({"ok": True})
        return jsonify({"error": "tenant_no_encontrado_en_papelera_o_en_borrado"}), 404
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400


@app.post("/api/tenant/delete-permanent")
def api_delete_tenant_permanent() -> Response:
    payload = request.get_json(silent=True) or {}
    try:
        client_id = _ensure_client_id(payload.get("client_id", ""))
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    confirm_text = (payload.get("confirm_text") or "").strip()
    if confirm_text != DELETE_CONFIRM_TEXT:
        return jsonify({"error": f"confirmacion_invalida. Debe escribir exactamente: {DELETE_CONFIRM_TEXT}"}), 400

    confirm_client_id = _ensure_client_id(payload.get("confirm_client_id", ""))
    if confirm_client_id != client_id:
        return jsonify({"error": "confirmacion_client_id_invalida. Debe escribir el CLIENT_ID exacto."}), 400

    items = _list_trash_items()
    if not any(item.get("client_id") == client_id for item in items):
        return jsonify({"error": "tenant_no_esta_en_papelera"}), 409

    if not _can_run_delete_without_password():
        return jsonify(
            {
                "error": "Permisos incompletos para borrar tenant. Ejecuta una vez: sudo bash /opt/adema-node/setup_web_panel.sh",
                "error_code": "delete_sudoers_missing",
            }
        ), 503

    command = ["sudo", "-n", "/bin/bash", str(DELETE_SCRIPT), client_id, "--force"]
    job = _enqueue_job("delete_tenant_permanent", command)
    _mark_trash_delete_requested(client_id, job.id)
    return jsonify({"ok": True, "job_id": job.id})


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


@app.get("/api/domain/status")
@limiter.limit("6 per minute")
def api_domain_status() -> Response:
    if not SETUP_DOMAINS_SCRIPT.exists():
        return jsonify({
            "ok": False,
            "error": "script_not_found",
            "message": (
                f"setup_domains.sh no encontrado en {SETUP_DOMAINS_SCRIPT}. "
                "Asegurate de clonar el repo completo y ejecutar desde la raiz correcta."
            ),
        }), 404

    env = dict(os.environ)
    if BASE_DOMAIN:
        env["BASE_DOMAIN"] = BASE_DOMAIN
    if ADEMA_INFRA_DOMAIN:
        env["ADEMA_INFRA_DOMAIN"] = ADEMA_INFRA_DOMAIN
    if ADEMA_DEPLOY_DOMAIN:
        env["ADEMA_DEPLOY_DOMAIN"] = ADEMA_DEPLOY_DOMAIN
    if MONITOR_DOMAIN:
        env["MONITOR_DOMAIN"] = MONITOR_DOMAIN
        env["ADEMA_INFRA_DOMAIN"] = MONITOR_DOMAIN
    if COOLIFY_DOMAIN:
        env["COOLIFY_DOMAIN"] = COOLIFY_DOMAIN
        env["ADEMA_DEPLOY_DOMAIN"] = COOLIFY_DOMAIN
    env["PUBLIC_PROXY_MODE"] = "coolify-traefik"

    try:
        result = run(
            ["sudo", "-n", "/bin/bash", str(SETUP_DOMAINS_SCRIPT), "--check", "--json"],
            cwd=str(ROOT_DIR),
            capture_output=True,
            text=True,
            check=False,
            timeout=45,
            env=env,
        )
    except TimeoutExpired:
        return jsonify({"ok": False, "error": "timeout", "message": "El chequeo de dominios tardo demasiado (>45s)."}), 504
    except OSError as exc:
        return jsonify({"ok": False, "error": "exec_error", "message": str(exc)}), 500

    if result.returncode != 0:
        raw = (result.stdout or result.stderr or "").strip()
        # Intentar parsear JSON de error devuelto por el script
        try:
            data = json.loads(raw)
            return jsonify(data), 500
        except json.JSONDecodeError:
            pass
        return jsonify({"ok": False, "error": "check_failed", "message": raw[:500] or "El script de dominios fallo."}), 500

    try:
        data = json.loads(result.stdout)
        return jsonify(data)
    except json.JSONDecodeError:
        return jsonify({
            "ok": False,
            "error": "json_parse_error",
            "message": "El script no devolvio JSON valido.",
            "raw": result.stdout[:500],
        }), 500


if __name__ == "__main__":
    app.run(host=HOST, port=PORT)
