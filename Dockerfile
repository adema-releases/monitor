FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ADEMA_WEB_HOST=0.0.0.0 \
    ADEMA_WEB_PORT=5000 \
    ADEMA_MONITOR_DIR=/app/monitor \
    MONITOR_ENV_FILE=/app/monitor/.monitor.env

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x run_monitor.sh monitor/*.sh scripts/*.sh 2>/dev/null || true \
    && mkdir -p /app/.web_jobs

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:5000/healthz || exit 1

CMD ["waitress-serve", "--listen=0.0.0.0:5000", "web_manager:app"]