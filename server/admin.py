"""Admin blueprint — login, API key management, data browser."""

import hashlib
import hmac
import json
import logging
import os
import secrets
import sys
import time
from functools import wraps

from datetime import date as date_type

import anthropic
import psycopg2.extras
from psycopg2 import sql
from flask import (
    Blueprint,
    current_app,
    flash,
    jsonify,
    make_response,
    redirect,
    render_template,
    request,
    session,
    url_for,
)

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Login failure throttling (F-034)
#
# After MAX_LOGIN_FAILURES consecutive failures, further attempts (even with
# the correct password) are refused until the window passes; a successful
# login clears the counter. State lives in the `settings` table, NOT a
# module-level counter: the container runs gunicorn with multiple workers,
# and per-worker state would let the effective threshold scale with the
# worker count (Copilot review of #162). Wall-clock epoch time (shared,
# unlike `time.monotonic()`) is used so the lockout window agrees across
# workers.
# ---------------------------------------------------------------------------

MAX_LOGIN_FAILURES = 5
LOGIN_LOCKOUT_SECONDS = 15 * 60

_FAILURES_KEY = "admin_login_failures"
_LOCKED_UNTIL_KEY = "admin_login_locked_until"


def _now():
    """Wall-clock epoch seconds — injectable so tests can advance the clock."""
    return time.time()


def _login_throttle_state(cur):
    """Return (failures, locked_until) from the settings table."""
    cur.execute(
        "SELECT key, value FROM settings WHERE key IN (%s, %s)",
        (_FAILURES_KEY, _LOCKED_UNTIL_KEY),
    )
    values = {k: v for k, v in cur.fetchall()}
    failures = int(values.get(_FAILURES_KEY) or 0)
    locked_until = float(values.get(_LOCKED_UNTIL_KEY) or 0.0)
    return failures, locked_until


def _record_login_failure(cur):
    """Atomically increment the shared failure counter; set the lockout when
    it trips. The increment is a single INSERT…ON CONFLICT that computes the
    new value in SQL and RETURNs it, rather than read-then-write — concurrent
    login POSTs (across gunicorn workers) would otherwise lose increments and
    weaken the lockout guarantee (Copilot review of #162)."""
    cur.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (%s, '1', NOW()) "
        "ON CONFLICT (key) DO UPDATE SET "
        "value = (COALESCE(settings.value, '0')::int + 1)::text, updated_at = NOW() "
        "RETURNING value::int",
        (_FAILURES_KEY,),
    )
    failures = cur.fetchone()[0]
    if failures >= MAX_LOGIN_FAILURES:
        _upsert_setting(cur, _LOCKED_UNTIL_KEY, str(_now() + LOGIN_LOCKOUT_SECONDS))
    return failures


def _clear_login_throttle(cur):
    """Clear throttle state after a successful login."""
    cur.execute(
        "DELETE FROM settings WHERE key IN (%s, %s)",
        (_FAILURES_KEY, _LOCKED_UNTIL_KEY),
    )


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
        db = get_db()
        cur = db.cursor()
        _, locked_until = _login_throttle_state(cur)
        if _now() < locked_until:
            flash("Too many attempts. Try again later.", "error")
            return render_template("login.html"), 429

        password = request.form.get("password", "")
        admin_password = os.environ.get("ADMIN_PASSWORD", "")
        if admin_password and hmac.compare_digest(password, admin_password):
            _clear_login_throttle(cur)
            db.commit()
            session["admin"] = True
            return redirect(url_for("admin.dashboard"))

        failures = _record_login_failure(cur)
        db.commit()
        # Counter only — never the submitted value or anything about it.
        logger.warning(
            "Admin login failure (consecutive failures: %d)", failures
        )
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
    # `table` iterates the hardcoded `tables` list above — not request input.
    for table, label in tables:
        cur.execute(sql.SQL("SELECT COUNT(*) AS count FROM {}").format(sql.Identifier(table)))
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


def _render_keys_page(new_key=None):
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute(
        "SELECT id, key_prefix, label, created_at, last_used_at, request_count, is_active "
        "FROM api_keys ORDER BY created_at DESC"
    )
    api_keys = cur.fetchall()
    html = render_template("keys.html", api_keys=api_keys, new_key=new_key)
    if new_key is None:
        return html
    # The one-time raw key is in this HTML. Forbid all caching so a browser
    # back-button, disk cache, or intermediary proxy can't re-surface it
    # after the intended "shown once" moment (Copilot review of #162).
    resp = make_response(html)
    resp.headers["Cache-Control"] = "no-store, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    return resp


@admin_bp.route("/keys")
@require_admin
def keys():
    return _render_keys_page()


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

    # Render the raw key exactly once, directly in this POST response. It must
    # NOT round-trip through the session cookie (the previous flow's
    # session["new_key"] + redirect): Flask sessions are signed but not
    # encrypted, so the raw key would transit the network in a decodable
    # cookie (F-033).
    return _render_keys_page(new_key=raw_key)


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


def _upsert_setting(cur, key, value):
    cur.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (%s, %s, NOW()) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        (key, value),
    )


