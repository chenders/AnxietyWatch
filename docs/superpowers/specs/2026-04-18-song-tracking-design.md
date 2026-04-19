# Song Tracking (Earworm) Feature — Design Spec

**Date:** 2026-04-18
**Status:** Draft

## Purpose

Track songs that get stuck in the user's head as an anxiety signal. Songs often reflect subconscious emotional states before the user consciously recognizes them. By logging which songs recur and correlating them with anxiety patterns, the system can surface insights across three priority levels:

1. **Pattern recognition** — Are certain songs predictive of anxiety spikes? Do they precede or follow high-severity entries?
2. **Emotional archaeology** — What emotional themes do the lyrics express? What might the subconscious be processing?
3. **Timeline enrichment** — Songs as contextual markers that make the anxiety timeline more human and complete.

## Architecture Overview

**Server-side song service.** The iOS app sends search queries to the AnxietyWatch server, which proxies to the Genius API for search and metadata, scrapes Genius for lyrics (with Musixmatch as fallback), and caches everything in Postgres. This keeps API keys on the server, puts web scraping in Python where it belongs, and makes lyrics directly available to the Claude analysis pipeline.

Lyrics sync bidirectionally — scraped on the server or manually entered on either the app or admin UI, they flow to both sides.

## Data Model

### Server (Postgres)

```sql
CREATE TABLE songs (
    id              SERIAL PRIMARY KEY,
    genius_id       INTEGER UNIQUE,
    title           TEXT NOT NULL,
    artist          TEXT NOT NULL,
    album           TEXT,
    album_art_url   TEXT,
    genius_url      TEXT,
    lyrics          TEXT,
    lyrics_source   TEXT,          -- 'genius', 'musixmatch', 'manual'
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE song_occurrences (
    id               SERIAL PRIMARY KEY,
    song_id          INTEGER NOT NULL REFERENCES songs(id),
    timestamp        TIMESTAMPTZ NOT NULL,
    source           TEXT,          -- 'journal', 'checkin', 'standalone'
    anxiety_entry_id TIMESTAMPTZ,   -- joins to anxiety_entries.timestamp, nullable
    notes            TEXT,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);
```

### iOS (SwiftData)

```swift
@Model
final class Song {
    var id: UUID
    var serverId: Int?              // maps to songs.id on server
    var geniusId: Int?
    var title: String
    var artist: String
    var album: String?
    var albumArtURL: String?
    var geniusURL: String?
    var lyrics: String?
    var lyricsSource: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SongOccurrence.song)
    var occurrences: [SongOccurrence]

    init(title: String, artist: String) {
        self.id = UUID()
        self.title = title
        self.artist = artist
        self.createdAt = Date()
        self.updatedAt = Date()
        self.occurrences = []
    }
}

@Model
final class SongOccurrence {
    var id: UUID
    var timestamp: Date
    var source: String?             // "journal", "checkin", "standalone"
    var notes: String?

    var song: Song?

    @Relationship(deleteRule: .nullify)
    var anxietyEntry: AnxietyEntry?

    init(timestamp: Date, source: String?) {
        self.id = UUID()
        self.timestamp = timestamp
        self.source = source
    }
}
```

`AnxietyEntry` gains an inverse relationship:

```swift
// Added to AnxietyEntry
@Relationship(deleteRule: .nullify, inverse: \SongOccurrence.anxietyEntry)
var songOccurrences: [SongOccurrence]
```

## Server API

All endpoints use the existing Bearer token auth.

### `GET /api/songs/search?q=<query>`

Proxies to Genius Search API. Returns top 5-8 results.

**Response:**
```json
{
  "results": [
    {
      "genius_id": 4535,
      "title": "Everybody Hurts",
      "artist": "R.E.M.",
      "album": "Automatic for the People",
      "album_art_url": "https://images.genius.com/..."
    }
  ]
}
```

### `POST /api/songs`

Adds a song to the catalog. If `genius_id` already exists, returns the existing record.

**Request:** `{"genius_id": 4535}`

**Server behavior:**
1. Check if `genius_id` exists in `songs` table → return existing if so
2. Fetch full metadata from Genius API
3. Scrape lyrics from the Genius song page using BeautifulSoup
4. If scrape fails, attempt Musixmatch API (30% preview on free tier)
5. Insert into `songs` table
6. Return the full song record

