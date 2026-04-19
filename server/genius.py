"""Genius API client and lyrics scraper for song tracking."""

import logging
import os

import requests
from bs4 import BeautifulSoup

log = logging.getLogger(__name__)

GENIUS_API_BASE = "https://api.genius.com"


def search_songs(query: str, api_token: str | None = None) -> list[dict]:
    """Search Genius for songs matching query. Returns normalized results."""
    token = api_token or os.environ.get("GENIUS_API_TOKEN")
    if not token:
        log.warning("No Genius API token configured")
        return []

    try:
        resp = requests.get(
            f"{GENIUS_API_BASE}/search",
            params={"q": query},
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if resp.status_code != 200:
            log.error("Genius search returned %d", resp.status_code)
            return []

        hits = resp.json().get("response", {}).get("hits", [])
        results = []
        for hit in hits[:8]:
            song = hit.get("result", {})
            results.append({
                "genius_id": song.get("id"),
                "title": song.get("title", ""),
                "artist": song.get("primary_artist", {}).get("name", ""),
                "album_art_url": song.get("song_art_image_url"),
            })
        return results
    except (requests.RequestException, ValueError):
        log.exception("Genius search failed")
        return []


def fetch_song_metadata(genius_id: int, api_token: str | None = None) -> dict | None:
    """Fetch full song metadata from Genius API."""
    token = api_token or os.environ.get("GENIUS_API_TOKEN")
    if not token:
        return None

    try:
        resp = requests.get(
            f"{GENIUS_API_BASE}/songs/{genius_id}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if resp.status_code != 200:
            log.error("Genius metadata fetch returned %d for %d", resp.status_code, genius_id)
            return None

        song = resp.json().get("response", {}).get("song", {})
        album = song.get("album")
        return {
            "genius_id": song.get("id"),
            "title": song.get("title", ""),
            "artist": song.get("primary_artist", {}).get("name", ""),
            "album": album.get("name") if album else None,
            "album_art_url": song.get("song_art_image_url"),
            "genius_url": song.get("url"),
        }
    except (requests.RequestException, ValueError):
        log.exception("Genius metadata fetch failed for %d", genius_id)
        return None


def scrape_lyrics(genius_url: str) -> str | None:
    """Scrape lyrics from a Genius song page.

    Extracts text from <div data-lyrics-container="true"> elements.
    Returns cleaned plain text or None if scraping fails.
    """
    try:
        resp = requests.get(genius_url, timeout=15)
        if resp.status_code != 200:
            log.error("Genius page returned %d for %s", resp.status_code, genius_url)
            return None

        soup = BeautifulSoup(resp.text, "lxml")
        containers = soup.find_all("div", attrs={"data-lyrics-container": "true"})
        if not containers:
            log.warning("No lyrics containers found on %s", genius_url)
            return None

        parts = []
        for container in containers:
            # Replace <br> tags with newlines before extracting text
            for br in container.find_all("br"):
                br.replace_with("\n")
            text = container.get_text(separator="\n")
            parts.append(text.strip())

        lyrics = "\n\n".join(parts).strip()
        return lyrics if lyrics else None
    except requests.RequestException:
        log.exception("Lyrics scrape failed for %s", genius_url)
        return None


def fetch_lyrics_musixmatch(title: str, artist: str) -> str | None:
    """Fetch lyrics from Musixmatch API (30% preview on free tier).

    Returns partial lyrics or None if unavailable.
    """
    api_key = os.environ.get("MUSIXMATCH_API_KEY")
    if not api_key:
        return None

    try:
        # Search for the track
        resp = requests.get(
            "https://api.musixmatch.com/ws/1.1/matcher.lyrics.get",
            params={
                "q_track": title,
                "q_artist": artist,
                "apikey": api_key,
            },
            timeout=10,
        )
        if resp.status_code != 200:
            return None

        body = resp.json().get("message", {}).get("body", {})
        lyrics_obj = body.get("lyrics", {})
        lyrics = lyrics_obj.get("lyrics_body")
        if lyrics:
            # Remove the Musixmatch disclaimer footer
            disclaimer_marker = "******* This Lyrics is NOT"
            if disclaimer_marker in lyrics:
                lyrics = lyrics[:lyrics.index(disclaimer_marker)].strip()
        return lyrics if lyrics else None
    except (requests.RequestException, ValueError):
        log.exception("Musixmatch fetch failed for %s - %s", artist, title)
        return None
