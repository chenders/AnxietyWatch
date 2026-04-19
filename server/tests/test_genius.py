"""Tests for the Genius API integration module."""

from unittest.mock import patch, MagicMock

from genius import search_songs, fetch_song_metadata, scrape_lyrics


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
