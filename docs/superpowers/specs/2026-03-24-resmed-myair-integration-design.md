# ResMed myAir Cloud Integration — Design Spec

## Problem

CPAP session data currently requires manual CSV import from the AirSense 11 SD card. This is friction-heavy and means data is often days or weeks stale. The ResMed myAir cloud service receives daily session summaries automatically from the device — integrating with it would provide near-automatic daily CPAP data without touching the SD card.

## Constraints

- The myAir API is **reverse-engineered** (not officially supported by ResMed). It can break at any time.
- Cloud data is **less detailed** than SD card: no obstructive/central/hypopnea event breakdown, no min/max pressure.
- Data updates **once per day**, typically 12–24 hours after the therapy session.
- Regional limitations: does not work in France (2FA required), untested in Asia.

## Architecture

Server-side integration (Python). The server polls myAir daily, stores results in PostgreSQL, and the iOS app picks up CPAP data through the existing `GET /api/data` endpoint (no new endpoint needed — cloud-synced rows appear in `cpap_sessions` like any other).

```
myAir Cloud → server/resmed_client.py → PostgreSQL (cpap_sessions) → GET /api/data → iOS app
```

Credentials are stored encrypted in a `settings` table, managed via the admin UI. This keeps credentials off the iOS device and makes it easy to fix the integration when the API changes (server-side fix, no app rebuild).

## Components

### 1. `server/resmed_client.py` — myAir API Client

Thin wrapper around the reverse-engineered myAir API.

**Responsibilities:**
- Authenticate with email/password
- Fetch daily session summaries (most recent N days)
- Return structured data (list of dicts)

**Interface:**
```python
class MyAirClient:
    def __init__(self, email: str, password: str):
        ...

    def fetch_sessions(self, days: int = 7) -> list[dict]:
        """Returns list of daily session summaries for the last N days.
        Each dict contains: date, ahi, usage_minutes, leak_percent, mean_pressure (if available).
        Use days=365 for initial historical backfill.
        Raises MyAirAuthError on auth failure, MyAirAPIError on unexpected responses.
        """
```

**Dependencies:** `requests`, `cryptography` (add to requirements.txt with version pins). No dependency on `myair-py` — implement directly from the Home Assistant integration's documented endpoints for full control and easier debugging.

### 2. `server/resmed_sync.py` — Sync CLI Script

Standalone script invoked by cron or the admin UI. Connects to PostgreSQL directly via `DATABASE_URL` (not through the Flask app — this runs outside the Flask request context).

**Flow:**
1. Connect to PostgreSQL using `DATABASE_URL` env var (same as the Flask app uses)
2. Read myAir credentials from `settings` table, decrypt password
3. Authenticate with MyAirClient
4. Fetch session summaries:
   - **First run** (no `resmed_last_sync` in settings): fetch all available historical data (myAir typically retains ~365 days). Not idempotent-safe for partial failures, but 365 upserts are fast enough that a retry is harmless.
   - **Subsequent runs**: fetch last 7 days to catch any missed or updated data
5. For each session:
   - If row exists with `import_source = 'sd_card'` → skip (SD card data is more detailed)
   - If row exists with `import_source = 'resmed_cloud'` → update
   - Otherwise → insert
6. Log result to `sync_log` table (with `api_key_id = NULL` since this is a server-side operation)
7. Update `settings` with last sync timestamp and status

**Invocation:**
```bash
cd /app && python resmed_sync.py              # Run sync now
cd /app && python resmed_sync.py --check-schedule  # Only run if current hour matches configured time
```

**Exit codes:** 0 = success, 1 = auth failure, 2 = API error, 3 = no credentials configured

### 3. Database Changes

**New `settings` table:**
```sql
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Migration for `cpap_sessions`** — drop NOT NULL constraints on columns that cloud data can't populate:
```sql
ALTER TABLE cpap_sessions ALTER COLUMN pressure_min DROP NOT NULL;
ALTER TABLE cpap_sessions ALTER COLUMN pressure_max DROP NOT NULL;
ALTER TABLE cpap_sessions ALTER COLUMN pressure_mean DROP NOT NULL;
ALTER TABLE cpap_sessions ALTER COLUMN leak_rate_95th DROP NOT NULL;
```

These ALTERs are idempotent-safe (dropping NOT NULL on a column that's already nullable is a no-op). Run them in `init_db()` after the `CREATE TABLE` statements.

Also update `schema.sql` to reflect the new nullable state for fresh installs.

**Settings keys:**
- `resmed_email` — myAir account email (plaintext)
- `resmed_password` — myAir account password (Fernet-encrypted)
- `resmed_sync_time` — Daily sync time in HH:MM format (default: "12:00")
- `resmed_last_sync` — ISO 8601 timestamp of last sync attempt
- `resmed_last_status` — Result of last sync ("ok: 3 sessions synced", "error: auth failed", etc.)

**Encryption:** Password encrypted with `cryptography.fernet.Fernet`. Since `SECRET_KEY` is an arbitrary string, derive a valid Fernet key using PBKDF2:
```python
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from cryptography.fernet import Fernet
import base64

def _fernet_key(secret: str) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32,
                      salt=b"anxietywatch-settings", iterations=100_000)
    return base64.urlsafe_b64encode(kdf.derive(secret.encode()))

