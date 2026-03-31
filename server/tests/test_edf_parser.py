"""Tests for EDF parser — uses mock data since real EDF files are large."""

from datetime import datetime, date
from unittest.mock import MagicMock

import numpy as np

from edf_parser import _extract_sessions, upsert_cpap_leak


# ---------------------------------------------------------------------------
# _extract_sessions tests (mocked EdfReader)
# ---------------------------------------------------------------------------


class TestExtractSessions:
    """Tests for _extract_sessions with a mocked EDF reader."""

    def _make_reader(self, labels, signals, start_dt, duration_sec):
        reader = MagicMock()
        reader.signals_in_file = len(labels)
        reader.getSignalLabels.return_value = labels
        reader.getStartdatetime.return_value = start_dt
        reader.getFileDuration.return_value = duration_sec

        def read_signal(idx):
            return np.array(signals[idx])

        reader.readSignal = read_signal
        return reader

    def test_extracts_leak_95th(self):
        # 100 samples: 0..99. 95th percentile = 94.05
        leak_signal = list(range(100))
        reader = self._make_reader(
            labels=["Pressure", "Leak", "Flow"],
            signals=[[], leak_signal, []],
            start_dt=datetime(2024, 3, 15, 23, 30, 0),
            duration_sec=420 * 60,
        )
        result = _extract_sessions(reader, np)
        assert len(result) == 1
        assert result[0]["leak_rate_95th"] == round(float(np.percentile(leak_signal, 95)), 2)

    def test_returns_calendar_date(self):
        reader = self._make_reader(
            labels=["Leak Rate"],
            signals=[[10.0, 15.0, 20.0]],
            start_dt=datetime(2024, 3, 15, 23, 30, 0),
            duration_sec=360 * 60,
        )
        result = _extract_sessions(reader, np)
        assert result[0]["date"] == date(2024, 3, 15)

    def test_duration_in_minutes(self):
        reader = self._make_reader(
            labels=["Leak"],
            signals=[[5.0, 10.0]],
            start_dt=datetime(2024, 1, 1, 22, 0, 0),
            duration_sec=7.5 * 3600,  # 7.5 hours
        )
        result = _extract_sessions(reader, np)
        assert result[0]["total_usage_minutes"] == 450

    def test_no_leak_channel_returns_empty(self):
        reader = self._make_reader(
            labels=["Pressure", "Flow", "Tidal Volume"],
            signals=[[], [], []],
            start_dt=datetime(2024, 1, 1),
            duration_sec=3600,
        )
        result = _extract_sessions(reader, np)
        assert result == []

    def test_empty_leak_signal_returns_empty(self):
        reader = self._make_reader(
            labels=["Leak"],
            signals=[[]],
            start_dt=datetime(2024, 1, 1),
            duration_sec=3600,
        )
        result = _extract_sessions(reader, np)
        assert result == []

    def test_leak_label_case_insensitive(self):
        reader = self._make_reader(
            labels=["LEAK RATE"],
            signals=[[12.0, 14.0, 16.0]],
            start_dt=datetime(2024, 1, 1),
            duration_sec=3600,
        )
        result = _extract_sessions(reader, np)
        assert len(result) == 1


# ---------------------------------------------------------------------------
# upsert_cpap_leak tests (mocked DB)
# ---------------------------------------------------------------------------


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
        cur.rowcount = 1
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
        ])
        assert result == 1

    def test_skips_existing_with_leak(self):
        conn, cur = self._make_mock_conn()
        cur.rowcount = 0
        cur.fetchone.return_value = (1,)
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
        ])
        assert result == 0

    def test_inserts_new_row_when_no_existing(self):
        conn, cur = self._make_mock_conn()
        cur.rowcount = 0
        cur.fetchone.return_value = None

        execute_calls = []

        def tracking_execute(*args, **kwargs):
            execute_calls.append(args)
            if len(execute_calls) == 3:
                cur.rowcount = 1

        cur.execute = tracking_execute

        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3,
             "total_usage_minutes": 420},
        ])
        assert result == 1

    def test_multiple_sessions(self):
        conn, cur = self._make_mock_conn()
        cur.rowcount = 1
        result = upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1), "leak_rate_95th": 15.3},
            {"date": datetime(2024, 1, 2), "leak_rate_95th": 18.7},
        ])
        assert result == 2

    def test_datetime_converted_to_date(self):
        """Verify datetime values are converted to date for Postgres DATE column."""
        conn, cur = self._make_mock_conn()
        cur.rowcount = 1
        upsert_cpap_leak(conn, [
            {"date": datetime(2024, 1, 1, 23, 30, 0), "leak_rate_95th": 15.0},
        ])
        # The UPDATE call should use a date, not datetime
        update_call = cur.execute.call_args_list[0]
        params = update_call[0][1]
        assert isinstance(params[1], date)
        assert not isinstance(params[1], datetime)