def _upgrade_legacy_plaintext_setting(cur, key, secret_key):
    """Re-encrypt a legacy plaintext settings value in place (F-080).

    The ResMed email was historically stored plaintext while the paired
    password was Fernet-encrypted. New saves encrypt the email too, but
    existing rows may still hold plaintext. On each save, if the stored
    value does NOT have the structural shape of a Fernet token
    (looks_like_fernet_token) we treat it as legacy
    plaintext and encrypt it in place. The check is on token *shape*, not a
    decrypt attempt, precisely so a misconfigured SECRET_KEY can't misread an
    already-encrypted value as plaintext and double-encrypt it — this lazy
    upgrade only ever touches a value that provably isn't already a token.
    Deliberately NOT a bulk migration for the same corruption-safety reason.
    """
    from crypto import encrypt_value, looks_like_fernet_token

    cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
    row = cur.fetchone()
    if not row or not row[0]:
        return
    # Only re-encrypt a value that provably ISN'T already a Fernet token.
    # A token that merely fails to decrypt (wrong SECRET_KEY) must be left
    # untouched — re-encrypting it would double-encrypt and corrupt it, the
    # exact outcome the no-bulk-migration decision avoids (Copilot #162).
    if not looks_like_fernet_token(row[0]):
        _upsert_setting(cur, key, encrypt_value(row[0], secret_key))


