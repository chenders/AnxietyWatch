"""Tests for the Genius API integration module."""

import logging
from unittest.mock import patch, MagicMock

import requests

from genius import search_songs, fetch_song_metadata, scrape_lyrics, fetch_lyrics_musixmatch


class TestSearchSongs:
    """Tests for search_songs()."""

    @patch("genius.requests.get")
    def test_returns_normalized_results(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            json=lambda: {
                "response": {
                    "hits": [
                        {
                            "result": {
                                "id": 4535,
                                "title": "Everybody Hurts",
                                "primary_artist": {"name": "R.E.M."},
                                "song_art_image_url": "https://images.genius.com/art.jpg",
                            }
                        }
                    ]
                }
            },
        )
        results = search_songs("everybody hurts", api_token="test-token")
        assert len(results) == 1
        assert results[0]["genius_id"] == 4535
        assert results[0]["title"] == "Everybody Hurts"
        assert results[0]["artist"] == "R.E.M."

    @patch("genius.requests.get")
    def test_returns_empty_list_on_no_results(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            json=lambda: {"response": {"hits": []}},
        )
        results = search_songs("xyznonexistent", api_token="test-token")
        assert results == []

    @patch("genius.requests.get")
    def test_returns_empty_list_on_api_error(self, mock_get):
        mock_get.return_value = MagicMock(status_code=500)
        results = search_songs("test", api_token="test-token")
        assert results == []

    def test_returns_empty_list_when_no_token(self):
        results = search_songs("test", api_token=None)
        assert results == []


class TestFetchSongMetadata:
    """Tests for fetch_song_metadata()."""

    @patch("genius.requests.get")
    def test_returns_song_metadata(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            json=lambda: {
                "response": {
                    "song": {
                        "id": 4535,
                        "title": "Everybody Hurts",
                        "primary_artist": {"name": "R.E.M."},
                        "album": {"name": "Automatic for the People"},
                        "song_art_image_url": "https://images.genius.com/art.jpg",
                        "url": "https://genius.com/Rem-everybody-hurts-lyrics",
                    }
                }
            },
        )
        meta = fetch_song_metadata(4535, api_token="test-token")
        assert meta["genius_id"] == 4535
        assert meta["title"] == "Everybody Hurts"
        assert meta["artist"] == "R.E.M."
        assert meta["album"] == "Automatic for the People"

    @patch("genius.requests.get")
    def test_returns_none_on_error(self, mock_get):
        mock_get.return_value = MagicMock(status_code=404)
        meta = fetch_song_metadata(99999, api_token="test-token")
        assert meta is None


class TestScrapeLyrics:
    """Tests for scrape_lyrics()."""

    @patch("genius.requests.get")
    def test_extracts_lyrics_from_containers(self, mock_get):
        html = """
        <html><body>
        <div data-lyrics-container="true">When your day is long<br/>And the night</div>
        <div data-lyrics-container="true">The night is yours alone</div>
        </body></html>
        """
        mock_get.return_value = MagicMock(status_code=200, text=html)
        lyrics = scrape_lyrics("https://genius.com/test-lyrics")
        assert "When your day is long" in lyrics
        assert "The night is yours alone" in lyrics

    @patch("genius.requests.get")
    def test_returns_none_when_no_containers(self, mock_get):
        html = "<html><body><p>No lyrics here</p></body></html>"
        mock_get.return_value = MagicMock(status_code=200, text=html)
        lyrics = scrape_lyrics("https://genius.com/test")
        assert lyrics is None

    @patch("genius.requests.get")
    def test_returns_none_on_http_error(self, mock_get):
        mock_get.return_value = MagicMock(status_code=403)
        lyrics = scrape_lyrics("https://genius.com/test")
        assert lyrics is None


class TestFetchLyricsMusixmatch:
    """Tests for fetch_lyrics_musixmatch() log hygiene (F-079)."""

    @patch.dict("os.environ", {"MUSIXMATCH_API_KEY": "FAKE-MM-KEY-abc123"})
    @patch("genius.requests.get")
    def test_request_exception_does_not_log_api_key(self, mock_get, caplog):
        """The Musixmatch key rides as an `apikey` query param; a connection
        failure's exception text embeds the full URL. The logged message must
        redact the query string — the fake key must never appear."""
        mock_get.side_effect = requests.RequestException(
            "Max retries exceeded with url: "
            "/ws/1.1/matcher.lyrics.get?q_track=t&q_artist=a&apikey=FAKE-MM-KEY-abc123 "
            "(Caused by NewConnectionError('...'))"
        )
        with caplog.at_level(logging.ERROR, logger="genius"):
            result = fetch_lyrics_musixmatch("Test Title", "Test Artist")
        assert result is None
        assert "Musixmatch fetch failed" in caplog.text
        assert "FAKE-MM-KEY-abc123" not in caplog.text
        assert "apikey" not in caplog.text

    @patch.dict("os.environ", {"MUSIXMATCH_API_KEY": ""})
    def test_returns_none_without_key(self):
        assert fetch_lyrics_musixmatch("Test Title", "Test Artist") is None