**Response:**
```json
{
  "id": 1,
  "genius_id": 4535,
  "title": "Everybody Hurts",
  "artist": "R.E.M.",
  "album": "Automatic for the People",
  "album_art_url": "https://images.genius.com/...",
  "genius_url": "https://genius.com/Rem-everybody-hurts-lyrics",
  "lyrics": "When your day is long...",
  "lyrics_source": "genius"
}
```

### `POST /api/songs/<song_id>/occurrences`

Logs a song occurrence.

**Request:**
```json
{
  "timestamp": "2026-04-18T14:30:00Z",
  "source": "journal",
  "anxiety_entry_id": "2026-04-18T13:00:00Z",
  "notes": null
}
```

### `GET /api/songs`

Returns all songs with occurrence summary. Used by the iOS app for initial catalog population and by the admin songs list page. Ongoing sync uses the standard sync payload (see Sync section), not this endpoint.

**Response:**
```json
{
  "songs": [
    {
      "id": 1,
      "title": "Everybody Hurts",
      "artist": "R.E.M.",
      "album": "Automatic for the People",
      "album_art_url": "https://...",
      "occurrence_count": 8,
      "last_occurrence": "2026-04-18T14:30:00Z",
      "has_lyrics": true
    }
  ]
}
```

### `PUT /api/songs/<song_id>`

Updates song metadata/lyrics (used by both iOS app and admin UI).

**Request:** `{"lyrics": "When your day is long...", "lyrics_source": "manual"}`

## Server Implementation

### Genius Integration (`server/genius.py`)

New module with:

- `search_songs(query: str) -> list[dict]` — calls Genius Search API, returns normalized results
- `fetch_song_metadata(genius_id: int) -> dict` — fetches full song details from Genius API
- `scrape_lyrics(genius_url: str) -> str | None` — BeautifulSoup scrape of the lyrics page
- `fetch_lyrics_musixmatch(title: str, artist: str) -> str | None` — Musixmatch API fallback

**Environment variables:**
- `GENIUS_API_TOKEN` — required for search and metadata endpoints
- `MUSIXMATCH_API_KEY` — optional, for lyrics fallback

### Lyrics Scraping Strategy

Genius lyrics pages render lyrics in `<div data-lyrics-container="true">` elements. The scraper:

1. Fetches the song page HTML
2. Parses with BeautifulSoup
3. Extracts text from all `[data-lyrics-container="true"]` divs
4. Strips annotation markup, preserves line breaks
5. Returns cleaned plain text

If the page structure changes, the scraper returns `None` and falls back to Musixmatch.

## iOS UI

### Tab Structure

The Journal tab gains a segmented control: **Journal | Songs**. Defaults to Journal. The Songs segment shows the song catalog.

### Songs Catalog View

- List of songs sorted by most recent occurrence
- Each row: album art thumbnail (or music note placeholder), title, artist, occurrence count, time since last occurrence
- **+ button** in nav bar opens the song search sheet
- Tapping a song row navigates to Song Detail view

### Song Detail View

- Displays: album art, title, artist, album, occurrence count
- **Editable fields:** title, artist, album, lyrics (large text editor)
- **Occurrence history:** timestamped list showing linked anxiety severity (if any) and source
- **Edit mode** via standard SwiftUI EditButton pattern
- Changes saved locally and synced to server via `PUT /api/songs/<id>`

### Song Search Sheet

Presented as a `.sheet` from three surfaces: Songs catalog + button, journal entry song field, check-in song field.

- **Search input** with ~400ms debounce
- Results appear in two sections:
  - **"Your songs"** — local catalog matches shown first, highlighted with a distinct background and ★ indicator
  - **"From Genius"** — new results from server search, with + button to add
- Tapping a catalog song selects it immediately
- Tapping a Genius result adds it to the catalog AND selects it
- When opened from journal/check-in, selecting a song dismisses the sheet and populates the song field

### Journal Entry Integration

- New optional "Song in your head?" section at the bottom of the journal entry form
- Collapsed search input — tapping it opens the Song Search Sheet
- Selected song displayed inline with album art, title, artist, and an ✕ to remove
- Saving the journal entry creates both the `AnxietyEntry` and a linked `SongOccurrence` (source: "journal")

### Random Check-in Integration