@admin_bp.route("/settings/resmed", methods=["GET", "POST"])
@require_admin
def resmed_settings():
    from crypto import encrypt_value

    db = get_db()
    cur = db.cursor()
    secret_key = os.environ.get("SECRET_KEY")

    if request.method == "POST":
        if not secret_key:
            flash("SECRET_KEY not configured — cannot encrypt credentials.", "error")
            return redirect(url_for("admin.resmed_settings"))
        action = request.form.get("action", "save")
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        sync_time = request.form.get("sync_time", "21:00").strip()

        # Validate sync_time (HH or HH:MM, 0-23)
        try:
            hour = int(sync_time.split(":")[0]) if sync_time else -1
            if not (0 <= hour <= 23):
                raise ValueError()
        except (ValueError, IndexError):
            flash("Invalid sync time. Use HH or HH:MM format (0-23).", "error")
            return redirect(url_for("admin.resmed_settings"))

        # Save email — encrypted at rest (F-080).
        if email:
            _upsert_setting(cur, "resmed_email", encrypt_value(email, secret_key))
        else:
            _upgrade_legacy_plaintext_setting(cur, "resmed_email", secret_key)

        # Save password (only if provided)
        if password:
            _upsert_setting(cur, "resmed_password", encrypt_value(password, secret_key))

        # Save sync time
        _upsert_setting(cur, "resmed_sync_time", sync_time)
        db.commit()
        flash("Settings saved.", "success")

        if action == "sync_now":
            try:
                # Justification for the nosecs below: fixed argv list
                # (sys.executable + a hardcoded script name); no shell, no
                # request-controlled input reaches argv or env.
                import subprocess  # nosec B404
                result = subprocess.run(  # nosec B603
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

    # GET — read current settings. The stored email is never echoed back into
    # the form (it may be encrypted or legacy plaintext); only its presence.
    def _get(key):
        cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
        row = cur.fetchone()
        return row[0] if row else None

    has_email = _get("resmed_email") is not None
    has_password = _get("resmed_password") is not None
    sync_time = _get("resmed_sync_time") or "21:00"
    last_sync = _get("resmed_last_sync")
    last_status = _get("resmed_last_status")

    return render_template(
        "resmed_settings.html",
        has_email=has_email,
        has_password=has_password,
        sync_time=sync_time,
        last_sync=last_sync,
        last_status=last_status,
    )


# ---------------------------------------------------------------------------
# CPAP EDF Upload
# ---------------------------------------------------------------------------


@admin_bp.route("/cpap/upload", methods=["GET", "POST"])
@require_admin
def cpap_upload():
    if request.method == "POST":
        files = request.files.getlist("edf_files")
        if not files or all(f.filename == "" for f in files):
            flash("No files selected.", "error")
            return redirect(url_for("admin.cpap_upload"))

        import tempfile
        import os as _os
        from edf_parser import parse_edf_file, upsert_cpap_leak

        db = get_db()
        total_sessions = 0

        max_size = 100 * 1024 * 1024  # 100 MB limit

        for f in files:
            if not f.filename:
                continue
            if not f.filename.lower().endswith(".edf"):
                flash(f"{f.filename}: skipped (not an .edf file)", "error")
                continue
            tmp_path = None
            try:
                with tempfile.NamedTemporaryFile(suffix=".edf", delete=False) as tmp:
                    f.save(tmp)
                    tmp_path = tmp.name
                if _os.path.getsize(tmp_path) > max_size:
                    flash(f"{f.filename}: skipped (exceeds 100 MB limit)", "error")
                    continue

                sessions = parse_edf_file(tmp_path)
                if sessions:
                    count = upsert_cpap_leak(db, sessions)
                    total_sessions += count
                    flash(f"{f.filename}: {count} session(s) updated", "success")
                else:
                    flash(f"{f.filename}: no leak data found", "error")

            except Exception as e:
                current_app.logger.exception("CPAP EDF upload failed for %s", f.filename)
                flash(f"{f.filename}: {str(e)[:500]}", "error")
            finally:
                if tmp_path:
                    try:
                        _os.unlink(tmp_path)
                    except Exception:
                        current_app.logger.debug(
                            "Failed to remove temp EDF file %s", tmp_path, exc_info=True
                        )

        if total_sessions > 0:
            flash(f"Total: {total_sessions} CPAP session(s) updated with leak data.", "success")

        return redirect(url_for("admin.cpap_upload"))

    return render_template("cpap_upload.html")


# ---------------------------------------------------------------------------
# Data Browser
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Patient Profile
# ---------------------------------------------------------------------------


@admin_bp.route("/patient-profile", methods=["GET", "POST"])
@require_admin
def patient_profile():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        name = request.form.get("name", "").strip() or None
        dob_str = request.form.get("date_of_birth", "").strip()
        dob = None
        if dob_str:
            try:
                date_type.fromisoformat(dob_str)
                dob = dob_str
            except ValueError:
                flash("Invalid date of birth format.", "error")
                return redirect(url_for("admin.patient_profile"))
        gender_raw = request.form.get("gender", "").strip()
        VALID_GENDERS = {"male", "female", "non_binary", "other", "prefer_not_to_say"}
        gender_normalized = gender_raw.lower().replace("-", "_").replace(" ", "_") if gender_raw else ""
        gender = gender_normalized if gender_normalized in VALID_GENDERS else None
        other_meds = request.form.get("other_medications", "").strip() or None
        history_raw = request.form.get("medical_history_raw", "").strip() or None
        history_structured = request.form.get("medical_history_structured", "").strip() or None
        profile_summary = request.form.get("profile_summary", "").strip() or None

        # Check if row exists
        cur.execute("SELECT id FROM patient_profile LIMIT 1")
        existing = cur.fetchone()

        if existing:
            cur.execute(
                "UPDATE patient_profile SET name = %s, date_of_birth = %s, gender = %s, "
                "other_medications = %s, medical_history_raw = %s, "
                "medical_history_structured = %s, profile_summary = %s, "
                "updated_at = NOW() WHERE id = %s",
                (name, dob, gender, other_meds, history_raw, history_structured,
                 profile_summary, existing["id"]),
            )
        else:
            cur.execute(
                "INSERT INTO patient_profile (name, date_of_birth, gender, other_medications, "
                "medical_history_raw, medical_history_structured, profile_summary) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (name, dob, gender, other_meds, history_raw, history_structured, profile_summary),
            )
        db.commit()
        flash("Patient profile saved.", "success")
        return redirect(url_for("admin.patient_profile"))

    # GET — load existing profile and active medications
    cur.execute("SELECT * FROM patient_profile LIMIT 1")
    profile = cur.fetchone() or {}

    cur.execute(
        "SELECT name, default_dose_mg, category FROM medication_definitions "
        "WHERE is_active = TRUE ORDER BY name"
    )
    medications = cur.fetchall()

    return render_template("patient_profile.html", profile=profile, medications=medications)


@admin_bp.route("/patient-profile/refine", methods=["POST"])
@require_admin
def patient_profile_refine():
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return jsonify({"error": "ANTHROPIC_API_KEY not configured"}), 400

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid or missing JSON body"}), 400
    raw = data.get("medical_history_raw", "")
    structured_draft = data.get("structured_draft")
    answers = data.get("answers")

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

    if structured_draft and answers:
        # Finalization round — combine original + draft + answers
        prompt = (
            f"Original medical history:\n{raw}\n\n"
            f"Your structured version:\n{structured_draft}\n\n"
            f"Patient's answers to your follow-up questions:\n{answers}\n\n"
            "Produce a final structured medical history incorporating these answers. "
            "Use clear categories (Diagnoses, Surgeries, Allergies, Family History, etc.)."
        )
    else:
        # First round — parse and ask follow-up questions
        prompt = (
            f"Parse this medical history. Structure it into relevant categories "
            f"(diagnoses, surgeries, allergies, family history, etc.). "
            f"List follow-up questions that would be clinically relevant for someone "
            f"using an anxiety tracking app.\n\n{raw}"
        )

    try:
        message = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=2048,
            messages=[{"role": "user", "content": prompt}],
        )
    except Exception:
        current_app.logger.exception("Patient profile refine request failed")
        return jsonify({"error": "AI refinement is temporarily unavailable"}), 502
    structured = message.content[0].text

    return jsonify({"structured": structured})


