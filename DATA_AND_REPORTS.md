# DATA_AND_REPORTS.md — Data Export, Claude Analysis, and Clinical Reports

This document describes how to get data out of AnxietyWatch for analysis on larger displays, AI-assisted pattern detection, and data-driven psychiatric care.

---

## Part 1: Server Sync (View on Larger Displays)

### V1 Approach: Manual Export + Local Viewing

Before building a full server sync, you can export data and view it on any device:

1. **Export JSON/CSV from the app** via the Export screen (share sheet)
2. **AirDrop or email** the file to your Mac
3. **Open in a browser-based dashboard** — you can build a simple local HTML/JS viewer, or load the CSV into any tool (Excel, Google Sheets, Observable, etc.)

This is functional but manual. It's the right starting point.

### V2 Approach: Personal Server Sync

Architecture for syncing to your own server:

```
iPhone App  ──push──▶  Your Server (REST API)  ◀──read──  Web Dashboard
                              │
                              ▼
                        PostgreSQL DB
```

**Server stack suggestion** (plays to your existing skills):
- **Python + FastAPI** — you already use this stack at work
- **PostgreSQL** — same
- **Celery** — for any async processing (report generation, etc.)
- The API receives JSON payloads from the app and stores them
- A simple web frontend (React, plain HTML, whatever) displays charts and data

