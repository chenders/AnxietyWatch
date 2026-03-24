# AnxietyWatch Server Setup Guide

Deploy the AnxietyWatch sync server on **megadude**.

## Prerequisites

- Server running Ubuntu 24.04 with Docker and systemd
- SSH access as `deploy` user
- GitHub fine-grained PAT for the AnxietyWatch repo

## Port Allocation

Both projects share the server with no port conflicts:

| Service | Host Port | Project |
|---------|-----------|---------|
| anxietywatch app | 8081 | anxietywatch |
| anxietywatch postgres | 5439 | anxietywatch |

## Server-Side Setup

### 1. Create Directories

```bash
sudo mkdir -p /opt/anxietywatch /opt/github-runners-anxietywatch
sudo chown deploy:deploy /opt/anxietywatch /opt/github-runners-anxietywatch
```

### 2. Create Systemd Services

**AnxietyWatch app service:**

```bash
sudo tee /etc/systemd/system/anxietywatch.service << 'EOF'
[Unit]
Description=AnxietyWatch Sync Server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=deploy
Group=docker
WorkingDirectory=/opt/anxietywatch
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/bin/sh -c '/usr/bin/docker compose pull && /usr/bin/docker compose up -d'

[Install]
WantedBy=multi-user.target
EOF
```

**GitHub runner service:**

```bash
sudo tee /etc/systemd/system/github-runners-anxietywatch.service << 'EOF'
[Unit]
Description=GitHub Actions Runners (AnxietyWatch)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=deploy
Group=docker
WorkingDirectory=/opt/github-runners-anxietywatch
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/bin/sh -c '/usr/bin/docker compose pull && /usr/bin/docker compose up -d'

[Install]
WantedBy=multi-user.target
EOF
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

### 3. Open Firewall Port

AnxietyWatch is LAN-only (no Cloudflare Tunnel). Open port 8081 for the iOS app, restricted to your LAN (replace the CIDR with your actual subnet):

```bash
sudo ufw allow from 192.168.1.0/24 to any port 8081 proto tcp comment 'AnxietyWatch sync server (LAN only)'
```

### 4. Create GitHub PAT for Runner

1. GitHub → Settings → Developer settings → Fine-grained tokens
2. **Token name:** `anxietywatch-runners`
3. **Repository:** `chenders/AnxietyWatch`
4. **Permission:** Administration (Read and write)
5. **Expiration:** 90 days — set a calendar reminder to renew
6. Generate and save the token

### 5. Bootstrap Runner

Copy runner config files to the server:

```bash
# From your local machine:
scp docker-compose.runners.yml deploy@megadude:/opt/github-runners-anxietywatch/docker-compose.yml
scp .env.runners.example deploy@megadude:/opt/github-runners-anxietywatch/.env.example
```

On the server, create the `.env` file:

```bash
cd /opt/github-runners-anxietywatch
cp .env.example .env
# Edit .env: set ACCESS_TOKEN to the PAT from step 4
nano .env
chmod 600 .env
```

Start the runner:

```bash
sudo systemctl enable --now github-runners-anxietywatch
```

Verify it appears in GitHub: Repository → Settings → Actions → Runners (should show "Idle").

### 6. Add GitHub Repository Secrets

In the AnxietyWatch repo (Settings → Secrets and variables → Actions), add:

| Secret | Description |
|--------|-------------|
| `ANXIETYWATCH_ADMIN_PASSWORD` | Admin UI login password |
| `ANXIETYWATCH_SECRET_KEY` | Flask session secret (random string) |
| `ANXIETYWATCH_DB_PASSWORD` | PostgreSQL password |

Generate strong random values:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

### 7. First Deploy

Either push a change to `server/**` on main, or trigger manually:

```bash
gh workflow run deploy.yml
```

Or bootstrap manually:

**From your local machine** — copy the compose file to the server:

```bash
scp server/docker-compose.prod.yml deploy@megadude:/opt/anxietywatch/docker-compose.yml
```

**On the server** — create the .env and start the app:

```bash
cd /opt/anxietywatch

# Create .env manually (use the same values as the GitHub secrets)
nano .env

# Start
docker compose pull
docker compose up -d
sudo systemctl enable anxietywatch
```

### 8. Create API Key

1. Open `http://megadude:8081/admin`
2. Log in with the `ANXIETYWATCH_ADMIN_PASSWORD`
3. Create a new API key — save the token (shown only once)
4. Configure the iOS app's SyncService with this token

## Verification

```bash
# Check containers are running
docker compose -f /opt/anxietywatch/docker-compose.yml ps

# Health check
curl http://megadude:8081/health

# Check runner status
docker ps | grep anxietywatch-runner
```

## Maintenance

### View Logs

```bash
# App logs
docker compose -f /opt/anxietywatch/docker-compose.yml logs -f anxietywatch-app

# Database logs
docker compose -f /opt/anxietywatch/docker-compose.yml logs -f anxietywatch-db

# Runner logs
docker compose -f /opt/github-runners-anxietywatch/docker-compose.yml logs -f
```

### Restart Services

```bash
sudo systemctl restart anxietywatch
sudo systemctl restart github-runners-anxietywatch
```

### Runner Token Renewal

The GitHub PAT expires every 90 days. To renew:

1. Generate a new fine-grained PAT (same settings as step 4)
2. Update `/opt/github-runners-anxietywatch/.env` with the new `ACCESS_TOKEN`
3. Restart: `sudo systemctl restart github-runners-anxietywatch`
4. Verify the runner reconnects in GitHub Settings → Actions → Runners

### Docker Cleanup

```bash
# Remove unused images
docker image prune -a

# Full cleanup (images, containers, volumes, networks)
docker system prune -a
```

## Troubleshooting

### App not accessible

```bash
# Check containers
docker compose -f /opt/anxietywatch/docker-compose.yml ps

# Check logs for errors
docker compose -f /opt/anxietywatch/docker-compose.yml logs --tail=50

# Check firewall
sudo ufw status | grep 8081

# Test locally on server
curl http://localhost:8081/health
```

### Runner not picking up jobs

```bash
# Check runner is running
docker ps | grep anxietywatch-runner

# Check runner logs
docker logs anxietywatch-runner-1 --tail=50

# Verify token hasn't expired
# Check GitHub → Settings → Actions → Runners for status
```

### Database connection issues

```bash
# Check db container health
docker inspect anxietywatch-db --format='{{.State.Health.Status}}'

# Connect to database directly
docker exec -it anxietywatch-db psql -U anxietywatch

# Check .env has correct credentials
cat /opt/anxietywatch/.env
```