@admin_bp.route("/patient-profile/generate-summary", methods=["POST"])
@require_admin
def patient_profile_generate_summary():
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return jsonify({"error": "ANTHROPIC_API_KEY not configured"}), 400

    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cur.execute("SELECT * FROM patient_profile LIMIT 1")
    profile = cur.fetchone()
    if not profile:
        return jsonify({"error": "No patient profile found"}), 404

    cur.execute(
        "SELECT name, default_dose_mg, category FROM medication_definitions "
        "WHERE is_active = TRUE ORDER BY name"
    )
    medications = cur.fetchall()

    parts = []
    if profile.get("name"):
        parts.append(f"Name: {profile['name']}")
    if profile.get("date_of_birth"):
        parts.append(f"Date of birth: {profile['date_of_birth']}")
    if profile.get("gender"):
        parts.append(f"Gender: {profile['gender']}")
    if medications:
        med_list = ", ".join(f"{m['name']} {m['default_dose_mg']}mg ({m['category']})" for m in medications)
        parts.append(f"Tracked medications: {med_list}")
    if profile.get("other_medications"):
        parts.append(f"Other medications: {profile['other_medications']}")
    history = profile.get("medical_history_structured") or profile.get("medical_history_raw")
    if history:
        parts.append(f"Medical history:\n{history}")

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
    try:
        message = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=1024,
            messages=[{"role": "user", "content": (
                "Synthesize the following patient information into a concise, prompt-ready "
                "summary paragraph suitable for injection into an AI health analysis prompt. "
                "Include all clinically relevant details. Be factual and concise.\n\n"
                + "\n".join(parts)
            )}],
        )
    except Exception:
        current_app.logger.exception("Patient summary generation failed")
        return jsonify({"error": "Summary generation is temporarily unavailable"}), 502
    summary = message.content[0].text

    return jsonify({"summary": summary})


# ---------------------------------------------------------------------------
# Psychiatrist Profile
# ---------------------------------------------------------------------------


@admin_bp.route("/psychiatrist-profile", methods=["GET", "POST"])
@require_admin
def psychiatrist_profile():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        name = request.form.get("name", "").strip()
        location = request.form.get("location", "").strip()
        profile_summary = request.form.get("profile_summary", "").strip() or None

        if not name or not location:
            flash("Name and location are required.", "error")
            return redirect(url_for("admin.psychiatrist_profile"))

        cur.execute("SELECT id FROM psychiatrist_profile LIMIT 1")
        existing = cur.fetchone()

        if existing:
            cur.execute(
                "UPDATE psychiatrist_profile SET name = %s, location = %s, "
                "profile_summary = %s, updated_at = NOW() WHERE id = %s",
                (name, location, profile_summary, existing["id"]),
            )
        else:
            cur.execute(
                "INSERT INTO psychiatrist_profile (name, location, profile_summary) "
                "VALUES (%s, %s, %s)",
                (name, location, profile_summary),
            )
        db.commit()
        flash("Psychiatrist profile saved.", "success")
        return redirect(url_for("admin.psychiatrist_profile"))

    cur.execute("SELECT * FROM psychiatrist_profile LIMIT 1")
    profile = cur.fetchone() or {}

    return render_template("psychiatrist_profile.html", profile=profile)


@admin_bp.route("/psychiatrist-profile/research", methods=["POST"])
@require_admin
def psychiatrist_profile_research():
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return jsonify({"error": "ANTHROPIC_API_KEY not configured"}), 400

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Invalid or missing JSON body"}), 400
    name = (data.get("name") or "").strip()
    location = (data.get("location") or "").strip()

    if not name or not location:
        return jsonify({"error": "Name and location required"}), 400

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
    try:
        message = client.messages.create(
            model="claude-opus-4-7",
            max_tokens=4096,
            tools=[{"type": "web_search_20250305", "name": "web_search"}],
            messages=[{"role": "user", "content": (
                f"Research this psychiatrist: {name}, located in/near {location}. "
                "Find their credentials, board certifications, medical school, specialty areas, "
                "treatment philosophy (if publicly stated), published research, and any public "
                "disciplinary records or malpractice history. Use reliable sources. Cite each finding. "
                "Return your findings as a JSON object with keys: credentials, medical_school, "
                "board_certifications, specialty, treatment_philosophy, publications, "
                "disciplinary_history, sources."
            )}],
        )
    except Exception:
        current_app.logger.exception("Psychiatrist research request failed")
        return jsonify({"error": "Psychiatrist research is temporarily unavailable"}), 502

    # Extract text from response (may have tool_use blocks interspersed)
    text_parts = [block.text for block in message.content if hasattr(block, "text")]
    research_text = "\n".join(text_parts)

    # Web search citations insert literal newlines inside JSON string values,
    # making standard json.loads fail. Use parse_llm_json to handle this.
    from json_helpers import parse_llm_json
    research_result = parse_llm_json(research_text)

    if research_result is None:
        research_result = {"raw_response": research_text}

    # Save to DB
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT id FROM psychiatrist_profile LIMIT 1")
    existing = cur.fetchone()

    if existing:
        cur.execute(
            "UPDATE psychiatrist_profile SET name = %s, location = %s, "
            "research_result = %s, researched_at = NOW(), "
            "updated_at = NOW() WHERE id = %s",
            (name, location, json.dumps(research_result), existing["id"]),
        )
    else:
        cur.execute(
            "INSERT INTO psychiatrist_profile (name, location, research_result, researched_at) "
            "VALUES (%s, %s, %s, NOW())",
            (name, location, json.dumps(research_result)),
        )
    db.commit()

    return jsonify({"research_result": research_result})