**Sync design:**
- App pushes daily: the HealthSnapshot for the day, any new journal entries, any new medication doses, CPAP session data
- Auth: API key in the request header (this is your personal server — keep it simple)
- Conflict resolution: server timestamp wins (or last-write-wins; you're the only user)
- Sync on app foreground, or on a background schedule using `BGAppRefreshTask`

**iOS side implementation:**
```swift
// Simplified sync service concept
actor SyncService {
    let serverURL: URL
    let apiKey: String

    func pushDailyData() async throws {
        let snapshots = // query unsync'd HealthSnapshots
        let entries = // query unsync'd AnxietyEntries
        let meds = // query unsync'd MedicationDoses
        let cpap = // query unsync'd CPAPSessions

        let payload = SyncPayload(snapshots: snapshots, entries: entries,
                                   medications: meds, cpapSessions: cpap)

        var request = URLRequest(url: serverURL.appendingPathComponent("/api/sync"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        // Mark records as synced on success
    }
}
```

**Alternative: CloudKit**
If you don't want to run your own server, Apple's CloudKit gives you:
- Automatic sync across your Apple devices
- No server to maintain
- Free tier is generous for single-user apps
- You can access the data via the CloudKit Dashboard web UI

The trade-off: CloudKit is Apple-only, harder to query for custom analysis, and you can't easily run a web dashboard against it. Given that you already run PostgreSQL professionally, your own server is probably the better fit.

---

## Part 2: Data Export for Claude Analysis

### Export Format

The app should export a single JSON file containing all data for a specified date range. This file is what you'll upload to Claude for analysis.

**Recommended JSON structure:**

```json
{
  "export_metadata": {
    "app_version": "1.0.0",
    "export_date": "2026-04-15T10:30:00Z",
    "date_range": {
      "start": "2026-03-15",
      "end": "2026-04-15"
    },
    "data_completeness": {
      "health_snapshots": 30,
      "journal_entries": 47,
      "medication_doses": 89,
      "cpap_sessions": 28,
      "barometric_readings": 412
    }
  },
  "health_snapshots": [
    {
      "date": "2026-03-15",
      "hrv_avg_ms": 34.2,
      "hrv_min_ms": 18.7,
      "resting_hr_bpm": 72,
      "sleep_duration_min": 412,
      "sleep_deep_min": 87,
      "sleep_rem_min": 94,
      "sleep_core_min": 198,
      "sleep_awake_min": 33,
      "skin_temp_deviation_c": -0.3,
      "respiratory_rate": 14.2,
      "spo2_avg_pct": 96.1,
      "steps": 8432,
      "active_calories": 340,
      "exercise_minutes": 32,
      "environmental_sound_avg_dba": 62.1,
      "bp_systolic_mmhg": 128,
      "bp_diastolic_mmhg": 82,
      "blood_glucose_avg_mgdl": null
    }
  ],
  "anxiety_entries": [
    {
      "timestamp": "2026-03-15T09:15:00Z",
      "severity": 7,
      "notes": "Woke up anxious, racing thoughts about work deadline. Took clonazepam at 9:20.",
      "tags": ["morning", "work", "racing_thoughts"],
      "nearby_hr_bpm": 88,
      "nearby_hrv_ms": 22.4
    }
  ],
  "medication_doses": [
    {
      "timestamp": "2026-03-15T09:20:00Z",
      "medication": "clonazepam",
      "dose_mg": 0.5,
      "category": "benzodiazepine"
    }
  ],
  "cpap_sessions": [
    {
      "date": "2026-03-15",
      "ahi": 3.2,
      "usage_minutes": 427,
      "leak_rate_95th_lpm": 8.4,
      "pressure_mean_cmh2o": 10.2,
      "obstructive_events": 12,
      "central_events": 3,
      "hypopnea_events": 8
    }
  ],
  "barometric_readings": [
    {
      "timestamp": "2026-03-15T09:00:00Z",
      "pressure_kpa": 101.2
    }
  ]
}
```

### Enriched Export: Nearby Physiology for Journal Entries

The most useful analysis feature: for each anxiety journal entry, include the physiological data from a window around that timestamp. This is the `nearby_hr_bpm` and `nearby_hrv_ms` fields above. At export time, query HealthKit for HR and HRV samples within ±30 minutes of each journal entry timestamp and include the closest readings.

This lets Claude see things like: "Every time you logged severity 8+, your HR was above 85 and your HRV was below 25ms."

### How to Use the Export with Claude

**Basic analysis prompt:**

```
I'm attaching a JSON export from my anxiety tracking app covering the last 30 days.
Please analyze this data and:

1. Identify any patterns between my physiological data (HRV, HR, sleep,
   CPAP) and my anxiety severity ratings
2. Flag any concerning readings or trends I should discuss with my doctor
3. Look for patterns around medication timing — does my physiology change
   predictably after doses?
4. Identify my best and worst days and what distinguished them
5. Note any sleep patterns (CPAP AHI, sleep staging, duration) that
   correlate with next-day anxiety

Be specific with numbers and dates. I want to see the actual data points
that support your observations.
```

**Medication-focused prompt:**

```
Here's my anxiety tracking data for the past 30 days. I'm particularly
interested in understanding the relationship between my benzodiazepine
doses and my physiological signals.

For each dose logged, can you:
1. Show what my HR and HRV were doing before and after the dose
2. Identify how long it takes for my HRV to improve after a dose
3. Flag any days where I appear to have needed medication but didn't take
   it (based on physiological signals being in an anxious range)
4. Look at the overnight data — do days where I took medication show
   different sleep patterns?
```

**Weekly check-in prompt:**

```
Here's this week's data from my anxiety tracker. Give me a brief summary:
- How this week compares to my recent baseline
- Any red flags
- What went well (best day and why)
- One thing to watch next week
```

---

## Part 3: Clinical Reports for Your Psychiatrist

### Purpose

Generate a structured, professional report summarizing a time period that you can print or share with your psychiatrist. The goal is to replace subjective "I felt anxious this week" with data-backed observations that enable collaborative, evidence-based treatment decisions.

### Report Content Structure

```
ANXIETYSCOPE — CLINICAL SUMMARY REPORT
Patient: [Name]
Report Period: [Start Date] — [End Date]
Generated: [Date]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. OVERVIEW
   - Total anxiety entries logged: N
   - Average severity: X.X / 10
   - Severity trend: improving / stable / worsening (with % change)
   - Days with severity ≥ 7: N out of N days

2. MEDICATION SUMMARY
   - [Drug name]: taken X times, average dose Xmg, total doses N
   - Adherence to prescribed schedule: X%
   - Correlation: average severity on medicated days vs unmedicated days

3. PHYSIOLOGICAL TRENDS
   - HRV: current 30-day avg vs prior 30-day avg, trend direction
   - Resting HR: same
   - Sleep: average duration, average deep sleep %, trend
   - Notable: any metrics significantly outside personal baseline

4. SLEEP & CPAP
   - Average nightly usage: X hrs
   - Average AHI: X.X events/hr
   - Nights with AHI > 5: N
   - Average mask leak: X L/min
   - Sleep quality correlation: AHI vs next-day anxiety

5. NOTABLE PATTERNS
   - [Pattern 1]: e.g., "Anxiety severity was significantly higher
     on days following nights with < 6 hours of sleep (avg 6.8 vs 4.2)"
   - [Pattern 2]: e.g., "HRV dropped below baseline 2-3 days before
     the highest-severity entries, suggesting a predictive window"
   - [Pattern 3]: e.g., "Exercise days (>30 min) showed 40% lower
     average anxiety severity the following day"

6. BLOOD PRESSURE (if available)
   - Average systolic/diastolic
   - Readings during high-anxiety episodes vs baseline
   - Trend

7. RAW DATA APPENDIX (optional, can be toggled)
   - Daily summary table with all metrics
   - Medication log
   - Full journal entries (or summaries)
```

### Report Generation

The app generates this as a **PDF** using PDFKit or Core Graphics. Design it for readability on printed paper (black and white compatible, clear fonts, minimal decoration).

**Key design choices:**
- Use tables and simple trend arrows (↑ ↓ →) rather than complex charts for print compatibility
- Include actual numbers, not just descriptions
- Make it scannable — a busy psychiatrist should be able to get the gist in 60 seconds from section 1 and drill into details as needed
- Include a "data completeness" note so the provider knows if there are gaps (e.g., "CPAP data missing for 5 of 30 days")

### Alternative: Claude-Generated Reports

For richer narrative analysis, you can use the export-to-Claude workflow to generate the report:

```
I'm attaching my anxiety tracking data for the past 30 days. Please
generate a clinical summary report that I can bring to my psychiatrist
appointment.

Format it as a professional medical summary with these sections:
1. Overview (severity trends, frequency)
2. Medication summary (adherence, timing patterns, efficacy signals)
3. Physiological trends (HRV, HR, sleep, CPAP)
4. Notable correlations and patterns
5. Questions or observations for clinical discussion

Use specific numbers and dates. Keep the tone clinical and factual.
My psychiatrist and I are taking a data-driven approach to treatment
and this report should support that conversation.
```

This gives you a more nuanced, narrative report than the app can auto-generate, and Claude can highlight patterns that simple programmatic analysis might miss.

---

## Part 4: Workflow Summary

### Daily
- Wear Apple Watch, use CPAP, log anxiety and medications in the app
- Data accumulates automatically

### Weekly
- Export the week's data to Claude for a quick check-in analysis
- Review trends in the app's dashboard

### Before Psychiatrist Appointments
- Generate a clinical report (PDF from app, or narrative from Claude)
- Print or share digitally with provider
- Use the report to ground the conversation in data

### Monthly
- Full 30-day export to Claude for deep pattern analysis
- Import CPAP data from SD card if not using cloud sync
- Review trends and adjust tracking as needed

### Quarterly
- Export full dataset for archival
- Assess whether additional data sources are adding value
- Consider hardware additions (Hilo Band, CGM) based on what patterns are emerging

---

## Part 5: Data Privacy Considerations

Since this data is deeply personal and includes health information:

1. **Local first** — all data stays on your device until you explicitly export or sync it
2. **Server security** — if you run a sync server, use HTTPS, API key auth, and keep it on a private network or behind a VPN
3. **Claude uploads** — when uploading to Claude for analysis, be aware that the data is being sent to Anthropic's servers. For maximum privacy, strip or anonymize identifying information before upload (the analysis doesn't need your name)
4. **Backups** — export and back up your data regularly. SwiftData stores are in the app's container; if you delete the app, the data is gone
5. **CPAP SD card** — your SD card contains detailed medical data. Store it securely when not in use