- Below the severity picker, an optional "Song in your head?" search input
- Same behavior: tapping opens the Song Search Sheet
- Submitting the check-in creates the `AnxietyEntry` and optionally a linked `SongOccurrence` (source: "checkin")
- Fully optional — severity-only check-ins still work with a single tap

## Sync

### iOS → Server

`DataExporter` includes song data in the sync payload:

```json
{
  "songs": [
    {
      "id": "uuid",
      "serverId": 1,
      "geniusId": 4535,
      "title": "Everybody Hurts",
      "artist": "R.E.M.",
      "album": "Automatic for the People",
      "lyrics": "When your day is long...",
      "lyricsSource": "manual",
      "updatedAt": "2026-04-18T15:00:00Z"
    }
  ],
  "songOccurrences": [
    {
      "id": "uuid",
      "songServerId": 1,
      "timestamp": "2026-04-18T14:30:00Z",
      "source": "journal",
      "anxietyEntryTimestamp": "2026-04-18T13:00:00Z"
    }
  ]
}
```

### Server → iOS

When songs are added or lyrics updated via the admin UI or server-side scraping, changes flow back to the app on the next sync.

### Conflict Resolution

Last-write-wins based on `updated_at`. If the same song is edited on both the app and admin UI, the most recent edit takes precedence.

## Admin UI

### Songs List (`/admin/songs`)

- Table: title, artist, album, occurrence count, lyrics status (✓/✗)
- Sortable columns
- Link to detail page for each song

### Song Detail (`/admin/songs/<id>`)

- Editable fields: title, artist, album, album_art_url, genius_url
- **Lyrics editor:** large textarea, pre-filled if scraped, manually editable
- Lyrics source indicator
- **Occurrence history:** timestamped table with linked anxiety severity and source
- Save button updates the record; sets `lyrics_source` to "manual" if lyrics were edited

## Claude Analysis Integration

### Prompt Construction

When building the analysis prompt, add a "Song Patterns" section:

```
## Song Patterns

Songs the patient has reported having stuck in their head, with frequency
and anxiety correlation:

| Song | Artist | Occurrences (period) | Avg Anxiety | Trend |
|------|--------|---------------------|-------------|-------|
| Everybody Hurts | R.E.M. | 8 (last 2 weeks) | 6.2 | ↑ from 1/month |
| Breathe Me | Sia | 3 (last month) | 7.1 | stable |
| Under Pressure | Queen | 1 | 4.0 | new |

[For songs with lyrics available, lyrics are included below]

### Everybody Hurts — R.E.M.
Lyrics: When your day is long and the night...

### Breathe Me — Sia
Lyrics: Help, I have done it again...

[For songs WITHOUT lyrics stored, the analyst should use web search
to find and analyze lyrics if the song shows interesting patterns.]
```

### Lyrics Inclusion Logic

- If a song has `lyrics IS NOT NULL` in the database: include lyrics directly in the prompt
- If lyrics are null AND the song shows interesting patterns (high frequency, strong anxiety correlation, or sudden appearance): instruct Claude to use web search to look up the lyrics
- Never ask Claude to look up lyrics that are already stored

### Analysis Instructions

Claude is prompted to analyze songs across the three priority levels:

1. **Pattern recognition:** Correlate song frequency/timing with anxiety severity. Identify songs that appear before anxiety spikes (predictive) vs. during (concurrent) vs. after (processing).
2. **Emotional archaeology:** For songs with available lyrics, analyze emotional themes. What feelings do the lyrics express? How might they relate to the patient's current situation and conflicts?
3. **Timeline enrichment:** Reference songs as contextual markers in the narrative summary (e.g., "During the week of April 14-18, the patient reported 'Everybody Hurts' stuck in their head 4 times, coinciding with elevated anxiety around the medication conflict").

## Environment Variables

New variables added to `server/.env.example`:

- `GENIUS_API_TOKEN` — API token from genius.com/api-clients (required for song search)
- `MUSIXMATCH_API_KEY` — API key from developer.musixmatch.com (optional, lyrics fallback)

## Dependencies

### Server
- `beautifulsoup4` — HTML parsing for lyrics scraping
- `lxml` — fast HTML parser backend for BeautifulSoup

### iOS
- No new dependencies — uses URLSession for API calls, SwiftData for persistence