@admin_bp.route("/psychiatrist-profile/generate-summary", methods=["POST"])
@require_admin
def psychiatrist_profile_generate_summary():
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return jsonify({"error": "ANTHROPIC_API_KEY not configured"}), 400

    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cur.execute("SELECT * FROM psychiatrist_profile LIMIT 1")
    profile = cur.fetchone()
    if not profile:
        return jsonify({"error": "No psychiatrist profile found"}), 404

    research = profile.get("research_result")
    if not research:
        return jsonify({"error": "No research results to summarize. Run research first."}), 400

    parts = []
    if profile.get("name"):
        parts.append(f"Name: {profile['name']}")
    if profile.get("location"):
        parts.append(f"Location: {profile['location']}")

    if isinstance(research, dict) and "raw_response" not in research:
        for key, value in research.items():
            if value and key != "sources":
                label = key.replace("_", " ").title()
                if isinstance(value, list):
                    items = [json.dumps(v) if isinstance(v, dict) else str(v) for v in value]
                    parts.append(f"{label}: {'; '.join(items)}")
                else:
                    parts.append(f"{label}: {value}")
    else:
        raw = research.get("raw_response", "") if isinstance(research, dict) else str(research)
        parts.append(f"Research findings:\n{raw[:3000]}")

    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
    try:
        message = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=1024,
            messages=[{"role": "user", "content": (
                "Synthesize the following psychiatrist information into a concise, prompt-ready "
                "summary paragraph suitable for injection into an AI health analysis prompt. "
                "Include credentials, specialty, treatment approach, and any notable details. "
                "This summary helps the AI understand the psychiatrist's perspective when "
                "analyzing a patient's health data. Be factual and concise.\n\n"
                + "\n".join(parts)
            )}],
        )
    except Exception:
        current_app.logger.exception("Psychiatrist summary generation failed")
        return jsonify({"error": "Summary generation is temporarily unavailable"}), 502

    text_parts = [block.text for block in message.content if hasattr(block, "text")]
    summary = "\n".join(text_parts)
    return jsonify({"summary": summary})


# ---------------------------------------------------------------------------
# Conflicts
# ---------------------------------------------------------------------------


@admin_bp.route("/conflicts")
@require_admin
def conflicts():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cur.execute(
        "SELECT id, status, description, created_at, resolved_at "
        "FROM conflicts ORDER BY "
        "CASE WHEN status = 'active' THEN 0 ELSE 1 END, created_at DESC"
    )
    conflict_list = cur.fetchall()

    return render_template("conflicts.html", conflicts=conflict_list)


@admin_bp.route("/conflicts/new", methods=["GET", "POST"])
@require_admin
def conflict_new():
    if request.method == "POST":
        description = request.form.get("description", "").strip()
        if not description:
            flash("Description is required.", "error")
            return redirect(url_for("admin.conflict_new"))
        db = get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO conflicts (description, patient_perspective, patient_assumptions, "
            "patient_desired_resolution, patient_wants_from_other, "
            "psychiatrist_perspective, psychiatrist_assumptions, "
            "psychiatrist_desired_resolution, psychiatrist_wants_from_other, "
            "additional_context) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (
                description,
                request.form.get("patient_perspective", "").strip() or None,
                request.form.get("patient_assumptions", "").strip() or None,
                request.form.get("patient_desired_resolution", "").strip() or None,
                request.form.get("patient_wants_from_other", "").strip() or None,
                request.form.get("psychiatrist_perspective", "").strip() or None,
                request.form.get("psychiatrist_assumptions", "").strip() or None,
                request.form.get("psychiatrist_desired_resolution", "").strip() or None,
                request.form.get("psychiatrist_wants_from_other", "").strip() or None,
                request.form.get("additional_context", "").strip() or None,
            ),
        )
        conflict_id = cur.fetchone()[0]
        db.commit()
        flash("Conflict created.", "success")
        return redirect(url_for("admin.conflict_detail", conflict_id=conflict_id))

    return render_template("conflict_detail.html", conflict={}, is_new=True)


