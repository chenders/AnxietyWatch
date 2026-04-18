"""Admin blueprint — login, API key management, data browser."""

import hashlib
import hmac
import json
import os
import re
import secrets
import sys
from functools import wraps

from datetime import date as date_type

import anthropic
import psycopg2.extras
from flask import (
    Blueprint,
    current_app,
    flash,
    jsonify,
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
    secret_key = os.environ.get("SECRET_KEY")
    if not secret_key:
        flash("SECRET_KEY not configured — cannot encrypt credentials.", "error")
        return redirect(url_for("admin.resmed_settings"))

    if request.method == "POST":
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
# Walgreens Settings
# ---------------------------------------------------------------------------


@admin_bp.route("/settings/walgreens", methods=["GET", "POST"])
@require_admin
def walgreens_settings():
    from crypto import encrypt_value

    db = get_db()
    cur = db.cursor()
    secret_key = os.environ.get("SECRET_KEY")
    if not secret_key:
        flash("SECRET_KEY not configured — cannot encrypt credentials.", "error")
        return redirect(url_for("admin.dashboard"))

    if request.method == "POST":
        action = request.form.get("action", "save")
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        security_answer = request.form.get("security_answer", "")
        sync_time = request.form.get("sync_time", "21:00").strip()

        # Validate sync_time (HH or HH:MM, 0-23)
        try:
            hour = int(sync_time.split(":")[0]) if sync_time else -1
            if not (0 <= hour <= 23):
                raise ValueError()
        except (ValueError, IndexError):
            flash("Invalid sync time. Use HH or HH:MM format (0-23).", "error")
            return redirect(url_for("admin.walgreens_settings"))

        # Save username
        if username:
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('walgreens_username', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (username,),
            )

        # Save password (only if provided)
        if password:
            encrypted = encrypt_value(password, secret_key)
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('walgreens_password', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (encrypted,),
            )

        # Save security answer (only if provided)
        if security_answer:
            encrypted = encrypt_value(security_answer, secret_key)
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('walgreens_security_answer', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (encrypted,),
            )

        # Save sync time
        cur.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES ('walgreens_sync_time', %s, NOW()) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            (sync_time,),
        )
        db.commit()
        flash("Settings saved.", "success")

        if action == "sync_now":
            try:
                import subprocess
                result = subprocess.run(
                    ["xvfb-run", "--auto-servernum", sys.executable, "walgreens_sync.py"],
                    capture_output=True, text=True, timeout=180,
                    env={**os.environ},
                )
                if result.returncode == 0:
                    flash(f"Sync completed: {result.stdout.strip()[:500]}", "success")
                else:
                    flash(f"Sync failed (exit {result.returncode}): {result.stderr.strip()[:500]}", "error")
            except Exception as e:
                flash(f"Sync error: {str(e)[:500]}", "error")

        return redirect(url_for("admin.walgreens_settings"))

    # GET — read current settings
    def _get(key):
        cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
        row = cur.fetchone()
        return row[0] if row else None

    username = _get("walgreens_username") or ""
    has_password = _get("walgreens_password") is not None
    has_security_answer = _get("walgreens_security_answer") is not None
    sync_time = _get("walgreens_sync_time") or "21:00"
    last_sync = _get("walgreens_last_sync")
    last_status = _get("walgreens_last_status")

    return render_template(
        "walgreens_settings.html",
        username=username,
        has_password=has_password,
        has_security_answer=has_security_answer,
        sync_time=sync_time,
        last_sync=last_sync,
        last_status=last_status,
    )


# ---------------------------------------------------------------------------
# CapRx Settings
# ---------------------------------------------------------------------------


