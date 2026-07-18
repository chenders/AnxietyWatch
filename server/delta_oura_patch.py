import base64
import time
import psycopg2.extras
from psycopg2 import sql
import hmac
import hashlib
import os


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
        app.logger.info(f"Oura webhook received: {event_data}")

        # Worker implementation stub (background worker for token refresh & fetch)
        # Typically enqueues an asynchronous task to pull the actual data from the API

        return jsonify({"status": "ok"}), 200