@admin_bp.route("/conflicts/<int:conflict_id>", methods=["GET", "POST"])
@require_admin
def conflict_detail(conflict_id):
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        action = request.form.get("action")

        if action == "resolve":
            cur.execute(
                "UPDATE conflicts SET status = 'resolved', resolved_at = NOW(), "
                "updated_at = NOW() WHERE id = %s",
                (conflict_id,),
            )
            db.commit()
            flash("Conflict marked as resolved.", "success")
        elif action == "reopen":
            cur.execute(
                "UPDATE conflicts SET status = 'active', resolved_at = NULL, "
                "updated_at = NOW() WHERE id = %s",
                (conflict_id,),
            )
            db.commit()
            flash("Conflict reopened.", "success")
        else:
            # Save form fields
            description = request.form.get("description", "").strip()
            if not description:
                flash("Description is required.", "error")
                return redirect(url_for("admin.conflict_detail", conflict_id=conflict_id))
            cur.execute(
                "UPDATE conflicts SET description = %s, "
                "patient_perspective = %s, patient_assumptions = %s, "
                "patient_desired_resolution = %s, patient_wants_from_other = %s, "
                "psychiatrist_perspective = %s, psychiatrist_assumptions = %s, "
                "psychiatrist_desired_resolution = %s, psychiatrist_wants_from_other = %s, "
                "additional_context = %s, updated_at = NOW() WHERE id = %s",
                (
                    description,
                    request.form.get("patient_perspective", "").strip() or None,
                    request.form.get("patient_assumptions", "").strip() or None,
                    request.form.get("patient_desired_resolution", "").strip() or None,
                    request.form.get("patient_wants_from_other", "").strip() or None,
                    request.form.get("psychiatrist_perspective", "").strip() or None,
                    request.form.get("psychiatrist_assumptions", "").strip() or None,
                    request.form.get("psychiatrist_desired_resolution", "").strip() or None,
                    request.form.get("psychiatrist_wants_from_other", "").strip() or None,
                    request.form.get("additional_context", "").strip() or None,
                    conflict_id,
                ),
            )
            db.commit()
            flash("Conflict saved.", "success")

        return redirect(url_for("admin.conflict_detail", conflict_id=conflict_id))

    cur.execute("SELECT * FROM conflicts WHERE id = %s", (conflict_id,))
    conflict = cur.fetchone()
    if not conflict:
        flash("Conflict not found.", "error")
        return redirect(url_for("admin.conflicts"))

    return render_template("conflict_detail.html", conflict=conflict, is_new=False)


# ---------------------------------------------------------------------------
# AI Analysis
# ---------------------------------------------------------------------------


@admin_bp.route("/analysis")
@require_admin
def analysis():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    from analysis import list_analyses, sweep_stale_analyses
    sweep_stale_analyses(db)
    analyses = list_analyses(cur)

    # Get date range across all analysis-relevant tables using index-friendly
    # MIN/MAX per table, then convert timestamps to UTC dates in Python.
    cur.execute(
        """
        SELECT
            (SELECT MIN(timestamp) FROM anxiety_entries) AS anxiety_min,
            (SELECT MAX(timestamp) FROM anxiety_entries) AS anxiety_max,
            (SELECT MIN(timestamp) FROM medication_doses) AS med_min,
            (SELECT MAX(timestamp) FROM medication_doses) AS med_max,
            (SELECT MIN(date) FROM cpap_sessions) AS cpap_min,
            (SELECT MAX(date) FROM cpap_sessions) AS cpap_max,
            (SELECT MIN(date) FROM health_snapshots) AS health_min,
            (SELECT MAX(date) FROM health_snapshots) AS health_max,
            (SELECT MIN(timestamp) FROM barometric_readings) AS baro_min,
            (SELECT MAX(timestamp) FROM barometric_readings) AS baro_max
        """
    )
    date_range = cur.fetchone()

    from datetime import date as date_type, datetime as dt_type, timedelta, timezone

    def _to_date(val):
        if val is None:
            return None
        if isinstance(val, dt_type):
            return val.astimezone(timezone.utc).date() if val.tzinfo else val.date()
        return val

    all_dates = [_to_date(date_range[k]) for k in date_range if date_range[k] is not None]
    if all_dates:
        min_date = min(all_dates)
        max_date = max(all_dates)
    else:
        max_date = date_type.today()
        min_date = max_date - timedelta(days=30)

    # Check for active conflict
    cur.execute(
        "SELECT id, description FROM conflicts "
        "WHERE status = 'active' ORDER BY created_at DESC LIMIT 1"
    )
    active_conflict = cur.fetchone()

    from analysis import MODEL, MODEL_CHOICES
    return render_template(
        "analysis.html",
        analyses=analyses,
        min_date=min_date,
        max_date=max_date,
        default_model=MODEL,
        model_choices=[(m[0], m[1]) for m in MODEL_CHOICES],
        active_conflict=active_conflict,
    )


@admin_bp.route("/analysis/run", methods=["POST"])
@require_admin
def analysis_run():
    import os
    from datetime import date

    if not os.environ.get("ANTHROPIC_API_KEY"):
        flash("ANTHROPIC_API_KEY not configured.", "error")
        return redirect(url_for("admin.analysis"))

    date_from_str = request.form.get("date_from", "")
    date_to_str = request.form.get("date_to", "")

    try:
        date_from = date.fromisoformat(date_from_str)
        date_to = date.fromisoformat(date_to_str)
    except (ValueError, TypeError):
        flash("Invalid date range.", "error")
        return redirect(url_for("admin.analysis"))

    if date_from > date_to:
        flash("Start date must be before end date.", "error")
        return redirect(url_for("admin.analysis"))

    dose_tracking_incomplete = "dose_tracking_incomplete" in request.form
    detailed_output = "detailed_output" in request.form

    from analysis import MODEL, ALLOWED_MODELS
    model = request.form.get("model", MODEL)
    if model not in ALLOWED_MODELS:
        model = MODEL

    # A hidden field "conflict_toggle_shown" is set when the checkbox was
    # rendered.  If absent, the form didn't offer the toggle → default True.
    if "conflict_toggle_shown" in request.form:
        include_conflict = "include_conflict" in request.form
    else:
        include_conflict = True

    db = get_db()
    try:
        from analysis import start_analysis
        database_url = current_app.config.get("DATABASE_URL") or os.environ.get("DATABASE_URL")
        analysis_id = start_analysis(
            db, date_from, date_to,
            database_url=database_url,
            dose_tracking_incomplete=dose_tracking_incomplete,
            detailed_output=detailed_output,
            model=model,
            include_conflict=include_conflict,
        )
        return redirect(url_for("admin.analysis_detail", analysis_id=analysis_id))
    except Exception:
        current_app.logger.exception("Failed to start analysis")
        flash("Failed to start analysis. Check server logs for details.", "error")
        return redirect(url_for("admin.analysis"))


