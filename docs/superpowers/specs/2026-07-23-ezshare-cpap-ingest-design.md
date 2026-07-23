# ez Share WiFi SD → AirSense 11 CPAP Ingest — Design Spec

## Problem

CPAP session data today arrives one of two ways: **manual OSCAR CSV import** from the SD card (friction-heavy, days stale — `CPAPImporter.swift`) or the **ResMed myAir cloud** poll (`resmed_sync.py` — automatic but low-detail: total AHI only, no event breakdown, no min/max pressure, ~12–24h latency).

An **ez Share WiFi SD card** in the AirSense 11 gives us a third path that is both automatic *and* full-detail: the machine writes standard ResMed EDF files to the card, the card exposes them over plain HTTP on its own WiFi AP, and a server-side poller pulls new files, parses them, and upserts into `cpap_sessions` — the same table the iOS app already reads. No ResMed cloud dependency, and the full SD-card metric set (obstructive/central/hypopnea events, RDI/RERA, all four pressure stats, leak avg/max/95th, and SpO₂/pulse when a machine-attached oximeter is present).

**Acute finding that motivated this spec (2026-07-23):** the card was plugged in but "not saving data anywhere." Root cause confirmed at the hardware layer — the 64 GB card shipped **exFAT**, and the ez Share firmware (and the AS11) read **FAT32 only**, so the machine never mounted it as writable and captured nothing (`ezshare.cfg` present, but no `DATALOG/`). Reformatting FAT32 is Phase 0 below. Separately, we discovered **megadude has onboard WiFi** (Intel AX201, `wlo1`), so no USB adapter purchase is required for the common case.

## Constraints

- **FAT32 only.** ez Share firmware and the AS11 both ignore exFAT/NTFS. The card must be FAT32 and re-initialized by the AS11.
- **The card is its own access point.** SSID `ez Share`, WPA2 PSK `88888888`, HTTP root `http://192.168.4.1` (card at `192.168.4.1`, DHCP hands clients `192.168.4.x`), admin/config password `admin` (factory defaults). It does **not** join the home LAN and is **short-range**. Its radio is live **whenever the card is powered by a host** — in production that's while the CPAP is on, but it also broadcasts while the card sits in a computer's SD reader (which is how the Phase-1 connectivity test below was run).
- **The card AP has no internet.** Whatever interface joins it must not become the default route — only `192.168.4.0/24` should route over it; the primary Ethernet stays the default route.
- **Directory listing is HTML, not JSON.** Files appear as `<a href="…/download?file=SHORT~1.EDF">` inside a `<pre>` block; the preceding text node carries date/time/size. Sizes are **whole-KB granular**, so the "already have this file" check must key on **(name, KB-size)**, never byte-exact.
- **Firmware variants exist.** Modern cards expose `/dir?dir=A:`; older cards expose only a photo-gallery API and need a legacy `download?fname=…&fdir=…` form. Detect via `/client?command=version`. *(This specific card is confirmed **modern** — firmware `2.0.7_2018-01-01`, `/dir` live — so the legacy path is defensive-only. See Validation status.)*
- **Deployment host (megadude):** Ubuntu 24.04, kernel 6.17, Ethernet `eno2` (default route), onboard Intel AX201 `wlo1` on the mainline `iwlwifi` driver (currently `rfkill` soft-blocked → clears with one command). Has both USB 2.0 and USB 3.0 buses. In-kernel drivers `ath9k_htc`, `mt7921u`, `mt76x2u`, `mt7601u` are present; `88x2bu` is **not**, and `dkms` is not installed (so Realtek RTL88x2-class USB adapters are out).
- **Reuse, don't reinvent.** The server already ships `beautifulsoup4` + `lxml` (HTML parsing), `pyedflib` + `numpy` (EDF), `requests`/`httpx`, the `cpap_sessions` table with a full column set and an `import_source` discriminator, the `settings`/`sync_log` cursor+audit pattern, and `edf_parser.py`. This integration is additive, mirroring `resmed_sync.py`.

## Architecture

