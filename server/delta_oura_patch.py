import base64
import time
import psycopg2.extras
from psycopg2 import sql
import hmac
import hashlib
import os
import json
import requests
from datetime import datetime, timezone, timedelta


def fetch_and_persist_oura_data(token_row, event_data, db_conn, http_client=requests):
    """
    Test-callable function to fetch and persist Oura data.
    """
    now = datetime.now(timezone.utc)
    expires_at = token_row['expires_at']
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)

    if expires_at < now:
        client_id = os.environ.get('OURA_CLIENT_ID', '')
        client_secret = os.environ.get('OURA_CLIENT_SECRET', '')
        refresh_bytes = token_row['refresh_token']
        refresh_str = refresh_bytes.decode('utf-8') if isinstance(refresh_bytes, bytes) else refresh_bytes

        resp = http_client.post("https://api.ouraring.com/oauth/token", data={
            "grant_type": "refresh_token",
            "refresh_token": refresh_str,
            "client_id": client_id,
            "client_secret": client_secret
        })
        if resp.status_code == 200:
            token_data = resp.json()
            new_access = token_data['access_token']
            new_refresh = token_data['refresh_token']
            expires_in = token_data.get('expires_in', 86400)
            new_expires = now + timedelta(seconds=expires_in)

            with db_conn.cursor() as cur:
                cur.execute("""
                    UPDATE oura_credentials
                    SET access_token = %s, refresh_token = %s, expires_at = %s, updated_at = %s
                    WHERE id = %s
                """, (new_access.encode('utf-8'), new_refresh.encode('utf-8'), new_expires, now, token_row['id']))
            db_conn.commit()

            token_row['access_token'] = new_access.encode('utf-8')
            token_row['refresh_token'] = new_refresh.encode('utf-8')
            token_row['expires_at'] = new_expires
        else:
            return False

    access_bytes = token_row['access_token']
    access_str = access_bytes.decode('utf-8') if isinstance(access_bytes, bytes) else access_bytes

    data_type = event_data.get('data_type')
    if not data_type:
        return False

    url = f"https://api.ouraring.com/v2/usercollection/{data_type}"
    headers = {"Authorization": f"Bearer {access_str}"}
    params = {}
    if 'start_date' in event_data:
        params['start_date'] = event_data['start_date']
    if 'end_date' in event_data:
        params['end_date'] = event_data['end_date']

    resp = http_client.get(url, headers=headers, params=params)
    if resp.status_code != 200:
        return False

    data_list = resp.json().get('data', [])
    if not data_list:
        return True

    with db_conn.cursor() as cur:
        for item in data_list:
            if data_type == 'sleep':
                day = item.get('day')
                doc_id = item.get('id', f"sleep_{day}")
                stages = json.dumps(item.get('sleep_phase_5_min', ''))
                hr_var = item.get('heart_rate_variability', {})
                hrv = hr_var.get('5_min', []) if isinstance(hr_var, dict) else []
                rr = item.get('respiratory_rate_5_min', [])
                resp_rate = item.get('average_respiratory_rate')
                efficiency = item.get('efficiency')
                latency = item.get('latency')

                cur.execute("""
                    INSERT INTO oura_sleep
                    (day, stages_hypnogram, hrv_5min, rr, resp_rate, efficiency, latency, document_id)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (day) DO UPDATE SET
                        stages_hypnogram = EXCLUDED.stages_hypnogram,
                        hrv_5min = EXCLUDED.hrv_5min,
                        rr = EXCLUDED.rr,
                        resp_rate = EXCLUDED.resp_rate,
                        efficiency = EXCLUDED.efficiency,
                        latency = EXCLUDED.latency,
                        document_id = EXCLUDED.document_id
                """, (day, stages, hrv, rr, resp_rate, efficiency, latency, doc_id))
            elif data_type == 'heartrate':
                ts = item.get('timestamp')
                bpm = item.get('bpm')
                source = item.get('source', '')
                cur.execute("""
                    INSERT INTO oura_heartrate (ts, bpm, source)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (ts) DO NOTHING
                """, (ts, bpm, source))
            elif data_type == 'interbeat_interval':
                ts = item.get('timestamp')
                ibi_ms = item.get('ibi')
                validity = item.get('validity', 0)
                cur.execute("""
                    INSERT INTO oura_ibi (ts, ibi_ms, validity)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (ts) DO NOTHING
                """, (ts, ibi_ms, validity))
            elif data_type in [
                'daily_readiness', 'daily_resilience', 'daily_stress', 'daily_spo2',
                'daily_cardiovascular_age', 'vo2_max'
            ]:
                day = item.get('day')
                doc_id = item.get('id', f"{data_type}_{day}")

                cur.execute("""
                    INSERT INTO oura_daily (day, document_id)
                    VALUES (%s, %s)
                    ON CONFLICT (day) DO NOTHING
                """, (day, doc_id))

                if data_type == 'daily_readiness':
                    cur.execute("UPDATE oura_daily SET readiness = %s, temp_deviation_c = %s WHERE day = %s",
                                (item.get('score'), item.get('temperature_deviation'), day))
                elif data_type == 'daily_resilience':
                    cur.execute("UPDATE oura_daily SET resilience_level = %s WHERE day = %s",
                                (item.get('resilience_level'), day))
                elif data_type == 'daily_stress':
                    cur.execute("UPDATE oura_daily SET stress_high_s = %s, recovery_high_s = %s WHERE day = %s",
                                (item.get('stress_high'), item.get('recovery_high'), day))
                elif data_type == 'daily_spo2':
                    pct = item.get('percentage', {})
                    spo2_avg = pct.get('average') if isinstance(pct, dict) else None
                    cur.execute("UPDATE oura_daily SET spo2_avg = %s WHERE day = %s",
                                (spo2_avg, day))
                elif data_type == 'daily_cardiovascular_age':
                    cur.execute("UPDATE oura_daily SET vascular_age = %s WHERE day = %s",
                                (item.get('vascular_age'), day))
                elif data_type == 'vo2_max':
                    cur.execute("UPDATE oura_daily SET vo2_max = %s WHERE day = %s",
                                (item.get('vo2_max'), day))
    db_conn.commit()
    return True