@admin_bp.route("/settings/caprx", methods=["GET", "POST"])
@require_admin
def caprx_settings():
    from crypto import encrypt_value

    db = get_db()
    cur = db.cursor()
    secret_key = os.environ.get("SECRET_KEY")
    if not secret_key:
        flash("SECRET_KEY not configured — cannot encrypt credentials.", "error")
        return redirect(url_for("admin.dashboard"))

    if request.method == "POST":
        action = request.form.get("action", "save")
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")

        if email:
            encrypted = encrypt_value(email, secret_key)
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('caprx_username', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (encrypted,),
            )

        if password:
            encrypted = encrypt_value(password, secret_key)
            cur.execute(
                "INSERT INTO settings (key, value, updated_at) VALUES ('caprx_password', %s, NOW()) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                (encrypted,),
            )

        db.commit()
        flash("Settings saved.", "success")

        if action == "sync_now":
            try:
                from caprx_sync import run_sync
                status, count = run_sync(conn=db)
                if status == "success":
                    flash(f"Sync completed: {count} prescriptions upserted", "success")
                else:
                    flash(f"Sync failed: {status}", "error")
            except Exception as e:
                flash(f"Sync error: {str(e)[:500]}", "error")

        return redirect(url_for("admin.caprx_settings"))

    # GET
    def _get(key):
        cur.execute("SELECT value FROM settings WHERE key = %s", (key,))
        row = cur.fetchone()
        return row[0] if row else None

    has_email = _get("caprx_username") is not None
    has_password = _get("caprx_password") is not None
    last_sync = _get("caprx_last_sync")
    last_status = _get("caprx_last_status")

    return render_template(
        "caprx_settings.html",
        has_email=has_email,
        has_password=has_password,
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
                        pass

        if total_sessions > 0:
            flash(f"Total: {total_sessions} CPAP session(s) updated with leak data.", "success")

        return redirect(url_for("admin.cpap_upload"))

    return render_template("cpap_upload.html")


# ---------------------------------------------------------------------------
# Prescription Management
# ---------------------------------------------------------------------------


@admin_bp.route("/prescriptions/clear", methods=["POST"])
@require_admin
def clear_prescriptions():
    source = request.form.get("source", "all")
    db = get_db()
    cur = db.cursor()

    if source == "all":
        cur.execute("DELETE FROM prescriptions")
        flash(f"Deleted {cur.rowcount} prescriptions.", "success")
    else:
        cur.execute("DELETE FROM prescriptions WHERE import_source = %s", (source,))
        flash(f"Deleted {cur.rowcount} {source} prescriptions.", "success")

    db.commit()
    return redirect(url_for("admin.caprx_settings"))


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
    # making standard json.loads fail. Use json_repair to handle this.
    research_result = None
    try:
        from json_repair import repair_json

        # Try fenced JSON block first (Claude often wraps in ```json ... ```)
        fence_match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", research_text, re.DOTALL)
        json_text = fence_match.group(1) if fence_match else research_text.strip()
        repaired = repair_json(json_text)
        parsed = json.loads(repaired)
        if isinstance(parsed, dict):
            # Clean citation-artifact newlines from values throughout the parsed JSON.
            def _clean(v):
                if isinstance(v, str):
                    return re.sub(r"\n+", " ", v).strip()
                if isinstance(v, list):
                    return [_clean(x) for x in v]
                if isinstance(v, dict):
                    return {k: _clean(val) for k, val in v.items()}
                return v
            research_result = _clean(parsed)
    except Exception:
        current_app.logger.exception("JSON repair failed, storing raw text")

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
                    parts.append(f"{label}: {'; '.join(str(v) for v in value)}")
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

    summary = message.content[0].text
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

    from analysis import MODEL
    return render_template(
        "analysis.html",
        analyses=analyses,
        min_date=min_date,
        max_date=max_date,
        model_name=MODEL,
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

    db = get_db()
    try:
        from analysis import start_analysis
        database_url = current_app.config.get("DATABASE_URL") or os.environ.get("DATABASE_URL")
        analysis_id = start_analysis(
            db, date_from, date_to,
            database_url=database_url,
            dose_tracking_incomplete=dose_tracking_incomplete,
            detailed_output=detailed_output,
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

    from analysis import get_analysis, sweep_stale_analyses
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
        timezone = request.form.get("timezone", "US/Pacific").strip() or "US/Pacific"
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
    timezone = row["value"] if row else "US/Pacific"
    return render_template("app_settings.html", timezone=timezone)


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