@admin_bp.route("/analysis/<int:analysis_id>")
@require_admin
def analysis_detail(analysis_id):
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    from analysis import get_analysis, sweep_stale_analyses, MODEL_PRICING
    sweep_stale_analyses(db)
    a = get_analysis(cur, analysis_id)
    if a is None:
        flash("Analysis not found.", "error")
        return redirect(url_for("admin.analysis"))

    # Group insights by severity, filtering out any malformed non-dict entries
    insights = [i for i in (a.get("insights") or []) if isinstance(i, dict)]
    high = [i for i in insights if i.get("severity") == "high"]
    medium = [i for i in insights if i.get("severity") == "medium"]
    low = [i for i in insights if i.get("severity") == "low"]

    # Load conflict analysis jobs (if any)
    cur.execute(
        "SELECT * FROM analysis_jobs WHERE analysis_id = %s AND job_type != 'health_analysis' "
        "ORDER BY id",
        (analysis_id,),
    )
    conflict_jobs = cur.fetchall()

    # Organize conflict jobs by type
    conflict_data = {}
    for job in conflict_jobs:
        conflict_data[job["job_type"]] = job

    return render_template(
        "analysis_detail.html",
        a=a,
        high_insights=high,
        medium_insights=medium,
        low_insights=low,
        conflict_jobs=conflict_jobs,
        conflict_data=conflict_data,
        model_pricing=MODEL_PRICING,
    )


DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


@admin_bp.route("/therapy-schedule", methods=["GET", "POST"])
@require_admin
def therapy_schedule():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        frequency = request.form.get("frequency", "weekly")
        day_of_week = request.form.get("day_of_week")
        day_of_month = request.form.get("day_of_month")
        time_of_day = request.form.get("time_of_day", "")
        session_type = request.form.get("session_type", "in-person")
        commute_minutes_raw = request.form.get("commute_minutes", "")
        notes = request.form.get("notes", "").strip() or None

        try:
            commute_minutes = max(0, int(commute_minutes_raw.strip() or 0))
        except ValueError:
            flash("Commute minutes must be a whole number.", "error")
            return redirect(url_for("admin.therapy_schedule"))

        if not time_of_day:
            flash("Time is required.", "error")
            return redirect(url_for("admin.therapy_schedule"))

        cur.execute(
            "INSERT INTO therapy_sessions "
            "(frequency, day_of_week, day_of_month, time_of_day, session_type, commute_minutes, notes) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (
                frequency,
                int(day_of_week) if frequency == "weekly" and day_of_week else None,
                int(day_of_month) if frequency == "monthly" and day_of_month else None,
                time_of_day,
                session_type,
                commute_minutes,
                notes,
            ),
        )
        db.commit()
        flash("Session added.", "success")
        return redirect(url_for("admin.therapy_schedule"))

    cur.execute("SELECT * FROM therapy_sessions WHERE is_active = TRUE ORDER BY day_of_week, time_of_day")
    sessions = cur.fetchall()
    return render_template("therapy_schedule.html", sessions=sessions, day_names=DAY_NAMES)


@admin_bp.route("/therapy-schedule/delete/<int:session_id>", methods=["POST"])
@require_admin
def therapy_schedule_delete(session_id):
    db = get_db()
    cur = db.cursor()
    cur.execute("UPDATE therapy_sessions SET is_active = FALSE WHERE id = %s", (session_id,))
    db.commit()
    flash("Session removed.", "success")
    return redirect(url_for("admin.therapy_schedule"))


@admin_bp.route("/settings", methods=["GET", "POST"])
@require_admin
def app_settings():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        timezone = request.form.get("timezone", "America/Los_Angeles").strip() or "America/Los_Angeles"
        cur.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES ('timezone', %s, NOW()) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            (timezone,),
        )
        db.commit()
        flash("Settings saved.", "success")
        return redirect(url_for("admin.app_settings"))

    cur.execute("SELECT value FROM settings WHERE key = 'timezone'")
    row = cur.fetchone()
    timezone = row["value"] if row else "America/Los_Angeles"
    return render_template("app_settings.html", timezone=timezone)


# ---------------------------------------------------------------------------
# Songs
# ---------------------------------------------------------------------------