Server-side, mirroring the ResMed cloud integration. A cron-driven poller on megadude reaches the card over the onboard WiFi, parses new EDFs, and upserts into PostgreSQL. The iOS app picks up the rows through the existing `GET /api/data` path — **no iOS changes**.

```
[ResMed AirSense 11] --writes EDF--> [ez Share WiFi SD @ 192.168.4.1, AP "ez Share"]
        │ (card AP live only while CPAP is powered)
        ▼ 2.4 GHz WiFi  — megadude wlo1 (AX201), route 192.168.4.0/24 ONLY; eno2 stays default
[megadude] server/ezshare_sync.py (cron) --parse (pyedflib / cpap-py)--> PostgreSQL
        │                                        cpap_sessions (import_source = 'ezshare')
        ▼ GET /api/data  (existing endpoint, unchanged)
[iOS app]  — zero app changes; ezshare rows appear like resmed_cloud rows
```

The poller connects to PostgreSQL directly via `DATABASE_URL` (outside the Flask request context, exactly like `resmed_sync.py`).

## Components

### 1. `server/ezshare_client.py` — ez Share HTTP client

Thin wrapper over the card's HTTP API. No WiFi handling — it talks to `http://192.168.4.1` and assumes the OS route (see Network Setup) already reaches it.

**Responsibilities:**
- Probe firmware: `GET /client?command=version`.
- List a directory: `GET /dir?dir=A:` / `…A:\DATALOG\<YYYYMMDD>` (backslash URL-encoded `%5C`), parse the HTML `<pre>` block with BeautifulSoup into entries. **Observed format** (from the live capture): the page is `charset=gb2312`, subdirectory links come back as `dir?dir=A:%5C<name>`, directories are marked `&lt;DIR&gt;` in the size column, and file rows are `2017-01-01 0:00:00 0KB <a href="…/download?file=SHORT~1.EDF"> name</a>`. Decode as gb2312; treat `<DIR>` rows as directories, not files.
- Recurse `DATALOG/` folders; skip non-data entries: `JOURNAL.JNL`, `ezshare.cfg`, `System Volume Information`, **and macOS metadata** that appears whenever the card has been mounted on a Mac (`.fseventsd`, `.Spotlight-V100`, `.Trashes`, `.DS_Store`, `._*`) — the live listing already contained `.fseventsd` and `.Spotlight-V100`.
- Download a file: `GET /download?file=<8.3-shortname>`.
- Expose the **(name, KB-size)** identity for dedup (sizes are KB-granular).

**Interface:**
```python
@dataclass
class DirEntry:
    name: str          # display name, e.g. "20260723_STR.edf"
    shortname: str      # 8.3 name from the download href, e.g. "STR~1.EDF"
    is_dir: bool
    kb_size: int | None # whole KB as reported by the listing (None for dirs)
    href: str

class EzShareClient:
    def __init__(self, base_url: str = "http://192.168.4.1", timeout: float = 10.0): ...
    def version(self) -> str: ...                       # raises EzShareUnreachable if AP is down
    def list_dir(self, path: str = "A:") -> list[DirEntry]: ...
    def download(self, entry: DirEntry) -> bytes: ...   # validates EDF header for *.edf before returning
    def is_legacy_firmware(self) -> bool: ...           # no /dir API → photo-gallery fallback needed
```

**Errors:** `EzShareUnreachable` (AP down / out of range — the *expected* daily state when the CPAP is off), `EzShareLegacyFirmware` (no `/dir` API), `EzShareHTTPError`.

### 2. EDF parsing — extend, don't replace `edf_parser.py`

Today's `edf_parser.py` extracts only `leak_rate_95th` + duration via `pyedflib`. The `cpap_sessions` table already has columns for the full metric set; we need a parser that fills them from the ResMed daily-summary `STR.edf` (AHI, event counts, pressure stats) plus the per-day detail EDFs (leak, SpO₂/pulse if an oximeter is attached).