def apply_patch(app, get_db, require_api_key):
    def _base64_to_bytes(s):
        return base64.b64decode(s) if s else b''

    def _bytes_to_base64(b):
        return base64.b64encode(b).decode('ascii') if b else ''

    SERVER_NODE_ID = b'\x00'*16

    def _server_hlc_now():
        return {
            "physical": int(time.time() * 1000),
            "logical": 0,
            "nodeId": _bytes_to_base64(SERVER_NODE_ID)
        }

    @app.route("/api/sync/pull", methods=["POST"])
    @app.route("/sync/pull", methods=["POST"])
    @require_api_key
    def sync_pull():
        from flask import request, jsonify
        data = request.get_json(silent=True) or {}
        if data.get("cursor_format_version") != 2:
            return jsonify({"error": "CursorFormatMismatch"}), 409

        table_cursors = data.get("table_cursors", {})
        db = get_db()
        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        resp_rows = {"samples": [], "sample_tombstones": [], "sync_log": []}
        next_cursors = {"samples": {"perNode": {}}, "sample_tombstones": {"perNode": {}}, "sync_log": {"perNode": {}}}
        batch_size = data.get("max_batch_bytes", 1000)  # simplified limit logic
        if batch_size > 5000:
            batch_size = 5000

        tables_map = {
            "samples": "samples",
            "sample_tombstones": "sample_tombstones",
            "sync_log": "delta_sync_log"
        }

        for table_key, table_name in tables_map.items():
            t_cursor = table_cursors.get(table_key, {}).get("perNode", {})
            norm_cursor = {}
            if isinstance(t_cursor, dict):
                norm_cursor = t_cursor
            elif isinstance(t_cursor, list):
                for i in range(0, len(t_cursor), 2):
                    norm_cursor[t_cursor[i]] = t_cursor[i+1]

            known_nodes = []
            for node_b64, clk in norm_cursor.items():
                node_bytes = _base64_to_bytes(node_b64)
                known_nodes.append(node_bytes)
                pt = clk.get("physical", 0)
                lc = clk.get("logical", 0)

                query = sql.SQL("""
                    SELECT * FROM {}
                    WHERE node_id = %s
                      AND (hlc_physical > %s OR (hlc_physical = %s AND hlc_logical > %s))
                    ORDER BY hlc_physical, hlc_logical
                    LIMIT %s
                """).format(sql.Identifier(table_name))
                cur.execute(query, (node_bytes, pt, pt, lc, batch_size))

                rows = cur.fetchall()
                for r in rows:
                    r['node_id'] = _bytes_to_base64(r['node_id'])
                    if 'extra' in r and r['extra'] is not None:
                        r['extra'] = _bytes_to_base64(r['extra'])
                    resp_rows[table_key].append(r)

            table_identifier = sql.Identifier(table_name)
            if known_nodes:
                query = sql.SQL("""
                    SELECT * FROM {}
                    WHERE node_id != ALL(%s)
                    ORDER BY hlc_physical, hlc_logical
                    LIMIT %s
                """).format(table_identifier)
                cur.execute(query, (known_nodes, batch_size))
            else:
                query = sql.SQL("""
                    SELECT * FROM {}
                    ORDER BY hlc_physical, hlc_logical
                    LIMIT %s
                """).format(table_identifier)
                cur.execute(query, (batch_size,))

            boot_rows = cur.fetchall()
            for r in boot_rows:
                r['node_id'] = _bytes_to_base64(r['node_id'])
                if 'extra' in r and r['extra'] is not None:
                    r['extra'] = _bytes_to_base64(r['extra'])
                resp_rows[table_key].append(r)

            for node_b64, clk in norm_cursor.items():
                next_cursors[table_key]["perNode"][node_b64] = clk

            for r in resp_rows[table_key]:
                n_b64 = r['node_id']
                pt = r['hlc_physical']
                lc = r['hlc_logical']
                curr = next_cursors[table_key]["perNode"].get(n_b64, {"physical": 0, "logical": 0})
                if pt > curr["physical"] or (pt == curr["physical"] and lc > curr["logical"]):
                    next_cursors[table_key]["perNode"][n_b64] = {"physical": pt, "logical": lc}

        return jsonify({
            "rows": resp_rows,
            "next_cursor": next_cursors,
            "server_hlc": _server_hlc_now()
        })

    @app.route("/api/sync/push", methods=["POST"])
    @app.route("/sync/push", methods=["POST"])
    @require_api_key
    def sync_push():
        from flask import request, jsonify
        data = request.get_json(silent=True) or {}
        rows = data.get("rows", {})

        db = get_db()
        cur = db.cursor()

        ack_cursors = {"samples": {"perNode": {}}, "sample_tombstones": {"perNode": {}}, "sync_log": {"perNode": {}}}

        def update_ack(table_key, node_b64, pt, lc):
            if not node_b64:
                return
            curr = ack_cursors[table_key]["perNode"].get(node_b64, {"physical": 0, "logical": 0})
            if pt > curr["physical"] or (pt == curr["physical"] and lc > curr["logical"]):
                ack_cursors[table_key]["perNode"][node_b64] = {"physical": pt, "logical": lc}

        for r in rows.get("samples", []):
            cur.execute("""
                INSERT INTO samples (source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (source, type, timestamp) DO UPDATE SET
                    value = EXCLUDED.value,
                    extra = EXCLUDED.extra,
                    hlc_physical = EXCLUDED.hlc_physical,
                    hlc_logical = EXCLUDED.hlc_logical,
                    node_id = EXCLUDED.node_id
            """, (
                r.get("source"), r.get("type"), r.get("timestamp"), r.get("value"),
                _base64_to_bytes(r.get("extra")), r.get("hlc_physical"), r.get(
                    "hlc_logical"), _base64_to_bytes(r.get("node_id"))
            ))
            update_ack("samples", r.get("node_id"), r.get("hlc_physical"), r.get("hlc_logical"))

        for r in rows.get("sample_tombstones", []):
            cur.execute("""
                INSERT INTO sample_tombstones
                    (source, type, ts_start, ts_end, hlc_physical, hlc_logical,
                     node_id, dropped_row_count, reason)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (source, type, ts_start, hlc_physical, hlc_logical, node_id) DO NOTHING
            """, (
                r.get("source"), r.get("type"), r.get("ts_start"), r.get("ts_end"),
                r.get("hlc_physical"), r.get("hlc_logical"), _base64_to_bytes(r.get("node_id")),
                r.get("dropped_row_count"), r.get("reason")
            ))
            update_ack("sample_tombstones", r.get("node_id"), r.get("hlc_physical"), r.get("hlc_logical"))

        for r in rows.get("sync_log", []):
            cur.execute("""
                INSERT INTO delta_sync_log (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
                VALUES (%s, %s, %s, %s, %s, %s)
                ON CONFLICT (table_name, row_pk) DO UPDATE SET
                    hlc_physical = EXCLUDED.hlc_physical,
                    hlc_logical = EXCLUDED.hlc_logical,
                    node_id = EXCLUDED.node_id,
                    operation = EXCLUDED.operation
            """, (
                r.get("table_name"), r.get("row_pk"), r.get("hlc_physical"), r.get("hlc_logical"),
                _base64_to_bytes(r.get("node_id")), r.get("operation")
            ))
            update_ack("sync_log", r.get("node_id"), r.get("hlc_physical"), r.get("hlc_logical"))

        db.commit()
        return jsonify({
            "ack_cursor": ack_cursors,
            "server_hlc": _server_hlc_now()
        })

    @app.route("/api/oura/auth", methods=["POST"])
    @require_api_key
    def oura_auth():
        from flask import request, jsonify
        from datetime import datetime

        data = request.get_json(silent=True) or {}
        access_token = data.get("access_token")
        refresh_token = data.get("refresh_token")
        expires_at_str = data.get("expires_at")

        if not access_token or not refresh_token or not expires_at_str:
            return jsonify({"error": "Missing required fields"}), 400

        try:
            expires_at = datetime.fromisoformat(expires_at_str.replace('Z', '+00:00'))
        except ValueError:
            return jsonify({"error": "Invalid expires_at format"}), 400

        db = get_db()
        oura_user_id = 'default'
        scope = data.get("scope", "all")

        with db.cursor() as cur:
            cur.execute("""
                INSERT INTO oura_credentials (oura_user_id, access_token, refresh_token, expires_at, scope)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (oura_user_id) DO UPDATE SET
                    access_token = EXCLUDED.access_token,
                    refresh_token = EXCLUDED.refresh_token,
                    expires_at = EXCLUDED.expires_at,
                    updated_at = NOW()
            """, (oura_user_id, access_token.encode('utf-8'), refresh_token.encode('utf-8'), expires_at, scope))
        db.commit()

        app.logger.info(f"Oura auth stored: access_len={len(access_token)}, refresh_len={len(refresh_token)}")
        return jsonify({"status": "ok"}), 200

    OURA_CLIENT_SECRET = os.environ.get("OURA_CLIENT_SECRET", "dummy_secret")

    @app.route("/webhooks/oura", methods=["GET", "POST"])
    def oura_webhook():
        from flask import request, jsonify
        challenge = request.args.get("challenge")
        if challenge:
            return challenge

        signature = request.headers.get("x-oura-signature")
        if not signature:
            return jsonify({"error": "Missing signature"}), 401

        body = request.get_data()
        expected_signature = hmac.new(
            OURA_CLIENT_SECRET.encode("utf-8"),
            body,
            hashlib.sha256
        ).hexdigest()

        if not hmac.compare_digest(signature, expected_signature):
            return jsonify({"error": "Invalid signature"}), 401

        event_data = request.get_json(silent=True) or {}
        app.logger.info(f"Oura webhook received: data_type={event_data.get('data_type')}")

        db = get_db()
        with db.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM oura_credentials WHERE oura_user_id = 'default' LIMIT 1")
            token_row = cur.fetchone()

        if token_row:
            fetch_and_persist_oura_data(token_row, event_data, db)

        return jsonify({"status": "ok"}), 200
