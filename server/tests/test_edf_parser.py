"""Tests for EDF parser — uses mock data since real EDF files are large."""

from unittest.mock import MagicMock
from datetime import datetime

from edf_parser import upsert_cpap_leak


class TestUpsertCpapLeak:
    """Tests for the upsert logic (no EDF dependency)."""

    def _make_mock_conn(self):
        """Create a mock DB connection."""
        conn = MagicMock()
        cur = MagicMock()
        conn.cursor.return_value = cur
        cur.rowcount = 0
        cur.fetchone.return_value = None
        return conn, cur

    def test_empty_sessions(self):
        conn, _ = self._make_mock_conn()
        result = upsert_cpap_leak(conn, [])
        assert result == 0

    def test_none_leak_skipped(self):
        conn, cur = self._make_mock_conn()
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": None},
        ])
        assert result == 0

    def test_updates_existing_null_leak(self):
        conn, cur = self._make_mock_conn()
        # Simulate: UPDATE sets rowcount=1 (found a row with NULL leak)
        cur.rowcount = 1
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
        ])
        assert result == 1

    def test_skips_existing_with_leak(self):
        conn, cur = self._make_mock_conn()
        # UPDATE affects 0 rows (leak already set), but row exists
        cur.rowcount = 0
        cur.fetchone.return_value = (1,)  # row exists
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
        ])
        assert result == 0

    def test_inserts_new_row_when_no_existing(self):
        conn, cur = self._make_mock_conn()
        # UPDATE affects 0, no existing row, INSERT succeeds
        cur.rowcount = 0
        cur.fetchone.return_value = None  # no existing row

        # Track execute calls and set rowcount=1 after the INSERT (3rd call)
        execute_calls = []

        def tracking_execute(*args, **kwargs):
            execute_calls.append(args)
            # After INSERT, set rowcount to 1
            if len(execute_calls) == 3:  # UPDATE, SELECT, INSERT
                cur.rowcount = 1

        cur.execute = tracking_execute

        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3,
             "total_usage_minutes": 420},
        ])
        assert result == 1

    def test_multiple_sessions(self):
        conn, cur = self._make_mock_conn()
        # Both updates succeed
        cur.rowcount = 1
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
            {"date": datetime(2024, 1, 2), "leak_rate_95th": 18.7},
        ])
        assert result == 2
