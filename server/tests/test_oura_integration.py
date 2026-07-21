import pytest
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock
from delta_oura_patch import fetch_and_persist_oura_data
import os

class MockResponse:
    def __init__(self, json_data, status_code):
        self.json_data = json_data
        self.status_code = status_code

    def json(self):
        return self.json_data

@pytest.fixture
def mock_db_conn():
    conn = MagicMock()
    cursor = MagicMock()
    conn.cursor.return_value.__enter__.return_value = cursor
    return conn, cursor

def test_fetch_and_persist_oura_sleep(mock_db_conn):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'dummy_access',
        'refresh_token': 'dummy_refresh',
        'expires_at': datetime.now(timezone.utc) + timedelta(hours=1)
    }
    event_data = {'data_type': 'sleep'}
    
    http_client = MagicMock()
    http_client.get.return_value = MockResponse({
        'data': [{
            'day': '2024-01-01',
            'id': 'sleep_2024-01-01',
            'sleep_phase_5_min': '112233',
            'heart_rate_variability': {'5_min': [40, 45]},
            'respiratory_rate_5_min': [14.5, 14.6],
            'average_respiratory_rate': 14.55,
            'efficiency': 85,
            'latency': 300
        }]
    }, 200)
    
    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    http_client.get.assert_called_once_with(
        "https://api.ouraring.com/v2/usercollection/sleep",
        headers={"Authorization": "Bearer dummy_access"},
        params={}
    )
    cursor.execute.assert_called_once()
    sql_call = cursor.execute.call_args[0][0]
    assert "INSERT INTO oura_sleep" in sql_call

def test_fetch_and_persist_oura_daily_readiness(mock_db_conn):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'dummy_access',
        'refresh_token': 'dummy_refresh',
        'expires_at': datetime.now(timezone.utc) + timedelta(hours=1)
    }
    event_data = {'data_type': 'daily_readiness'}
    
    http_client = MagicMock()
    http_client.get.return_value = MockResponse({
        'data': [{
            'day': '2024-01-01',
            'id': 'readiness_123',
            'score': 88,
            'temperature_deviation': 0.1
        }]
    }, 200)
    
    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    assert cursor.execute.call_count == 2
    insert_call = cursor.execute.call_args_list[0][0][0]
    update_call = cursor.execute.call_args_list[1][0][0]
    assert "INSERT INTO oura_daily" in insert_call
    assert "UPDATE oura_daily SET readiness =" in update_call
    assert cursor.execute.call_args_list[1][0][1] == (88, 0.1, '2024-01-01')

def test_oura_token_refresh(mock_db_conn):
    conn, cursor = mock_db_conn
    token_row = {
        'id': 1,
        'access_token': 'expired_access',
        'refresh_token': 'valid_refresh',
        'expires_at': datetime.now(timezone.utc) - timedelta(hours=1)
    }
    event_data = {'data_type': 'sleep'}
    
    http_client = MagicMock()
    # First post is refresh, second is get
    http_client.post.return_value = MockResponse({
        'access_token': 'new_access',
        'refresh_token': 'new_refresh',
        'expires_in': 3600
    }, 200)
    http_client.get.return_value = MockResponse({'data': []}, 200)
    
    os.environ['OURA_CLIENT_ID'] = 'test_id'
    os.environ['OURA_CLIENT_SECRET'] = 'test_secret'
    
    res = fetch_and_persist_oura_data(token_row, event_data, conn, http_client)
    assert res is True
    http_client.post.assert_called_once()
    assert token_row['access_token'] == b'new_access'
    assert token_row['refresh_token'] == b'new_refresh'
    
    # DB update for token
    update_call = cursor.execute.call_args_list[0][0][0]
    assert "UPDATE oura_credentials" in update_call
