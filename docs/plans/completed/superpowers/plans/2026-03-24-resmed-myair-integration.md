# ResMed myAir Cloud Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically sync daily CPAP session data from ResMed's myAir cloud into the AnxietyWatch server.

**Architecture:** Server-side Python module that authenticates with myAir, fetches daily summaries, and upserts into the existing `cpap_sessions` PostgreSQL table. Credentials managed via admin UI with Fernet encryption. Hourly cron checks schedule and runs sync at configured time (default 12:00 PM UTC).

**Tech Stack:** Python 3.12, Flask, PostgreSQL, myair-py (myAir API client), cryptography (Fernet encryption), requests

**Spec:** `docs/superpowers/specs/2026-03-24-resmed-myair-integration-design.md`

---

### Task 1: Dependencies and Schema

**Files:**
- Modify: `server/requirements.txt`
- Modify: `server/schema.sql`
- Modify: `server/server.py` (init_db function, around line 52)

- [ ] **Step 1: Add dependencies to requirements.txt**

Add to `server/requirements.txt`:
```
requests>=2.31
cryptography>=41.0
myair>=0.1.2
```

- [ ] **Step 2: Add settings table to schema.sql**

Append to `server/schema.sql` before the indexes section:
```sql
CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
```

- [ ] **Step 3: Update schema.sql — make cpap_sessions pressure/leak columns nullable**

Change the `cpap_sessions` table in `server/schema.sql`:
```sql
CREATE TABLE IF NOT EXISTS cpap_sessions (
    date                DATE NOT NULL PRIMARY KEY,
    ahi                 DOUBLE PRECISION NOT NULL,
    total_usage_minutes INTEGER NOT NULL,
    leak_rate_95th      DOUBLE PRECISION,
    pressure_min        DOUBLE PRECISION,
    pressure_max        DOUBLE PRECISION,
    pressure_mean       DOUBLE PRECISION,
    obstructive_events  INTEGER NOT NULL DEFAULT 0,
    central_events      INTEGER NOT NULL DEFAULT 0,
    hypopnea_events     INTEGER NOT NULL DEFAULT 0,
    import_source       TEXT NOT NULL DEFAULT 'sd_card'
);
```

- [ ] **Step 4: Add ALTER TABLE migrations to init_db() in server.py**

In `server/server.py`, find the `init_db()` function. After the `cur.execute(schema)` line, add:
```python
# Migrations for existing databases
cur.execute("ALTER TABLE cpap_sessions ALTER COLUMN pressure_min DROP NOT NULL")
cur.execute("ALTER TABLE cpap_sessions ALTER COLUMN pressure_max DROP NOT NULL")
cur.execute("ALTER TABLE cpap_sessions ALTER COLUMN pressure_mean DROP NOT NULL")
cur.execute("ALTER TABLE cpap_sessions ALTER COLUMN leak_rate_95th DROP NOT NULL")
conn.commit()
```

- [ ] **Step 5: Install dependencies and verify**

Run: `cd server && pip install -r requirements.txt`
Expected: All packages install successfully

- [ ] **Step 6: Verify server starts with new schema**

Run: `cd server && python -c "from server import create_app; app = create_app()"`
Expected: No errors

- [ ] **Step 7: Commit**

```bash
git add server/requirements.txt server/schema.sql server/server.py
git commit -m "feat: add settings table and make cpap pressure columns nullable

Prepares schema for ResMed myAir cloud integration where pressure
min/max and leak rate are not available from the cloud API."
```

---

### Task 2: Encryption Helpers

**Files:**
- Create: `server/crypto.py`
- Create: `server/tests/test_crypto.py`

- [ ] **Step 1: Write failing tests for crypto module**

Create `server/tests/test_crypto.py`:
```python
import pytest
from crypto import encrypt_value, decrypt_value


def test_round_trip():
    secret = "test-secret-key-for-encryption"
    plaintext = "my-resmed-password-123"
    encrypted = encrypt_value(plaintext, secret)
    assert encrypted != plaintext
    assert decrypt_value(encrypted, secret) == plaintext


def test_different_secrets_produce_different_output():
    plaintext = "same-password"
    enc1 = encrypt_value(plaintext, "secret-one")
    enc2 = encrypt_value(plaintext, "secret-two")
    assert enc1 != enc2


def test_wrong_secret_fails():
    encrypted = encrypt_value("password", "correct-secret")
    with pytest.raises(Exception):
        decrypt_value(encrypted, "wrong-secret")


def test_empty_string():
    secret = "test-secret"
    encrypted = encrypt_value("", secret)
    assert decrypt_value(encrypted, secret) == ""
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_crypto.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'crypto'`

