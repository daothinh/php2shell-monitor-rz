FROM python:3.12-slim

# tzdata: để ZoneInfo("Asia/Ho_Chi_Minh") hoạt động (slim không kèm sẵn)
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=Asia/Ho_Chi_Minh

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# chạy non-root; compose map user 1000:1000 để file trên host thuộc gaban
RUN useradd --uid 1000 --user-group --no-create-home --shell /usr/sbin/nologin app \
 && mkdir -p /data && chown -R 1000:1000 /srv /data
USER 1000:1000

ENV ALERT_DB_PATH=/data/alerts.db \
    ALERT_EVIDENCE_ROOT=/data/evidence

VOLUME /data
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/v1/healthz', timeout=3).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
