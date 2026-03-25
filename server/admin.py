"""Admin blueprint — login, API key management, data browser."""

import hashlib
import hmac
import os
import secrets
import sys
from functools import wraps

import psycopg2.extras
from flask import (
    Blueprint,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


def get_db():
    return current_app.get_db()


def require_admin(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("admin"):
            return redirect(url_for("admin.login"))
        return f(*args, **kwargs)
    return decorated


# ---------------------------------------------------------------------------
# Login / Logout
# ---------------------------------------------------------------------------


@admin_bp.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        password = request.form.get("password", "")
        admin_password = os.environ.get("ADMIN_PASSWORD", "")
        if admin_password and hmac.compare_digest(password, admin_password):
            session["admin"] = True
            return redirect(url_for("admin.dashboard"))
        flash("Invalid password.", "error")
    return render_template("login.html")


@admin_bp.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("admin.login"))


# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------


@admin_bp.route("/")
@require_admin
def dashboard():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Record counts
    tables = [
        ("anxiety_entries", "Anxiety Entries"),
        ("medication_definitions", "Medication Definitions"),
        ("medication_doses", "Medication Doses"),
        ("cpap_sessions", "CPAP Sessions"),
        ("health_snapshots", "Health Snapshots"),
        ("barometric_readings", "Barometric Readings"),
    ]
    counts = []
    for table, label in tables:
        cur.execute(f"SELECT COUNT(*) AS count FROM {table}")
        counts.append({"label": label, "count": cur.fetchone()["count"]})

    # Last sync
    cur.execute(
        "SELECT received_at, sync_type, device_name, record_counts "
        "FROM sync_log ORDER BY received_at DESC LIMIT 1"
    )
    last_sync = cur.fetchone()

    # DB size
    cur.execute("SELECT pg_size_pretty(pg_database_size(current_database())) AS size")
    db_size = cur.fetchone()["size"]

    # Active API keys count
    cur.execute("SELECT COUNT(*) AS count FROM api_keys WHERE is_active = TRUE")
    active_keys = cur.fetchone()["count"]

    return render_template(
        "dashboard.html",
        counts=counts,
        last_sync=last_sync,
        db_size=db_size,
        active_keys=active_keys,
    )


# ---------------------------------------------------------------------------
# API Key Management
# ---------------------------------------------------------------------------


@admin_bp.route("/keys")
@require_admin
def keys():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute(
        "SELECT id, key_prefix, label, created_at, last_used_at, request_count, is_active "
        "FROM api_keys ORDER BY created_at DESC"
    )
    api_keys = cur.fetchall()
    new_key = session.pop("new_key", None)
    return render_template("keys.html", api_keys=api_keys, new_key=new_key)


@admin_bp.route("/keys", methods=["POST"])
@require_admin
def create_key():
    label = request.form.get("label", "").strip()
    if not label:
        flash("Label is required.", "error")
        return redirect(url_for("admin.keys"))

    raw_key = secrets.token_urlsafe(32)
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()
    key_prefix = raw_key[:8]

    db = get_db()
    cur = db.cursor()
    cur.execute(
        "INSERT INTO api_keys (key_hash, key_prefix, label) VALUES (%s, %s, %s)",
        (key_hash, key_prefix, label),
    )
    db.commit()

    session["new_key"] = raw_key
    return redirect(url_for("admin.keys"))


@admin_bp.route("/keys/<int:key_id>/revoke", methods=["POST"])
@require_admin
def revoke_key(key_id):
    db = get_db()
    cur = db.cursor()
    cur.execute("UPDATE api_keys SET is_active = FALSE WHERE id = %s", (key_id,))
    db.commit()
    flash("API key revoked.", "success")
    return redirect(url_for("admin.keys"))


# ---------------------------------------------------------------------------
# ResMed Settings
# ---------------------------------------------------------------------------


@admin_bp.route("/settings/resmed", methods=["GET", "POST"])
@require_admin
def resmed_settings():
    from crypto import encrypt_value

    db = get_db()
    cur = db.cursor()
    secret_key = os.environ.get("SECRET_KEY", "")

    if request.method == "POST":
        action = request.form.get("action", "save")
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        sync_time = request.form.get("sync_time", "21:00").strip()

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
            try:
                import subprocess
                result = subprocess.run(
                    [sys.executable, "resmed_sync.py"],
                    capture_output=True, text=True, timeout=60,
                    env={**os.environ},
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
    sync_time = _get("resmed_sync_time") or "21:00"
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


# ---------------------------------------------------------------------------
# Data Browser
# ---------------------------------------------------------------------------

BROWSABLE_TABLES = {
    "anxiety_entries": {"order": "timestamp DESC", "label": "Anxiety Entries"},
    "medication_definitions": {"order": "name", "label": "Medication Definitions"},
    "medication_doses": {"order": "timestamp DESC", "label": "Medication Doses"},
    "cpap_sessions": {"order": "date DESC", "label": "CPAP Sessions"},
    "health_snapshots": {"order": "date DESC", "label": "Health Snapshots"},
    "barometric_readings": {"order": "timestamp DESC", "label": "Barometric Readings"},
    "sync_log": {"order": "received_at DESC", "label": "Sync Log"},
}


@admin_bp.route("/data")
@require_admin
def data():
    table = request.args.get("table", "anxiety_entries")
    if table not in BROWSABLE_TABLES:
        table = "anxiety_entries"

    limit = min(int(request.args.get("limit", 50)), 500)

    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    order = BROWSABLE_TABLES[table]["order"]
    cur.execute(f"SELECT * FROM {table} ORDER BY {order} LIMIT %s", (limit,))
    rows = cur.fetchall()

    # Get column names from cursor description
    columns = [desc[0] for desc in cur.description] if cur.description else []

    return render_template(
        "data.html",
        tables=BROWSABLE_TABLES,
        current_table=table,
        columns=columns,
        rows=rows,
        limit=limit,
    )