- [ ] **Step 3: Implement crypto.py**

Create `server/crypto.py`:
```python
"""Fernet encryption helpers for settings values (e.g., myAir password)."""

import base64

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes


def _fernet_key(secret: str) -> bytes:
    """Derive a valid Fernet key from an arbitrary secret string."""
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"anxietywatch-settings",
        iterations=100_000,
    )
    return base64.urlsafe_b64encode(kdf.derive(secret.encode()))


def encrypt_value(plaintext: str, secret: str) -> str:
    """Encrypt a string using Fernet with a PBKDF2-derived key."""
    return Fernet(_fernet_key(secret)).encrypt(plaintext.encode()).decode()


def decrypt_value(token: str, secret: str) -> str:
    """Decrypt a Fernet token back to plaintext."""
    return Fernet(_fernet_key(secret)).decrypt(token.encode()).decode()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python -m pytest tests/test_crypto.py -v`
Expected: 4 passed

- [ ] **Step 5: Lint**

Run: `cd server && flake8 crypto.py tests/test_crypto.py --max-line-length=120`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add server/crypto.py server/tests/test_crypto.py
git commit -m "feat: add Fernet encryption helpers with PBKDF2 key derivation"
```

---

### Task 3: myAir API Client

**Files:**
- Create: `server/resmed_client.py`
- Create: `server/tests/test_resmed_client.py`

- [ ] **Step 1: Write failing tests**

Create `server/tests/test_resmed_client.py`:
```python
import pytest
from unittest.mock import patch, MagicMock
from resmed_client import MyAirClient, MyAirAuthError, MyAirAPIError


def test_auth_failure_raises():
    with patch("resmed_client.MyAir") as mock_myair:
        mock_myair.side_effect = Exception("auth failed")
        with pytest.raises(MyAirAuthError):
            client = MyAirClient("bad@email.com", "wrong-password")
            client.fetch_sessions(days=1)


def test_fetch_sessions_returns_list():
    with patch("resmed_client.MyAir") as mock_myair:
        mock_instance = MagicMock()
        mock_myair.return_value = mock_instance
        mock_instance.get_sleep_records.return_value = [
            MagicMock(
                start_date="2026-03-20",
                total_usage=420,
                ahi=2.5,
                leak_percentile=18.3,
                mask_events=2,
            )
        ]
        client = MyAirClient("user@example.com", "password")
        sessions = client.fetch_sessions(days=7)
        assert len(sessions) == 1
        assert sessions[0]["ahi"] == 2.5
        assert sessions[0]["total_usage_minutes"] == 420


def test_empty_response_returns_empty_list():
    with patch("resmed_client.MyAir") as mock_myair:
        mock_instance = MagicMock()
        mock_myair.return_value = mock_instance
        mock_instance.get_sleep_records.return_value = []
        client = MyAirClient("user@example.com", "password")
        sessions = client.fetch_sessions(days=7)
        assert sessions == []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_resmed_client.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Implement resmed_client.py**

Create `server/resmed_client.py`:
```python
"""Thin wrapper around the myAir API for fetching CPAP session data."""

from datetime import datetime, timedelta


class MyAirAuthError(Exception):
    """Raised when myAir authentication fails."""
    pass


class MyAirAPIError(Exception):
    """Raised when the myAir API returns an unexpected response."""
    pass


try:
    from myair import MyAir
except ImportError:
    MyAir = None


class MyAirClient:
    """Fetches daily CPAP session summaries from ResMed's myAir cloud."""

    def __init__(self, email: str, password: str):
        if MyAir is None:
            raise MyAirAPIError("myair package not installed")
        self.email = email
        self.password = password

    def fetch_sessions(self, days: int = 7) -> list[dict]:
        """Fetch daily session summaries for the last N days.

        Returns list of dicts with keys: date, ahi, total_usage_minutes,
        leak_percentile, mean_pressure (if available).
        """
        try:
            client = MyAir(self.email, self.password)
            records = client.get_sleep_records(
                start=datetime.now() - timedelta(days=days),
                end=datetime.now(),
            )
        except Exception as e:
            error_msg = str(e).lower()
            if "auth" in error_msg or "credential" in error_msg or "login" in error_msg:
                raise MyAirAuthError(f"Authentication failed: {e}") from e
            raise MyAirAPIError(f"API error: {e}") from e

        sessions = []
        for record in records:
            try:
                session = {
                    "date": str(record.start_date)[:10],
                    "ahi": float(record.ahi),
                    "total_usage_minutes": int(record.total_usage),
                    "leak_percentile": getattr(record, "leak_percentile", None),
                    "mean_pressure": getattr(record, "mean_pressure", None),
                }
                sessions.append(session)
            except (AttributeError, ValueError, TypeError) as e:
                # Skip malformed records rather than failing the whole sync
                print(f"Skipping malformed record: {e}")
                continue

        return sessions
```

