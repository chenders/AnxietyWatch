import os
from unittest.mock import patch, MagicMock

import pytest
import requests

from ezshare_client import (
    parse_dir_listing, DirEntry, EzShareClient,
    EzShareUnreachable, EzShareHTTPError,
)

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def _root_html():
    with open(os.path.join(FIXTURES, "ezshare_dir_root.html"), encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# parse_dir_listing (pure)
# ---------------------------------------------------------------------------


def test_parses_str_edf_file():
    by_name = {e.name: e for e in parse_dir_listing(_root_html())}
    assert by_name["STR.EDF"].is_dir is False
    assert by_name["STR.EDF"].shortname == "STR.EDF"
    assert by_name["STR.EDF"].kb_size == 21


def test_parses_directories():
    by_name = {e.name: e for e in parse_dir_listing(_root_html())}
    assert by_name["DATALOG"].is_dir is True
    assert by_name["DATALOG"].shortname is None
    assert by_name["DATALOG"].kb_size is None


def test_skips_noise_case_insensitively():
    names = {e.name for e in parse_dir_listing(_root_html())}
    for noise in ("ezshare.cfg", "journal.jnl", "Identification.json",
                  ".fseventsd", ".Spotlight-V100"):
        assert noise not in names


def test_returns_empty_for_no_pre_block():
    assert parse_dir_listing("<html><body>nope</body></html>") == []


# ---------------------------------------------------------------------------
# EzShareClient (mocked HTTP)
# ---------------------------------------------------------------------------

VERSION_XML = (b'<?xml version="1.0" encoding="gb2312"?>'
               b'<response><device><version>LZ1640EDPG:2.0.7</version>'
               b'</device></response>')


def _resp(content=b"", status=200):
    r = MagicMock()
    r.status_code = status
    r.content = content
    return r


def test_version_parses_firmware():
    with patch("ezshare_client.requests.get", return_value=_resp(VERSION_XML)):
        assert EzShareClient().version().startswith("LZ1640EDPG:2.0.7")


def test_version_unreachable_raises():
    with patch("ezshare_client.requests.get",
               side_effect=requests.exceptions.ConnectionError()):
        with pytest.raises(EzShareUnreachable):
            EzShareClient().version()


def test_list_dir_returns_entries():
    with patch("ezshare_client.requests.get",
               return_value=_resp(_root_html().encode("utf-8"))):
        entries = EzShareClient().list_dir("A:")
    assert any(e.name == "STR.EDF" for e in entries)


def test_download_rejects_bad_edf_header():
    entry = DirEntry("STR.EDF", "STR.EDF", False, 21, "")
    with patch("ezshare_client.requests.get", return_value=_resp(b"NOT-AN-EDF-FILE............")):
        with pytest.raises(EzShareHTTPError):
            EzShareClient().download(entry)


def test_download_accepts_valid_edf_header():
    entry = DirEntry("STR.EDF", "STR.EDF", False, 21, "")
    edf = b"0       " + b" " * 200  # EDF version field is '0' left-justified in 8 bytes
    with patch("ezshare_client.requests.get", return_value=_resp(edf)):
        assert EzShareClient().download(entry).startswith(b"0")


def test_download_str_edf_finds_and_downloads():
    client = EzShareClient()
    entry = DirEntry("STR.EDF", "STR.EDF", False, 21, "")
    with patch.object(EzShareClient, "list_dir", return_value=[entry]), \
         patch.object(EzShareClient, "download", return_value=b"0       edf") as dl:
        data = client.download_str_edf()
    assert data == b"0       edf"
    dl.assert_called_once()


def test_download_str_edf_returns_none_when_absent():
    client = EzShareClient()
    with patch.object(EzShareClient, "list_dir", return_value=[]):
        assert client.download_str_edf() is None


def test_datalog_days_filters_by_cursor():
    listing = [
        DirEntry("20260114", None, True, None, "dir?dir=A:%5CDATALOG%5C20260114"),
        DirEntry("20260115", None, True, None, "dir?dir=A:%5CDATALOG%5C20260115"),
        DirEntry("20260116", None, True, None, "dir?dir=A:%5CDATALOG%5C20260116"),
    ]
    with patch.object(EzShareClient, "list_dir", return_value=listing):
        days = EzShareClient().datalog_days(since_yyyymmdd="20260115")
    assert days == ["20260115", "20260116"]  # inclusive of cursor day
