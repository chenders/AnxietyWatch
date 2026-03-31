# OSCAR CPAP Import + EDF Leak Parser — Design Spec

**Date:** 2026-03-30
**Status:** Approved
**Scope:** Add OSCAR Summary CSV support to iOS CPAPImporter, add EDF file upload with leak extraction to server

---

## Overview

Two complementary import paths for CPAP data from a ResMed AirSense 11:

1. **iOS CSV import (enhanced)** — Auto-detects OSCAR Summary CSV format alongside the existing simple format. Gets all fields except leak rate.
2. **Server EDF upload (new)** — Accepts EDF files from the SD card via admin UI. Extracts leak 95th percentile and upserts into `cpap_sessions`. iOS sync pulls the updated data.

---

## 1. OSCAR CSV Import (iOS)

### Auto-Detection

The importer reads the header row to detect format:
- Header starts with `Date,Session Count,Start,End,Total Time,AHI` → OSCAR Summary
- Header starts with `date,ahi,usage_minutes` → existing simple format
- Anything else → throw `invalidFormat`

### OSCAR Column Mapping

| CPAPSession field | OSCAR column (index) | Parsing |
|---|---|---|
| `date` | `Date` (0) | `yyyy-MM-dd` format |
| `ahi` | `AHI` (5) | Double |
| `totalUsageMinutes` | `Total Time` (4) | Parse `HH:MM:SS` → total minutes |
| `leakRate95th` | — | `nil` (not available in OSCAR CSV) |
| `pressureMin` | `Median Pressure` (22) | Best proxy (no true min in export) |
| `pressureMax` | `99.5% Pressure` (36) | Close proxy for max |
| `pressureMean` | `Median Pressure` (22) | Median ≈ mean for CPAP |
| `obstructiveEvents` | `OA Count` (8) | Int |
| `centralEvents` | `CA Count` (6) | Int |
| `hypopneaEvents` | `H Count` (9) | Int |
| `importSource` | — | `"oscar"` |

### Model Change

`CPAPSession.leakRate95th` changes from `Double` to `Double?`:
- Init parameter gets default `nil`
- Existing callers that pass a value are unaffected
- Views displaying leak hide the leak metric when nil
- `ImportSource` enum gains `.oscar` case

### Import Source

OSCAR imports use `importSource: "oscar"` to distinguish from simple CSV (`"csv"`) and other sources.

---

## 2. EDF Parser (Server)

### Endpoint

`GET/POST /admin/cpap/upload` — admin UI page with multipart file upload for one or more EDF files.

### Parser Module

`server/edf_parser.py` using `pyedflib`:

1. Read EDF file
2. Identify the leak channel (labeled "Leak" or "Leak Rate" in ResMed files)
3. Compute 95th percentile via `numpy.percentile`
4. Extract session date from the EDF header
5. Return structured dict with date + leak 95th

**Note on `STR.edf`:** ResMed's `STR.edf` contains per-session summary data, but the current parser does not implement STR-specific parsing. Both `STR.edf` and detail EDF files are processed the same way — the parser finds the leak channel and computes the 95th percentile. STR-specific summary extraction is future work.

### Storage

Parsed data upserts into the existing `cpap_sessions` PostgreSQL table. The `leak_rate_95th` column already exists. Upserts key on date — if a CSV import already created a row with NULL leak, the EDF upload fills it in.

### Admin UI

Add an upload form to the existing admin blueprint:
- File picker accepting `.edf` files (single or multiple)
- Submit button
- Result summary: sessions updated, leak values extracted, any errors

### Dependencies

Add `pyedflib` and `numpy` to `server/requirements.txt`.

---

## 3. Integration

### Two paths, complementary

1. **iOS CSV** — OSCAR Summary export → file picker in CPAP tab → immediate local import (everything except leak)
2. **Server EDF** — SD card files → admin UI upload → server extracts leak → next iOS sync pulls updated data

### Upsert behavior

Both paths key on date. A CSV import creating a session with `leakRate95th: nil` can be later enriched by an EDF upload that fills in leak for the same date. The server upsert updates the existing row. iOS sync pulls the complete record.

### What iOS sync needs

The server's CPAP data endpoint already returns `leak_rate_95th`. The iOS `SyncService` / data fetch path needs to map this field to the now-optional `CPAPSession.leakRate95th`.

---

## Out of Scope

- OSCAR Sessions CSV import (Summary aggregates to daily, which matches our model)
- OSCAR Details CSV / per-event import (Phase 3 intelligence layer)
- Full EDF waveform storage
- Automatic SD card detection
- Direct EDF parsing on iOS
