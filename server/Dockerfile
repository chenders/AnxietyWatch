FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN playwright install --with-deps chromium && playwright install --with-deps chrome

COPY . .

EXPOSE 8080

# cron for scheduled jobs, xvfb+xauth for headed Chrome without a display
RUN apt-get update && apt-get install -y --no-install-recommends cron xvfb xauth && rm -rf /var/lib/apt/lists/*
COPY resmed-cron /etc/cron.d/resmed-sync
RUN chmod 0644 /etc/cron.d/resmed-sync
COPY caprx-cron /etc/cron.d/caprx-sync
RUN chmod 0644 /etc/cron.d/caprx-sync

CMD ["sh", "-c", "cron && exec gunicorn --bind 0.0.0.0:8080 --workers 2 --access-logfile - 'server:create_app()'"]