def encrypt_value(plaintext: str, secret: str) -> str:
    return Fernet(_fernet_key(secret)).encrypt(plaintext.encode()).decode()

def decrypt_value(token: str, secret: str) -> str:
    return Fernet(_fernet_key(secret)).decrypt(token.encode()).decode()
```

### 4. Admin UI Additions

**New route: `GET/POST /admin/settings/resmed`**

Form fields:
- **myAir Email** — text input
- **myAir Password** — password input (shows masked dots, blank on POST = unchanged)
- **Daily Sync Time** — time input (HH:MM), default 12:00 PM
- **Sync Now** button — triggers immediate sync by calling `resmed_sync` inline
- **Last Sync Status** — read-only display: timestamp + result message

**Template:** `server/templates/resmed_settings.html`

Navigation: Add "ResMed Sync" link to the admin sidebar/nav.

**Security:** The `settings` table should NOT be added to `BROWSABLE_TABLES` in the admin data browser, since it contains the encrypted password blob.

### 5. Cron Integration

The server runs in Docker. Add an hourly cron entry (via the existing Docker entrypoint or a supercronic sidecar) that invokes the sync script with schedule checking:

```
0 * * * * cd /app && python resmed_sync.py --check-schedule >> /var/log/resmed_sync.log 2>&1
```

With `--check-schedule`, the script reads `resmed_sync_time` from the `settings` table, compares against the current server time (UTC — the configured time should be documented as UTC in the admin UI), and exits immediately (code 0) if the current hour doesn't match. The minute component is ignored (sync fires at the top of the matching hour).

If no cron infrastructure exists yet on the server container, add it to the Gunicorn entrypoint or use APScheduler as an in-process alternative. The simplest Docker approach: add a one-line cron to the Dockerfile or docker-compose command.

## Data Mapping

| myAir Field | `cpap_sessions` Column | Notes |
|-------------|----------------------|-------|
| Date | `date` | Normalized to start-of-day |
| AHI | `ahi` | Direct map |
| Usage minutes | `total_usage_minutes` | Direct map |
| Mask leak % | `leak_rate_95th` | Convert from % to L/min if needed (see below) |
| Mean pressure | `pressure_mean` | If available from API, else NULL |
| — | `pressure_min` | NULL (not available from cloud) |
| — | `pressure_max` | NULL (not available from cloud) |
| — | `obstructive_events` | 0 (cloud only provides total AHI) |
| — | `central_events` | 0 |
| — | `hypopnea_events` | 0 |
| — | `import_source` | `"resmed_cloud"` |

**Leak rate conversion:** The iOS model documents `leakRate95th` as L/min. If myAir reports a percentage instead, store the raw percentage and add a `leak_unit` note in the `import_source` or a comment. During implementation, inspect the actual API response to determine the unit and convert accordingly. If conversion is not possible, store NULL rather than an incorrect value.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Auth failure | Store error in last_status, exit code 1, don't retry until next run |
| Unexpected API response | Log raw response, store error, exit code 2 |
| Network timeout | Store error, exit code 2 |
| Date already has `sd_card` import | Skip (SD card data is more detailed) |
| Date already has `resmed_cloud` import | Upsert (update with latest) |
| No credentials configured | Exit code 3, no-op |
| Encryption key mismatch | Store error, require re-entry of credentials in admin UI |

## What This Does NOT Include (YAGNI)

- Detailed waveform data (not available from cloud API)
- Real-time monitoring (data only updates once daily)
- Multiple myAir accounts
- Automatic fallback to SD card import
- iOS-side myAir authentication
- myAir score tracking (proprietary metric, not clinically useful)

## Testing

- **Unit tests** for `resmed_client.py`: mock HTTP responses, test auth flow, test data parsing, test error handling
- **Unit tests** for `resmed_sync.py`: mock client, test upsert logic (new row, existing `sd_card` row skipped, existing cloud row updated), test schedule checking, test DB connection via DATABASE_URL
- **Unit tests** for encryption helpers: round-trip encrypt/decrypt, wrong key handling
- **Integration test**: settings CRUD via admin UI
- **Manual test**: configure real myAir credentials, verify data appears in iOS app after sync

## Files to Create/Modify

| File | Action |
|------|--------|
| `server/resmed_client.py` | NEW — myAir API client |
| `server/resmed_sync.py` | NEW — sync CLI script (connects to DB directly, not via Flask) |
| `server/crypto.py` | NEW — Fernet encrypt/decrypt helpers with PBKDF2 key derivation |
| `server/admin.py` | MODIFY — add ResMed settings routes, exclude settings from data browser |
| `server/templates/resmed_settings.html` | NEW — settings form template |
| `server/schema.sql` | MODIFY — add `settings` table, make pressure/leak columns nullable |
| `server/server.py` | MODIFY — add ALTER TABLE migrations in `init_db()` |
| `server/requirements.txt` | MODIFY — add `requests>=2.31`, `cryptography>=41.0` |
| `server/tests/test_resmed.py` | NEW — unit tests |
| `server/Dockerfile` or `docker-compose.yml` | MODIFY — add hourly cron for resmed_sync |