**Recommended:** adopt **`cpap-py`** (dynacylabs — pure-Python, zero-dependency, explicit AS11 support for `STR.edf` + `DATALOG` BRP/PLD/SAD/EVE/CSL/AEV + identification files) for the summary metrics, and keep the existing `pyedflib` path for the leak-detail extraction it already does well. Pending a quick license + output-shape check during Phase 3 (fallback: hand-extend the pyedflib parser to read the STR summary signals ourselves — more fragile).

**Interface (new `server/ezshare_parser.py`, or extend `edf_parser.py`):**
```python
def parse_day(datalog_dir: Path, str_edf: Path | None) -> dict | None:
    """Return one daily session dict keyed to cpap_sessions columns
    (date, ahi, total_usage_minutes, obstructive/central/hypopnea_events,
     rdi_events, rera_events, pressure_min/max/mean/95th,
     leak_avg/max, leak_rate_95th, spo2_avg/min, pulse_avg).
    Fields the machine didn't record (e.g. no attached oximeter) are None,
    never a fabricated 0. Returns None if the folder holds no parseable session."""
```

### 3. `server/ezshare_sync.py` — sync CLI (cron-invoked)

Orchestrator, modeled on `resmed_sync.py`.

**Flow:**
1. Connect to PostgreSQL via `DATABASE_URL`.
2. Read `ezshare_bridge_url` (default `http://192.168.4.1`) and the cursor `ezshare_last_sync` from `settings`.
3. `EzShareClient.version()`. If `EzShareUnreachable` → log `unreachable`, **do not advance the cursor**, exit 0 (this is the normal daytime state — the CPAP is off).
4. Capture `cursor_upper_bound = <the newest folder date seen this run>` **before** ingesting (the CLAUDE.md incremental-sync-cursor rule — never advance to "now").
5. Walk `DATALOG/<YYYYMMDD>/` folders on/after `ezshare_last_sync` (plus always re-check the latest folder — EDFs grow during therapy). For each file whose (name, KB-size) isn't already recorded, download it (validating the EDF header) and stage it.
6. `parse_day()` per folder → session dict; upsert into `cpap_sessions` with `import_source='ezshare'` and the precedence rules below.
7. `log_sync()` to `sync_log` + `ezshare_last_status`; advance `ezshare_last_sync` to `cursor_upper_bound` **only on success**.

**Invocation / exit codes:** `python ezshare_sync.py` (run now) / `--check-schedule` (gate on a poll window). `0` success *or* AP-unreachable no-op, `2` parse/HTTP error, `3` config error (no `DATABASE_URL`).

## Database Changes

**No new `cpap_sessions` columns** — migration 0010 already added the full by-session set (rdi/rera/spo2/pulse/pressure_95th/leak_avg/leak_max), all nullable with the correct "NULL means not reported, never a fabricated 0" semantics.

**New `import_source` value: `'ezshare'`.** Update `resmed_sync.upsert_sessions()` so cloud rows never clobber `ezshare` rows — add `'ezshare'` to the same "don't overwrite" guard that already protects `'sd_card'`.

**New `settings` keys** (same encrypted-at-rest pattern only if any were secret — these are not):
- `ezshare_bridge_url` — default `http://192.168.4.1`.
- `ezshare_enabled` — `"1"`/`"0"` master switch.
- `ezshare_last_sync` — cursor: newest DATALOG folder date successfully ingested.
- `ezshare_last_status` — human-readable last result (`"ok: 2 sessions"`, `"unreachable"`, `"error: …"`).

**Optional file-dedup table** (Phase 4 optimization, to skip re-downloading unchanged files rather than re-parsing each run):
```sql
CREATE TABLE IF NOT EXISTS ezshare_files (
    folder     TEXT NOT NULL,   -- e.g. "20260723"
    shortname  TEXT NOT NULL,   -- 8.3 name
    kb_size    INTEGER NOT NULL,
    imported_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (folder, shortname, kb_size)
);
```
The cursor + upsert idempotency alone is correct without this; the table is purely a bandwidth optimization. Ship it only if re-walking is measurably slow.

## Network Setup (ops runbook)

