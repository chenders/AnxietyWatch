FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8080

# Install cron for ResMed sync (hourly schedule check)
RUN apt-get update && apt-get install -y --no-install-recommends cron && rm -rf /var/lib/apt/lists/*
COPY resmed-cron /etc/cron.d/resmed-sync
RUN chmod 0644 /etc/cron.d/resmed-sync
COPY walgreens-cron /etc/cron.d/walgreens-sync
RUN chmod 0644 /etc/cron.d/walgreens-sync

CMD ["sh", "-c", "cron && exec gunicorn --bind 0.0.0.0:8080 --workers 2 --access-logfile - 'server:create_app()'"]