Note: The exact `myair` library API (attribute names on record objects) may differ from what's mocked here. During implementation, install `myair` and inspect the actual response objects. The mock tests validate the wrapper logic; the real API shape will be verified manually.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python -m pytest tests/test_resmed_client.py -v`
Expected: 3 passed

- [ ] **Step 5: Lint**

Run: `cd server && flake8 resmed_client.py tests/test_resmed_client.py --max-line-length=120`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add server/resmed_client.py server/tests/test_resmed_client.py
git commit -m "feat: add myAir API client wrapper with error handling"
```

---

### Task 4: Sync Script

**Files:**
- Create: `server/resmed_sync.py`
- Create: `server/tests/test_resmed_sync.py`

- [ ] **Step 1: Write failing tests for upsert logic**

Create `server/tests/test_resmed_sync.py`:
```python
import os
import pytest
import psycopg2
from resmed_sync import upsert_sessions, should_run_now


@pytest.fixture
def db():
    """Connect to test database."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        pytest.skip("DATABASE_URL not set")
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    yield conn
    conn.rollback()
    conn.close()


@pytest.fixture
def clean_cpap(db):
    """Ensure cpap_sessions is empty for this test."""
    cur = db.cursor()
    cur.execute("DELETE FROM cpap_sessions")
    db.commit()
    yield db
    cur.execute("DELETE FROM cpap_sessions")
    db.commit()


def test_insert_new_session(clean_cpap):
    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 1

    cur = clean_cpap.cursor()
    cur.execute("SELECT import_source FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == "resmed_cloud"


def test_skip_existing_sd_card(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute(
        "INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
        "VALUES ('2026-03-20', 1.0, 400, 'sd_card')"
    )
    clean_cpap.commit()

    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 0  # Skipped because sd_card data exists

    cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == 1.0  # Original value preserved


def test_update_existing_cloud(clean_cpap):
    cur = clean_cpap.cursor()
    cur.execute(
        "INSERT INTO cpap_sessions (date, ahi, total_usage_minutes, import_source) "
        "VALUES ('2026-03-20', 1.0, 400, 'resmed_cloud')"
    )
    clean_cpap.commit()

    sessions = [{"date": "2026-03-20", "ahi": 2.5, "total_usage_minutes": 420,
                 "leak_percentile": None, "mean_pressure": None}]
    count = upsert_sessions(clean_cpap, sessions)
    assert count == 1  # Updated

    cur.execute("SELECT ahi FROM cpap_sessions WHERE date = '2026-03-20'")
    assert cur.fetchone()[0] == 2.5  # Updated value


def test_should_run_now_matching_hour():
    assert should_run_now("14", 14) is True
    assert should_run_now("14:30", 14) is True


def test_should_run_now_non_matching_hour():
    assert should_run_now("14", 15) is False
    assert should_run_now("08:00", 14) is False


def test_should_run_now_invalid():
    assert should_run_now("", 14) is False
    assert should_run_now(None, 14) is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_resmed_sync.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Implement resmed_sync.py**

Create `server/resmed_sync.py`:
```python
"""ResMed myAir sync script — fetches CPAP data and upserts into PostgreSQL.

Usage:
    python resmed_sync.py                  # Run sync now
    python resmed_sync.py --check-schedule # Only run if current hour matches configured time

