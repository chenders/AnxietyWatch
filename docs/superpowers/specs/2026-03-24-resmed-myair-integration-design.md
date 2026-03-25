# ResMed myAir Cloud Integration — Design Spec

## Problem

CPAP session data currently requires manual CSV import from the AirSense 11 SD card. This is friction-heavy and means data is often days or weeks stale. The ResMed myAir cloud service receives daily session summaries automatically from the device — integrating with it would provide near-automatic daily CPAP data without touching the SD card.

## Constraints

- The myAir API is **reverse-engineered** (not officially supported by ResMed). It can break at any time.
- Cloud data is **less detailed** than SD card: no obstructive/central/hypopnea event breakdown, possibly no min/max pressure.
- Data updates **once per day**, typically 12–24 hours after the therapy session.
- Regional limitations: does not work in France (2FA required), untested in Asia.

## Architecture

Server-side integration (Python). The server polls myAir daily, stores results in PostgreSQL, and the iOS app picks up CPAP data through its existing sync mechanism.

```
myAir Cloud → server/resmed_client.py → PostgreSQL (cpap_sessions) → /api/data → iOS app
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

    def fetch_recent_sessions(self, days: int = 7) -> list[dict]:
        """Returns list of daily session summaries.
        Each dict contains: date, ahi, usage_minutes, leak_percent, mean_pressure (if available).
        Raises MyAirAuthError on auth failure, MyAirAPIError on unexpected responses.
        """
```

**Dependencies:** `requests` (add to requirements.txt). No dependency on `myair-py` — implement directly from the Home Assistant integration's documented endpoints for full control and easier debugging.

### 2. `server/resmed_sync.py` — Sync CLI Script

Standalone script invoked by cron. Reads settings from DB, fetches data, upserts.

**Flow:**
1. Read myAir credentials and sync time from `settings` table
2. Authenticate with MyAirClient
3. Fetch last 7 days of session summaries
4. For each session:
   - If row exists with `import_source = 'csv'` → skip (CSV is more detailed)
   - If row exists with `import_source = 'resmed_cloud'` → update
   - Otherwise → insert
5. Log result to `sync_log` table
6. Update `settings` with last sync timestamp and status

**Invocation:**
```bash
python -m resmed_sync
# Or via the server module:
cd server && python resmed_sync.py
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

**Settings keys:**
- `resmed_email` — myAir account email
- `resmed_password` — myAir account password (encrypted with Fernet using SECRET_KEY)
- `resmed_sync_time` — Daily sync time in HH:MM format (default: "12:00")
- `resmed_last_sync` — ISO 8601 timestamp of last sync attempt
- `resmed_last_status` — Result of last sync ("ok: 3 sessions synced", "error: auth failed", etc.)

**Encryption:** Password encrypted at rest using `cryptography.fernet.Fernet` with the existing `SECRET_KEY` env var as the key derivation source.

### 4. Admin UI Additions

**New route: `GET/POST /admin/settings/resmed`**

Form fields:
- **myAir Email** — text input
- **myAir Password** — password input (shows masked dots, blank = unchanged)
- **Daily Sync Time** — time input (HH:MM), default 12:00 PM
- **Sync Now** button — triggers immediate sync via `resmed_sync` inline
- **Last Sync Status** — read-only display: timestamp + result message

**Template:** `server/templates/resmed_settings.html`

Navigation: Add "ResMed Sync" link to the admin sidebar/nav.

### 5. Cron Integration

Add to the server's cron schedule (or Docker entrypoint):
```
0 12 * * * cd /app && python resmed_sync.py >> /var/log/resmed_sync.log 2>&1
```

The script reads the configured sync time from the `settings` table. The cron runs at the default time (12:00 PM); if the admin changes the time, the actual cron entry should be updated accordingly. For simplicity in V1, the cron runs hourly and the script itself checks if it's the right time:

```
0 * * * * cd /app && python resmed_sync.py --check-schedule
```

With `--check-schedule`, the script exits immediately (code 0) if the current hour doesn't match the configured sync time.

## Data Mapping

| myAir Field | `cpap_sessions` Column | Notes |
|-------------|----------------------|-------|
| Date | `date` | Normalized to start-of-day |
| AHI | `ahi` | Direct map |
| Usage minutes | `total_usage_minutes` | Direct map |
| Mask leak % | `leak_rate_95th` | May need unit conversion |
| Mean pressure | `pressure_mean` | If available from API |
| — | `pressure_min` | NULL (not available) |
| — | `pressure_max` | NULL (not available) |
| — | `obstructive_events` | 0 (cloud only provides total AHI) |
| — | `central_events` | 0 |
| — | `hypopnea_events` | 0 |
| — | `import_source` | `"resmed_cloud"` |

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Auth failure | Store error in last_status, exit code 1, don't retry until next run |
| Unexpected API response | Log raw response, store error, exit code 2 |
| Network timeout | Store error, exit code 2 |
| Date already has CSV import | Skip (CSV data is more detailed) |
| Date already has cloud import | Upsert (update with latest) |
| No credentials configured | Exit code 3, no-op |
| Encryption key mismatch | Store error, require re-entry of credentials |

## What This Does NOT Include (YAGNI)

- Detailed waveform data (not available from cloud API)
- Real-time monitoring (data only updates once daily)
- Multiple myAir accounts
- Automatic fallback to SD card import
- iOS-side myAir authentication
- myAir score tracking (proprietary metric, not clinically useful)

## Testing

- **Unit tests** for `resmed_client.py`: mock HTTP responses, test auth flow, test data parsing, test error handling
- **Unit tests** for `resmed_sync.py`: mock client, test upsert logic (new row, existing CSV row skipped, existing cloud row updated), test schedule checking
- **Integration test**: settings CRUD via admin UI
- **Manual test**: configure real myAir credentials, verify data appears in iOS app after sync

## Files to Create/Modify

| File | Action |
|------|--------|
| `server/resmed_client.py` | NEW — myAir API client |
| `server/resmed_sync.py` | NEW — sync CLI script |
| `server/admin.py` | MODIFY — add ResMed settings routes |
| `server/templates/resmed_settings.html` | NEW — settings form template |
| `server/schema.sql` | MODIFY — add `settings` table |
| `server/requirements.txt` | MODIFY — add `requests`, `cryptography` |
| `server/tests/test_resmed.py` | NEW — unit tests |
| `server/docker-compose.yml` | MODIFY — add cron for resmed_sync (if using Docker cron) |

## Open Questions

1. **Exact myAir API endpoints** — Need to trace the Home Assistant integration source code to document the exact URLs, headers, and response formats. This will be done during implementation.
2. **Leak rate units** — myAir may report leak as a percentage or L/min. Need to verify and convert if necessary to match the `leak_rate_95th` column semantics.
3. **Schema migration** — The `settings` table needs to be added. Current pattern is auto-init from `schema.sql` on startup. Adding `IF NOT EXISTS` to the new table definition keeps it backward compatible.