@admin_bp.route("/songs")
@require_admin
def admin_songs():
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("""
        SELECT s.*, COUNT(so.id) AS occurrence_count,
               MAX(so.timestamp) AS last_occurrence,
               s.lyrics IS NOT NULL AS has_lyrics
        FROM songs s
        LEFT JOIN song_occurrences so ON so.song_id = s.id
        GROUP BY s.id
        ORDER BY last_occurrence DESC NULLS LAST, s.title
    """)
    songs = cur.fetchall()
    return render_template("songs.html", songs=songs)


@admin_bp.route("/songs/<int:song_id>", methods=["GET", "POST"])
@require_admin
def admin_song_detail(song_id):
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    if request.method == "POST":
        lyrics = request.form.get("lyrics", "").strip() or None
        # If lyrics changed, set source to "manual"
        cur.execute("SELECT lyrics, lyrics_source FROM songs WHERE id = %s", (song_id,))
        old = cur.fetchone()
        lyrics_source = old["lyrics_source"] if old else None
        if lyrics != (old["lyrics"] if old else None):
            lyrics_source = "manual" if lyrics else None

        title = request.form.get("title", "").strip()
        artist = request.form.get("artist", "").strip()
        if not title or not artist:
            flash("Title and artist are required.", "error")
            return redirect(url_for("admin.admin_song_detail", song_id=song_id))

        cur.execute(
            """UPDATE songs SET title = %s, artist = %s, album = %s,
                                lyrics = %s, lyrics_source = %s, updated_at = NOW()
               WHERE id = %s""",
            (
                title,
                artist,
                request.form.get("album", "").strip() or None,
                lyrics,
                lyrics_source,
                song_id,
            ),
        )
        db.commit()
        flash("Song updated.", "success")

    cur.execute("SELECT * FROM songs WHERE id = %s", (song_id,))
    song = cur.fetchone()
    if not song:
        flash("Song not found.", "error")
        return redirect(url_for("admin.admin_songs"))

    cur.execute("""
        SELECT so.*, ae.severity
        FROM song_occurrences so
        LEFT JOIN anxiety_entries ae ON ae.timestamp = so.anxiety_entry_id
        WHERE so.song_id = %s
        ORDER BY so.timestamp DESC
    """, (song_id,))
    occurrences = cur.fetchall()

    return render_template("song_detail.html", song=song, occurrences=occurrences)


@admin_bp.route("/songs/<int:song_id>/refetch-lyrics", methods=["POST"])
@require_admin
def admin_song_refetch_lyrics(song_id):
    db = get_db()
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute("SELECT genius_url FROM songs WHERE id = %s", (song_id,))
    song = cur.fetchone()
    if not song or not song["genius_url"]:
        flash("No Genius URL for this song.", "error")
        return redirect(url_for("admin.admin_song_detail", song_id=song_id))

    from genius import scrape_lyrics
    lyrics = scrape_lyrics(song["genius_url"])
    if lyrics:
        cur.execute(
            "UPDATE songs SET lyrics = %s, lyrics_source = 'genius', updated_at = NOW() WHERE id = %s",
            (lyrics, song_id),
        )
        db.commit()
        flash("Lyrics re-fetched from Genius.", "success")
    else:
        flash("Could not fetch lyrics from Genius.", "error")
    return redirect(url_for("admin.admin_song_detail", song_id=song_id))


BROWSABLE_TABLES = {
    "anxiety_entries": {"order": "timestamp DESC", "label": "Anxiety Entries"},
    "medication_definitions": {"order": "name", "label": "Medication Definitions"},
    "medication_doses": {"order": "timestamp DESC", "label": "Medication Doses"},
    "cpap_sessions": {"order": "date DESC", "label": "CPAP Sessions"},
    "health_snapshots": {"order": "date DESC", "label": "Health Snapshots"},
    "barometric_readings": {"order": "timestamp DESC", "label": "Barometric Readings"},
    "pharmacies": {"order": "name", "label": "Pharmacies"},
    "prescriptions": {"order": "date_filled DESC", "label": "Prescriptions"},
    "pharmacy_call_logs": {"order": "timestamp DESC", "label": "Pharmacy Call Logs"},
    "sync_log": {"order": "received_at DESC", "label": "Sync Log"},
    "patient_profile": {"order": "updated_at DESC", "label": "Patient Profile"},
    "psychiatrist_profile": {"order": "updated_at DESC", "label": "Psychiatrist Profile"},
    "conflicts": {"order": "created_at DESC", "label": "Conflicts"},
    "analysis_jobs": {"order": "created_at DESC", "label": "Analysis Jobs"},
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

    # `table` is validated against the BROWSABLE_TABLES whitelist above, and
    # "order" is a hardcoded value from that same dict — split into an
    # identifier and a direction keyword (coerced to a known-safe value) so
    # the query is composed via psycopg2.sql rather than f-string
    # interpolation.
    order_col, _, order_dir = BROWSABLE_TABLES[table]["order"].partition(" ")
    order_dir = order_dir if order_dir in ("ASC", "DESC") else "ASC"
    cur.execute(
        sql.SQL("SELECT * FROM {} ORDER BY {} {} LIMIT %s").format(
            sql.Identifier(table), sql.Identifier(order_col), sql.SQL(order_dir)
        ),
        (limit,),
    )
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