Exit codes: 0=success, 1=auth failure, 2=API error, 3=no credentials
"""

import argparse
import os
import sys
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras

from crypto import decrypt_value
from resmed_client import MyAirClient, MyAirAuthError, MyAirAPIError


def get_db():
    """Connect to PostgreSQL using DATABASE_URL."""
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError("DATABASE_URL not set")
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    return conn


def get_setting(conn, key):
    """Read a setting from the settings table."""
    cur = conn.cursor()
    cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
    row = cur.fetchone()
    return row[0] if row else None


def set_setting(conn, key, value):
    """Write a setting (upsert)."""
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (%s, %s, NOW()) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        (key, value),
    )
    conn.commit()


def should_run_now(sync_time_str, current_hour):
    """Check if the current hour matches the configured sync time."""
    if not sync_time_str:
        return False
    try:
        hour = int(sync_time_str.split(":")[0])
        return hour == current_hour
    except (ValueError, IndexError):
        return False


def upsert_sessions(conn, sessions):
    """Insert or update CPAP sessions from myAir data.

    Skips dates that already have sd_card imports.
    Returns count of rows inserted/updated.
    """
    cur = conn.cursor()
    count = 0

    for s in sessions:
        date = s["date"]

        # Check if sd_card data exists for this date
        cur.execute(
            "SELECT import_source FROM cpap_sessions WHERE date = %s", (date,)
        )
        existing = cur.fetchone()
        if existing and existing[0] == "sd_card":
            continue  # Don't overwrite SD card data

        cur.execute(
            """INSERT INTO cpap_sessions
               (date, ahi, total_usage_minutes, leak_rate_95th,
                pressure_mean, obstructive_events, central_events,
                hypopnea_events, import_source)
               VALUES (%s, %s, %s, %s, %s, 0, 0, 0, 'resmed_cloud')
               ON CONFLICT (date) DO UPDATE SET
                   ahi = EXCLUDED.ahi,
                   total_usage_minutes = EXCLUDED.total_usage_minutes,
                   leak_rate_95th = EXCLUDED.leak_rate_95th,
                   pressure_mean = EXCLUDED.pressure_mean,
                   import_source = 'resmed_cloud'
               WHERE cpap_sessions.import_source = 'resmed_cloud'
            """,
            (date, s["ahi"], s["total_usage_minutes"],
             s.get("leak_percentile"), s.get("mean_pressure")),
        )
        if cur.rowcount > 0:
            count += 1

    conn.commit()
    return count


def log_sync(conn, status, count=0):
    """Log sync result to sync_log and settings."""
    now = datetime.now(timezone.utc).isoformat()
    set_setting(conn, "resmed_last_sync", now)
    set_setting(conn, "resmed_last_status", status)

    cur = conn.cursor()
    cur.execute(
        "INSERT INTO sync_log (sync_type, device_name, record_counts, api_key_id) "
        "VALUES (%s, %s, %s, NULL)",
        ("resmed_cloud", "server", psycopg2.extras.Json({"cpap_sessions": count})),
    )
    conn.commit()


def main():
    parser = argparse.ArgumentParser(description="Sync ResMed myAir CPAP data")
    parser.add_argument("--check-schedule", action="store_true",
                        help="Only run if current UTC hour matches configured sync time")
    args = parser.parse_args()

    conn = get_db()

    # Schedule check
    if args.check_schedule:
        sync_time = get_setting(conn, "resmed_sync_time") or "12"
        current_hour = datetime.now(timezone.utc).hour
        if not should_run_now(sync_time, current_hour):
            conn.close()
            sys.exit(0)

    # Read credentials
    email = get_setting(conn, "resmed_email")
    encrypted_pw = get_setting(conn, "resmed_password")
    secret_key = os.environ.get("SECRET_KEY", "")

    if not email or not encrypted_pw:
        print("No myAir credentials configured")
        conn.close()
        sys.exit(3)

    try:
        password = decrypt_value(encrypted_pw, secret_key)
    except Exception as e:
        log_sync(conn, f"error: decryption failed — {e}")
        conn.close()
        sys.exit(1)

    # Determine fetch range
    last_sync = get_setting(conn, "resmed_last_sync")
    days = 365 if last_sync is None else 7

    # Fetch and sync
    try:
        client = MyAirClient(email, password)
        sessions = client.fetch_sessions(days=days)
        count = upsert_sessions(conn, sessions)
        log_sync(conn, f"ok: {count} sessions synced ({len(sessions)} fetched)")
        print(f"Synced {count} sessions ({len(sessions)} fetched, {days}-day window)")
    except MyAirAuthError as e:
        log_sync(conn, f"error: auth failed — {e}")
        print(f"Auth error: {e}", file=sys.stderr)
        conn.close()
        sys.exit(1)
    except MyAirAPIError as e:
        log_sync(conn, f"error: API error — {e}")
        print(f"API error: {e}", file=sys.stderr)
        conn.close()
        sys.exit(2)
    except Exception as e:
        log_sync(conn, f"error: unexpected — {e}")
        print(f"Unexpected error: {e}", file=sys.stderr)
        conn.close()
        sys.exit(2)

    conn.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests**

Run: `cd server && python -m pytest tests/test_resmed_sync.py -v`
Expected: 6 passed (requires DATABASE_URL — schedule tests run without DB)

- [ ] **Step 5: Lint**

Run: `cd server && flake8 resmed_sync.py tests/test_resmed_sync.py --max-line-length=120`

- [ ] **Step 6: Commit**

```bash
git add server/resmed_sync.py server/tests/test_resmed_sync.py
git commit -m "feat: add ResMed myAir sync script with upsert logic"
```

---

### Task 5: Admin UI — ResMed Settings Page

**Files:**
- Modify: `server/admin.py`
- Create: `server/templates/resmed_settings.html`
- Modify: `server/templates/base.html`

- [ ] **Step 1: Add "ResMed" link to admin nav**

In `server/templates/base.html`, add after the "Data" link (line 54):
```html
        <a href="{{ url_for('admin.resmed_settings') }}">ResMed</a>
```

- [ ] **Step 2: Create the settings template**

Create `server/templates/resmed_settings.html`:
```html
{% extends "base.html" %}
{% block title %}ResMed Sync — Anxiety Watch Admin{% endblock %}
{% block content %}
<h1>ResMed myAir Sync</h1>

<div class="card">
    <h2>Credentials</h2>
    <form method="post">
        <div class="mb-1">
            <label for="email"><strong>myAir Email</strong></label>
            <input type="text" id="email" name="email" value="{{ email }}" placeholder="your@email.com">
        </div>
        <div class="mb-1">
            <label for="password"><strong>myAir Password</strong></label>
            <input type="password" id="password" name="password" placeholder="{{ '••••••••' if has_password else 'Enter password' }}">
            {% if has_password %}<small style="color:#6e6e73;">Leave blank to keep current password</small>{% endif %}
        </div>
        <div class="mb-1">
            <label for="sync_time"><strong>Daily Sync Time (UTC, HH:MM)</strong></label>
            <input type="text" id="sync_time" name="sync_time" value="{{ sync_time }}" placeholder="12:00">
        </div>
        <button type="submit" name="action" value="save" class="btn btn-primary">Save Settings</button>
        <button type="submit" name="action" value="sync_now" class="btn btn-primary" style="margin-left:0.5rem;">Sync Now</button>
    </form>
</div>

{% if last_sync or last_status %}
<div class="card">
    <h2>Last Sync</h2>
    <table>
        {% if last_sync %}<tr><th>Time</th><td>{{ last_sync }}</td></tr>{% endif %}
        {% if last_status %}<tr><th>Result</th><td>{{ last_status }}</td></tr>{% endif %}
    </table>
</div>
{% endif %}
{% endblock %}
```

- [ ] **Step 3: Add routes to admin.py**

Add to `server/admin.py` before the data browser section:
```python
# ---------------------------------------------------------------------------
# ResMed Settings
# ---------------------------------------------------------------------------

@admin_bp.route("/settings/resmed", methods=["GET", "POST"])
@require_admin
def resmed_settings():
    from crypto import encrypt_value, decrypt_value

    db = get_db()
    cur = db.cursor()
    secret_key = os.environ.get("SECRET_KEY", "")

    if request.method == "POST":
        action = request.form.get("action", "save")
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        sync_time = request.form.get("sync_time", "12:00").strip()

        # Save email
        if email:
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('resmed_email', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (email,),
            )

        # Save password (only if provided)
        if password:
            encrypted = encrypt_value(password, secret_key)
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('resmed_password', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (encrypted,),
            )

        # Save sync time
        cur.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES ('resmed_sync_time', %s, NOW()) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            (sync_time,),
        )
        db.commit()
        flash("Settings saved.", "success")

        if action == "sync_now":
            from resmed_sync import get_db as sync_get_db, main as sync_main
            try:
                # Run sync inline (reuse current DB connection context)
                import subprocess
                result = subprocess.run(
                    [sys.executable, "resmed_sync.py"],
                    capture_output=True, text=True, timeout=60,
                    env={**os.environ, "DATABASE_URL": os.environ.get("DATABASE_URL", "")},
                )
                if result.returncode == 0:
                    flash(f"Sync completed: {result.stdout.strip()}", "success")
                else:
                    flash(f"Sync failed (exit {result.returncode}): {result.stderr.strip()}", "error")
            except Exception as e:
                flash(f"Sync error: {e}", "error")

        return redirect(url_for("admin.resmed_settings"))

    # GET — read current settings
    def _get(key):
        cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
        row = cur.fetchone()
        return row[0] if row else None

    email = _get("resmed_email") or ""
    has_password = _get("resmed_password") is not None
    sync_time = _get("resmed_sync_time") or "12:00"
    last_sync = _get("resmed_last_sync")
    last_status = _get("resmed_last_status")

    return render_template(
        "resmed_settings.html",
        email=email,
        has_password=has_password,
        sync_time=sync_time,
        last_sync=last_sync,
        last_status=last_status,
    )
```

Also add `import sys` to the top of `admin.py`.

- [ ] **Step 4: Verify the admin UI loads**

Run: `cd server && ADMIN_PASSWORD=test SECRET_KEY=test-key DATABASE_URL=... python -c "from server import create_app; app = create_app(); app.test_client().get('/admin/settings/resmed')"`
Expected: No errors

- [ ] **Step 5: Lint**

Run: `cd server && flake8 admin.py templates/ --max-line-length=120`

- [ ] **Step 6: Commit**

```bash
git add server/admin.py server/templates/base.html server/templates/resmed_settings.html
git commit -m "feat: add ResMed settings page to admin UI"
```

---

### Task 6: Cron Integration

**Files:**
- Modify: `server/Dockerfile`

- [ ] **Step 1: Add cron to Docker container**

The simplest approach: add a cron entry to the Docker image. In `server/Dockerfile`, before the `CMD` line, add:
```dockerfile
# Install cron for ResMed sync
RUN apt-get update && apt-get install -y cron && rm -rf /var/lib/apt/lists/*
COPY resmed-cron /etc/cron.d/resmed-sync
RUN chmod 0644 /etc/cron.d/resmed-sync && crontab /etc/cron.d/resmed-sync
```

Create `server/resmed-cron`:
```
0 * * * * cd /app && python resmed_sync.py --check-schedule >> /proc/1/fd/1 2>&1
```

Note: This approach requires running cron alongside gunicorn. An alternative is to use the `--check-schedule` approach with the existing Docker setup and add a simple entrypoint wrapper. Evaluate during implementation.

- [ ] **Step 2: Commit**

```bash
git add server/Dockerfile server/resmed-cron
git commit -m "feat: add hourly cron for ResMed myAir sync"
```

---

### Task 7: Server Tests — CI Integration

**Files:**
- Modify: `server/tests/test_server.py` (add settings table to cleanup)

- [ ] **Step 1: Add settings table cleanup to test fixtures**

In `server/tests/test_server.py`, find the `_clean_tables` fixture and add `settings` to the table list:
```python
cur.execute("DELETE FROM settings")
```

- [ ] **Step 2: Run full server test suite**

Run: `cd server && python -m pytest tests/ -v`
Expected: All tests pass

- [ ] **Step 3: Lint entire server**

Run: `cd server && flake8 . --max-line-length=120 --exclude=__pycache__`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add server/tests/test_server.py
git commit -m "test: add settings table cleanup to server test fixtures"
```

---

### Task 8: Manual Verification

- [ ] **Step 1: Deploy to megadude and verify schema migration**

Push changes, wait for deploy, check that `settings` table exists and `cpap_sessions` columns are nullable.

- [ ] **Step 2: Configure myAir credentials via admin UI**

Navigate to `http://megadude:8081/admin/settings/resmed`, enter credentials, save.

- [ ] **Step 3: Test "Sync Now"**

Click Sync Now, verify sessions appear in the data browser.

- [ ] **Step 4: Verify iOS app receives cloud data**

Open the app, trigger a sync, verify CPAP sessions appear on the dashboard.
