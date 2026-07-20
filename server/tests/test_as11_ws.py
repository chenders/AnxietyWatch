import json
from datetime import datetime, timezone
from api.as11 import insert_stream_sample
from api.as11_ws import as11_ws_handler
from tests.test_server import app, _clean_tables, _init_db  # noqa: F401


class MockWebSocket:
    def __init__(self):
        self.sent = []
        self.closed = False
        self.close_code = None
        self.close_reason = None

    def send(self, data):
        self.sent.append(data)
        if len(self.sent) >= 1:
            raise Exception('Break loop')

    def receive(self):
        return None

    def close(self, code=None, reason=None):
        self.closed = True
        self.close_code = code
        self.close_reason = reason


def test_as11_ws_auth_rejected(app):
    """An invalid token is rejected."""
    with app.test_request_context('/api/cpap/as11/ws', headers={"Authorization": "Bearer bad"}):
        ws = MockWebSocket()
        as11_ws_handler(ws)
        assert ws.closed
        assert ws.close_code == 1008


def test_as11_ws_with_valid_token_and_since_cursor(app, _clean_tables):
    """A WS client with a valid Bearer token receives buffered rows and state,
    and a `since` cursor replays newer rows."""

    with app.app_context():
        db = app.get_db()
        sample1_id = insert_stream_sample(db, "br-1", datetime.now(timezone.utc), "SPO2", 98.0)
        sample2_id = insert_stream_sample(db, "br-1", datetime.now(timezone.utc), "SPO2", 99.0)

        # We need a valid API key. test_server.py has a fixture or setup that puts one.
        # But wait, app_context is enough to query it?
        with db.cursor() as cur:
            cur.execute("SELECT id, key_hash, is_active FROM api_keys LIMIT 1")
            cur.fetchone()

    # wait fixture usually handles api keys. test_server.py auth_header() uses "test-api-key"
    from tests.test_server import auth_header
    headers = auth_header()

    with app.test_request_context('/api/cpap/as11/ws', headers=headers):
        ws = MockWebSocket()
        as11_ws_handler(ws)
        assert not ws.closed
        assert len(ws.sent) == 1
        data = json.loads(ws.sent[0])
        assert data["state"] == "STREAMING_OK"
        ids = [s["id"] for s in data["samples"]]
        assert sample1_id in ids
        assert sample2_id in ids

    with app.test_request_context(f'/api/cpap/as11/ws?since={sample1_id}', headers=headers):
        ws = MockWebSocket()
        as11_ws_handler(ws)
        assert not ws.closed
        assert len(ws.sent) == 1
        data = json.loads(ws.sent[0])
        assert data["state"] == "STREAMING_OK"
        ids = [s["id"] for s in data["samples"]]
        assert sample1_id not in ids
        assert sample2_id in ids


def test_as11_ws_stalled_state(app, _clean_tables):
    from datetime import timedelta
    with app.app_context():
        db = app.get_db()
        sample1_id = insert_stream_sample(db, "br-1", datetime.now(timezone.utc) - timedelta(seconds=20), "SPO2", 98.0)

    from tests.test_server import auth_header
    headers = auth_header()

    with app.test_request_context(f'/api/cpap/as11/ws?since={sample1_id}', headers=headers):
        ws = MockWebSocket()
        as11_ws_handler(ws)
        data = json.loads(ws.sent[0])
        assert data["state"] == "STREAM_STALLED"