**Phase 0 — reformat the card FAT32 (destructive; one-time).** On a Mac, identify the card with `diskutil list` (it's the ~63.9 GB external disk — **verify the identifier every time**, do not assume `/dev/diskN`), then:
```bash
diskutil eraseDisk FAT32 EZSHARE MBRFormat /dev/diskN   # N = the verified card disk
```
Reinsert into the AS11, let it initialize, and run **one night** of therapy. Confirm a `DATALOG/<YYYYMMDD>/` tree plus a top-level `STR.edf` appear.

**Phase 1 — bring up onboard WiFi on megadude (no purchase for the common case; validated 2026-07-23).** The onboard AX201 (`wlo1`, `iwlwifi`) is `rfkill` soft-blocked by default. Use the **inline-secret** `device wifi connect` form — a pre-built profile + `nmcli connection up` fails headlessly over SSH with `Secrets were required, but not provided` (no secret agent in a non-login session):
```bash
sudo rfkill unblock wifi
sudo nmcli device wifi connect "ez Share" password "88888888" ifname wlo1 name ezshare-card
# Keep the card AP off the default route AND out of DNS; autoconnect off:
sudo nmcli connection modify ezshare-card ipv4.never-default yes ipv4.ignore-auto-dns yes \
    ipv6.method ignore connection.autoconnect no
sudo nmcli connection up ezshare-card
```
Validate (Ethernet `eno2` must stay the default route — confirm `ip route show default` shows only the `eno2` line, and `ip route get 192.168.4.1` goes via `wlo1`):
```bash
curl "http://192.168.4.1/client?command=version"   # → firmware XML
curl "http://192.168.4.1/dir?dir=A:"               # → HTML <pre> listing
```
Teardown to the original state (keeps the saved profile): `sudo nmcli connection down ezshare-card && sudo rfkill block wifi`.

**Range fallback (only if onboard can't hear the AP from where megadude sits).** The AX201's antennas are fixed at the box; the card AP is weak. If Phase 1's `curl` can't reach the card, add a USB adapter with a **repositionable external antenna** whose driver is already in-kernel here:
- **ALFA AWUS036ACM** — MediaTek **MT7612U** → `mt76x2u` (present), dual-band, dual 5 dBi antennas, ships with a USB extension cradle (ideal for range). **Caveat:** MT7612U can misbehave on USB 3.0 on new kernels — plug it into megadude's **USB 2.0** port or use the included cradle.
- **Alfa AWUS036NHA** — Atheros AR9271 → `ath9k_htc` (present), 2.4 GHz-only, single antenna, the most bulletproof driver. Also fine.
- **Do not** use the TP-Link Archer T3U (RTL8812BU) — needs the out-of-tree `88x2bu` + dkms, neither present; it rots on kernel bumps.

**Container networking.** The poller must reach `192.168.4.1` via the host's `wlo1` route, which the app's bridge network cannot. Recommended: a dedicated compose service (`network_mode: host`) built from the existing server image that runs the ez Share cron; with host networking it inherits the host route to the card and reaches Postgres via the published `127.0.0.1:5439`. Alternative: a host-level `systemd` timer running the script in a venv. (Decision flagged below.)

## Validation status (2026-07-23, pre-implementation)

The **network path (Phase 1) was validated live before any code was written**, with the card powered in a Mac SD reader so its AP was broadcasting:

- megadude's **onboard AX201** (`wlo1`) saw `ez Share` at signal ~47–54 and joined it (IP `192.168.4.2/24`). **No USB adapter needed at this location.**
- The `ipv4.never-default` + `ipv4.ignore-auto-dns` lockdown **held**: the default route stayed on `eno2`, DNS untouched, the running server unaffected (`ip route get 192.168.4.1` → via `wlo1`).
- `GET /client?command=version` → `200`, firmware `2.0.7_2018-01-01` → **modern `/dir` API**, legacy fallback not needed for this card.
- `GET /dir?dir=A:` → `200`, HTML `<pre>` listing parsed as expected. A real capture now anchors the `ezshare_client.py` parser and its test fixture (gb2312 charset; `&lt;DIR&gt;` markers; `dir?dir=A:%5C` subdir links; macOS dot-dirs present).
- **Phase 0 done (2026-07-23):** the card was confirmed exFAT (only `ezshare.cfg` + macOS metadata, no `DATALOG/`) and **reformatted to FAT32** — MBR scheme, label `EZSHARE`, via `diskutil eraseDisk FAT32 EZSHARE MBRFormat /dev/disk11`. **Remaining prerequisite for real data: one AS11 night** to generate the `DATALOG/` tree + `STR.edf`.

A saved NM profile `ezshare-card` (autoconnect off, never-default, ignore-DNS) remains on megadude; the radio was returned to its original `rfkill`-blocked state after the test. Bring it back up with `sudo nmcli connection up ezshare-card`.

**Still unvalidated (needs real data):** the EDF parse path (Phases 2–4) — blocked on Phase 0 producing an actual `STR.edf` — and whether signal ~50 holds once the card moves from the Mac into the CPAP in its permanent location (range may differ).

## Data Mapping

| EDF source | `cpap_sessions` column | Notes |
|---|---|---|
| `STR.edf` session date | `date` | Bucket by session start; normalize to calendar date |
| `STR.edf` AHI | `ahi` | Direct |
| `STR.edf` mask time | `total_usage_minutes` | Direct |
| `EVE.edf` obstructive | `obstructive_events` | Count |
| `EVE.edf` central | `central_events` | Count |
| `EVE.edf` hypopnea | `hypopnea_events` | Count |
| `STR.edf` RDI / RERA | `rdi_events` / `rera_events` | events/hr (rate) / count |
| `PLD.edf` pressure | `pressure_min/max/mean` + `pressure_95th` | cmH₂O |
| `PLD.edf` leak | `leak_avg` / `leak_max` / `leak_rate_95th` | L/min |
| `SAD.edf` SpO₂ / pulse | `spo2_avg` / `spo2_min` / `pulse_avg` | **NULL** if no oximeter attached — never 0 |
| — | `import_source` | `"ezshare"` |

## Precedence & source arbitration

Fidelity ranking: **manual `sd_card`/`csv` (user-curated) ≥ `ezshare` (automated SD read) > `resmed_cloud`**.

- New date, or existing `ezshare` row → **upsert** (idempotent on re-run).
- Existing `resmed_cloud` row → **overwrite** with the richer ez Share data.
- Existing manual `sd_card`/`csv` row → **skip** (don't silently clobber a user's curated OSCAR import; ez Share is the same underlying SD data, so there's nothing to gain and provenance to lose).
- `resmed_sync.upsert_sessions()` gains `'ezshare'` in its don't-overwrite set, so a later cloud poll can't regress an ez Share row.

*(Flagged for review: whether `ezshare` should instead outrank manual imports and overwrite them.)*

## Error Handling

| Scenario | Behavior |
|---|---|
| Card AP unreachable (CPAP off / out of range) | Log `unreachable`, **cursor unchanged**, exit 0 — this is the normal daytime state |
| Legacy firmware (no `/dir` API) | `EzShareLegacyFirmware`, actionable log ("update card firmware or use legacy fetch"), exit 2 |
| One EDF fails to parse | Skip that file, log, continue the run — never poison the whole night |
| Downloaded size ≠ listing | KB-granularity makes byte compares impossible; re-download and validate the EDF header before commit |
| No new `DATALOG` folder in > 24 h | Emit a **stale-capture** alert (silent AS11 write failure / mis-dated folder after reformat) |
| Cursor advance | Capture upper bound **before** ingest, advance to *that* on success only — never `.now` (CLAUDE.md incremental-sync race) |

## What This Does NOT Include (YAGNI)

- Waveform-level analysis of the 25 Hz `BRP.edf` flow/pressure curves (V2).
- Sub-60s "live" polling during therapy (a later `--live` toggle; V1 polls on a schedule).
- Changing the card's WiFi/admin passwords off factory defaults, VLAN isolation (optional hardening, later).
- Multiple machines / multiple cards.
- Any iOS-side change — ez Share rows ride the existing `cpap_sessions` sync + display path.
- An admin-UI page for ez Share status (nice-to-have; the `settings` status key is enough for V1, an admin panel mirrors the ResMed one later).

## Testing

- **`server/tests/test_ezshare_client.py`** — the HTML `<pre>` dir-listing parser against a **sanitized, recorded `/dir` fixture**: file vs dir discrimination, 8.3 shortname extraction from `href`, date/size parsing, `DATALOG` recursion, the skip-list, legacy-firmware detection, and (name, KB-size) dedup identity.
- **`server/tests/test_ezshare_parser.py`** — `parse_day()` against a **sanitized sample `STR.edf` / detail-EDF fixture** (the OSCAR project ships public ResMed test fixtures); assert AHI/events/pressures/leak with an **epsilon tolerance** (never `==` on floats — CLAUDE.md), and that a no-oximeter night yields `spo2_*`/`pulse_avg` = `None`, not 0.
- **`server/tests/test_ezshare_sync.py`** — upsert precedence (overwrites `resmed_cloud`, skips manual `sd_card`, idempotent on `ezshare`), the unreachable-AP no-op (cursor unchanged, exit 0), and a cursor-race regression (a folder that appears mid-run isn't skipped forever).
- **PII gate (mandatory):** EDF headers and `Identification.tgt`/`.json` carry the device serial and real session dates. Every committed fixture must be sanitized (serials → `0000`, dates → obviously-fictional) per the Sensitive Data Rules; prefer OSCAR's public fixtures over anything captured from this machine.
- **Manual integration runbook:** Phase 0 reformat → one AS11 night → `curl /dir` from megadude → run poller once → row lands with `import_source='ezshare'` → confirm it reaches the iOS app → stale-DATALOG > 24 h alert fires.

## Build Order

1. **Phase 0** — reformat card FAT32; one AS11 night; confirm `DATALOG/` + `STR.edf`. *(destructive — needs explicit go-ahead)*
2. **Phase 1** — onboard WiFi up on megadude, `192.168.4.0/24`-only route, validate with `curl`. (USB adapter only if range fails.)
3. **Phase 2** — `ezshare_client.py` + fixture-based parser tests.
4. **Phase 3** — adopt/verify `cpap-py`, `parse_day()` summary parsing + fixture tests.
5. **Phase 4** — `ezshare_sync.py` (cursor, precedence, `sync_log`) + tests; wire the host-network cron service; patch `resmed_sync` guard.
6. **Phase 5** — stale-capture health check; then optional hardening.

## Files to Create/Modify

| File | Action |
|---|---|
| `server/ezshare_client.py` | NEW — HTTP + HTML dir-listing client |
| `server/ezshare_parser.py` | NEW — full-summary EDF → session dict (or extend `edf_parser.py`) |
| `server/ezshare_sync.py` | NEW — cron sync CLI (direct `DATABASE_URL`, cursor, precedence) |
| `server/resmed_sync.py` | MODIFY — add `'ezshare'` to the don't-overwrite guard |
| `server/schema.sql` | MODIFY — optional `ezshare_files` table; document new `settings` keys |
| `server/requirements.txt` | MODIFY — add `cpap-py` (pin) if adopted |
| `server/docker-compose.yml` / `docker-compose.prod.yml` | MODIFY — add `network_mode: host` ez Share poller service + cron |
| `server/tests/test_ezshare_client.py` | NEW — dir-listing parser tests |
| `server/tests/test_ezshare_parser.py` | NEW — EDF parser tests (sanitized fixtures) |
| `server/tests/test_ezshare_sync.py` | NEW — upsert/precedence/cursor tests |
| `docs/` runbook (or this spec's Network Setup) | reference for the one-time card + WiFi setup |

## Decisions (locked 2026-07-23)

1. **EDF parser: adopt `cpap-py`** for the full summary metrics, keeping `pyedflib`/`edf_parser.py` for leak detail. Phase 3 opens with a quick license + output-shape check; if `cpap-py` proves unworkable, fall back to hand-extending the `pyedflib` parser (documented as the alternative, not the plan).
2. **Precedence: `ezshare` overwrites `resmed_cloud` but skips manual `sd_card`/`csv` rows.** Automated SD ingest is authoritative over cloud, but never silently clobbers a user-curated manual import (same underlying data, nothing to gain, provenance to lose). `resmed_sync` gains `'ezshare'` in its don't-overwrite guard.
3. **Packaging/cadence: a dedicated `network_mode: host` compose service** built from the existing server image, running the poller on a **~10-minute schedule with a graceful no-op** when the AP is unreachable (the normal daytime state). Stays in-repo; no host `systemd` dependency. The always-on `--live` loop is a later opt-in, not V1.
4. **File-dedup table: deferred.** Rely on the cursor + upsert idempotency; add `ezshare_files` only if re-walking is measurably slow in practice. (The `CREATE TABLE` stays in the spec as a ready-to-ship optimization.)

## Implementation notes (as-built 2026-07-23)

The plan above is preserved verbatim. During implementation, real hardware access (a live AS11 STR.EDF) simplified and corrected several assumptions. Deltas:

- **`cpap-py` dropped — pyedflib-only, no new dependency.** `cpap-py` is not published on PyPI under any name, so the spec's documented fallback (extend the existing `pyedflib` path) became the plan. `server/ezshare_parser.py` reads STR.EDF directly.
- **STR.EDF is the authoritative *multi-day* summary → no DATALOG walking in V1.** The real STR.EDF holds one row per day (last ~6 days) for every metric we need. So `parse_str_edf(path) -> list[dict]` returns all daily sessions, and `ezshare_sync` downloads STR.EDF, re-parses the whole file each poll, and **upserts every row (idempotent, self-healing)**. This *eliminates* the incremental-sync cursor race entirely (nothing is ever the only copy left out of a payload) — `ezshare_last_sync` is now status-only, not a filter. DATALOG waveforms remain the deferred V2 (as the spec already scoped). `datalog_days()` is kept in the client for that future work but is unused by V1.
- **Real ResMed signal labels + medical-accuracy conversions** (captured from hardware, encoded in `ezshare_parser.py`): leak is **L/s → ×60 → L/min** (`Leak.50/95/Max`); apnea **indices** `OAI/CAI/HI` (events/hr) → event **counts** via `round(index × usage_hours)`; `AHI` maps directly (rate); pressures from `MaskPress.50/95/Max` (min has no STR source → NULL); `SpO2 = -1` sentinel → NULL; no pulse/RDI/RERA in STR → NULL; dates are days-since-1970.
- **Deployment: a profile-gated (`--profile ezshare`) `anxietywatch-ezshare` `network_mode: host` service** in both compose files, polling every 10 min via a `while` loop (no cron file, no Dockerfile change — the code is already `COPY`'d into the image). Opt-in so it never runs before the host WiFi is joined to the card AP.
- **Clock-reset caveat (action needed):** the real card's STR.EDF is stamped **2008** (`Date` = days-since-epoch) because the AS11's clock reset to epoch on reinit. The parser is faithful; **the AS11 clock must be set** for real session dates, otherwise every night imports as ~2008 and trips the downstream clock-reset guard.
- **Validation done:** live network path + `/client?command=version` + `/dir` (megadude onboard AX201); real STR.EDF parsed (6 days); **real STR.EDF → `upsert_ezshare_sessions` → Postgres round-trip** (correct columns, type adaptation, idempotent). **Not yet run as the deployed container service** — that needs the image rebuilt with these files (CI) and the CPAP powered so the card AP is live.
- **Files as-built:** `ezshare_client.py`, `ezshare_parser.py`, `ezshare_sync.py` (all NEW), `resmed_sync.py` (guard patch), `docker-compose.yml` + `docker-compose.prod.yml` (poller service), `schema.sql` (settings-key docs). No `requirements.txt` change, no `ezshare-cron`, no `ezshare_files` table. 52 server tests green, flake8 clean.
