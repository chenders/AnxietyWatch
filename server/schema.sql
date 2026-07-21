-- Anxiety Watch Sync Server — PostgreSQL Schema
-- REFERENCE ONLY — Alembic migrations are the authoritative schema source.
-- This file is read by alembic/versions/0001_baseline_schema.py.
-- To update the schema, create a new Alembic migration:
--   cd server && alembic revision -m "description"

CREATE TABLE IF NOT EXISTS api_keys (
    id              SERIAL PRIMARY KEY,
    key_hash        TEXT NOT NULL UNIQUE,
    key_prefix      TEXT NOT NULL,          -- first 8 chars, for display
    label           TEXT NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at    TIMESTAMPTZ,
    request_count   INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS anxiety_entries (
    timestamp       TIMESTAMPTZ NOT NULL PRIMARY KEY,
    severity        INTEGER NOT NULL CHECK (severity BETWEEN 1 AND 10),
    notes           TEXT NOT NULL DEFAULT '',
    tags            JSONB NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE IF NOT EXISTS medication_definitions (
    name            TEXT NOT NULL PRIMARY KEY,
    default_dose_mg DOUBLE PRECISION NOT NULL,
    category        TEXT NOT NULL DEFAULT '',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    -- 0013: raw CNSDepressantClass rawValue from the app's explicit picker
    -- (source of truth for dose-window monitoring); NULL = unclassified.
    cns_depressant_class TEXT
);

CREATE TABLE IF NOT EXISTS medication_doses (
    timestamp       TIMESTAMPTZ NOT NULL,
    medication_name TEXT NOT NULL,
    dose_mg         DOUBLE PRECISION NOT NULL,
    notes           TEXT,
    PRIMARY KEY (timestamp, medication_name)
);

CREATE TABLE IF NOT EXISTS cpap_sessions (
    date                DATE NOT NULL PRIMARY KEY,
    -- Nullable (migration 0007): NULL means "AHI not measured" (EDF-only
    -- imports carry leak/duration but no AHI). 0.0 is a real measured value.
    ahi                 DOUBLE PRECISION,
    total_usage_minutes INTEGER NOT NULL,
    leak_rate_95th      DOUBLE PRECISION,
    pressure_min        DOUBLE PRECISION,
    pressure_max        DOUBLE PRECISION,
    pressure_mean       DOUBLE PRECISION,
    obstructive_events  INTEGER NOT NULL DEFAULT 0,
    central_events      INTEGER NOT NULL DEFAULT 0,
    hypopnea_events     INTEGER NOT NULL DEFAULT 0,
    import_source       TEXT NOT NULL DEFAULT 'sd_card',
    -- By-session import fields (migration 0010). All nullable: NULL means
    -- "the source didn't report this" (e.g. no machine-attached oximeter) —
    -- never a fabricated 0. Units: rdi_events events/hour (a rate, like ahi);
    -- rera_events count; spo2_avg/spo2_min %; pulse_avg bpm;
    -- pressure_95th cmH2O; leak_avg/leak_max L/min.
    rdi_events          DOUBLE PRECISION,
    rera_events         INTEGER,
    spo2_avg            DOUBLE PRECISION,
    spo2_min            DOUBLE PRECISION,
    pulse_avg           DOUBLE PRECISION,
    pressure_95th       DOUBLE PRECISION,
    leak_avg            DOUBLE PRECISION,
    leak_max            DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS health_snapshots (
    date                    DATE NOT NULL PRIMARY KEY,
    hrv_avg                 DOUBLE PRECISION,
    hrv_min                 DOUBLE PRECISION,
    resting_hr              DOUBLE PRECISION,
    sleep_duration_min      INTEGER,
    sleep_deep_min          INTEGER,
    sleep_rem_min           INTEGER,
    sleep_core_min          INTEGER,
    sleep_awake_min         INTEGER,
    skin_temp_deviation     DOUBLE PRECISION,
    skin_temp_wrist         DOUBLE PRECISION,
    respiratory_rate        DOUBLE PRECISION,
    spo2_avg                DOUBLE PRECISION,
    spo2_nadir_overnight    DOUBLE PRECISION,
    spo2_nadir_opportunistic DOUBLE PRECISION,
    spo2_time_below_90_min  INTEGER,
    spo2_desats_count       INTEGER,
    -- SpO2 source basis (F-092): which sample population each metric group
    -- was computed from ('oximeter' | 'mixed'). aggregate = avg/nadir,
    -- burden = T90/desats; they can differ on a mixed-provenance night.
    spo2_aggregate_source   TEXT,
    spo2_burden_source      TEXT,
    steps                   INTEGER,
    active_calories         DOUBLE PRECISION,
    exercise_minutes        INTEGER,
    environmental_sound_avg DOUBLE PRECISION,
    bp_systolic             DOUBLE PRECISION,
    bp_diastolic            DOUBLE PRECISION,
    blood_glucose_avg       DOUBLE PRECISION,
    glucose_std_dev         DOUBLE PRECISION,
    glucose_cv              DOUBLE PRECISION,
    glucose_min             DOUBLE PRECISION,
    glucose_max             DOUBLE PRECISION,
    cpap_ahi                DOUBLE PRECISION,
    cpap_usage_minutes      INTEGER,
    barometric_pressure_avg_kpa    DOUBLE PRECISION,
    barometric_pressure_change_kpa DOUBLE PRECISION,
    data_quality            JSONB
);

CREATE TABLE IF NOT EXISTS barometric_readings (
    timestamp           TIMESTAMPTZ NOT NULL PRIMARY KEY,
    pressure_kpa        DOUBLE PRECISION NOT NULL,
    relative_altitude_m DOUBLE PRECISION NOT NULL
);

-- Per-sample mirror of HealthKit HKQuantitySample rows for clinically-
-- meaningful metrics (HR, HRV, glucose, SpO2, BP, body/wrist temp, etc.).
-- The `id` PK is the iOS UUID (= HKSample.uuid), so upsert by id is the
-- dedupe path for replays + retroactive HealthKit corrections.
CREATE TABLE IF NOT EXISTS quantity_health_samples (
    id                  UUID PRIMARY KEY,
    timestamp           TIMESTAMPTZ NOT NULL,
    metric_type         TEXT NOT NULL,
    value               DOUBLE PRECISION NOT NULL,
    unit_string         TEXT NOT NULL,
    source_bundle_id    TEXT NOT NULL,
    source_name         TEXT,
    device_model        TEXT,
    group_id            UUID,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_quantity_samples_metric_time
    ON quantity_health_samples (metric_type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_quantity_samples_group
    ON quantity_health_samples (group_id);

-- Per-event mirror of HealthKit HKCategorySample sleep-analysis rows.
CREATE TABLE IF NOT EXISTS sleep_stage_events (
    id                  UUID PRIMARY KEY,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    stage               TEXT NOT NULL,
    source_bundle_id    TEXT NOT NULL,
    source_name         TEXT,
    device_model        TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sleep_events_start
    ON sleep_stage_events (start_time DESC);

CREATE TABLE IF NOT EXISTS sync_log (
    id              SERIAL PRIMARY KEY,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sync_type       TEXT NOT NULL,
    device_name     TEXT,
    record_counts   JSONB NOT NULL DEFAULT '{}'::jsonb,
    api_key_id      INTEGER REFERENCES api_keys(id)
);

CREATE TABLE IF NOT EXISTS pharmacies (
    name            TEXT NOT NULL PRIMARY KEY,
    address         TEXT NOT NULL DEFAULT '',
    phone_number    TEXT NOT NULL DEFAULT '',
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,
    notes           TEXT NOT NULL DEFAULT '',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS prescriptions (
    rx_number               TEXT NOT NULL PRIMARY KEY,
    medication_name         TEXT NOT NULL,
    dose_mg                 DOUBLE PRECISION NOT NULL,
    dose_description        TEXT NOT NULL DEFAULT '',
    date_filled             TIMESTAMPTZ NOT NULL,
    pharmacy_name           TEXT NOT NULL DEFAULT '',
    notes                   TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS pharmacy_call_logs (
    timestamp           TIMESTAMPTZ NOT NULL,
    pharmacy_name       TEXT NOT NULL,
    direction           TEXT NOT NULL DEFAULT 'attempted',
    notes               TEXT NOT NULL DEFAULT '',
    duration_seconds    INTEGER,
    PRIMARY KEY (timestamp, pharmacy_name)
);

CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS correlations (
    id              SERIAL PRIMARY KEY,
    signal_name     TEXT NOT NULL,
    correlation     DOUBLE PRECISION NOT NULL,
    p_value         DOUBLE PRECISION NOT NULL,
    sample_count    INTEGER NOT NULL,
    mean_severity_when_abnormal DOUBLE PRECISION,
    mean_severity_when_normal   DOUBLE PRECISION,
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(signal_name)
);

CREATE TABLE IF NOT EXISTS analyses (
    id              SERIAL PRIMARY KEY,
    date_from       DATE NOT NULL,
    date_to         DATE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    model           TEXT NOT NULL,
    request_payload JSONB,
    response_payload JSONB,
    summary         TEXT,
    trend_direction TEXT,
    insights        JSONB,
    tokens_in       INTEGER,
    tokens_out      INTEGER,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    error_message   TEXT,
    dose_tracking_incomplete BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS therapy_sessions (
    id              SERIAL PRIMARY KEY,
    frequency       TEXT NOT NULL DEFAULT 'weekly'
                        CHECK (frequency IN ('weekly', 'monthly')),
    day_of_week     INTEGER CHECK (day_of_week BETWEEN 0 AND 6),
    day_of_month    INTEGER CHECK (day_of_month BETWEEN 1 AND 31),
    time_of_day     TIME NOT NULL,
    session_type    TEXT NOT NULL DEFAULT 'in-person'
                        CHECK (session_type IN ('in-person', 'virtual')),
    commute_minutes INTEGER NOT NULL DEFAULT 0 CHECK (commute_minutes >= 0),
    notes           TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (frequency = 'weekly' AND day_of_week IS NOT NULL AND day_of_month IS NULL)
        OR
        (frequency = 'monthly' AND day_of_month IS NOT NULL AND day_of_week IS NULL)
    )
);

CREATE TABLE IF NOT EXISTS patient_profile (
    id                          SERIAL PRIMARY KEY,
    name                        TEXT,
    date_of_birth               DATE,
    gender                      TEXT,
    medical_history_raw         TEXT,
    medical_history_structured  TEXT,
    other_medications           TEXT,
    profile_summary             TEXT,
    updated_at                  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS psychiatrist_profile (
    id                SERIAL PRIMARY KEY,
    name              TEXT NOT NULL,
    location          TEXT NOT NULL,
    research_result   JSONB,
    profile_summary   TEXT,
    researched_at     TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS conflicts (
    id                              SERIAL PRIMARY KEY,
    status                          TEXT NOT NULL DEFAULT 'active'
                                        CHECK (status IN ('active', 'resolved')),
    description                     TEXT NOT NULL,
    patient_perspective             TEXT,
    patient_assumptions             TEXT,
    patient_desired_resolution      TEXT,
    patient_wants_from_other        TEXT,
    psychiatrist_perspective        TEXT,
    psychiatrist_assumptions        TEXT,
    psychiatrist_desired_resolution TEXT,
    psychiatrist_wants_from_other   TEXT,
    additional_context              TEXT,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at                     TIMESTAMPTZ,
    updated_at                      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS analysis_jobs (
    id                SERIAL PRIMARY KEY,
    analysis_id       INTEGER NOT NULL REFERENCES analyses(id),
    conflict_id       INTEGER REFERENCES conflicts(id),
    job_type          TEXT NOT NULL
                          CHECK (job_type IN (
                              'health_analysis',
                              'patient_validity',
                              'psychiatrist_validity',
                              'patient_criticism',
                              'psychiatrist_criticism',
                              'conflict_synthesis'
                          )),
    depends_on        INTEGER[],
    status            TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    request_payload   JSONB,
    response_payload  JSONB,
    result            JSONB,
    model             TEXT NOT NULL,
    tokens_in         INTEGER,
    tokens_out        INTEGER,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at        TIMESTAMPTZ,
    completed_at      TIMESTAMPTZ,
    error_message     TEXT
);

-- Indexes for common query patterns (only on non-PK / non-UNIQUE columns)
CREATE INDEX IF NOT EXISTS idx_sync_log_received_at ON sync_log (received_at DESC);
CREATE INDEX IF NOT EXISTS idx_conflicts_status_created
    ON conflicts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_analysis_id_job_type
    ON analysis_jobs (analysis_id, job_type);
CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status
    ON analysis_jobs (status);

CREATE TABLE IF NOT EXISTS songs (
    id              SERIAL PRIMARY KEY,
    genius_id       INTEGER UNIQUE,
    title           TEXT NOT NULL,
    artist          TEXT NOT NULL,
    album           TEXT,
    album_art_url   TEXT,
    genius_url      TEXT,
    lyrics          TEXT,
    lyrics_source   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_songs_manual_title_artist_unique
    ON songs (lower(btrim(title)), lower(btrim(artist)))
    WHERE genius_id IS NULL;

CREATE TABLE IF NOT EXISTS song_occurrences (
    id               SERIAL PRIMARY KEY,
    song_id          INTEGER NOT NULL REFERENCES songs(id),
    timestamp        TIMESTAMPTZ NOT NULL,
    source           TEXT NOT NULL DEFAULT 'standalone',
    anxiety_entry_id TIMESTAMPTZ,
    notes            TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT song_occurrences_natural_key_unique
        UNIQUE (song_id, timestamp, source)
);

CREATE INDEX IF NOT EXISTS idx_song_occurrences_timestamp
    ON song_occurrences (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_song_occurrences_song_id_timestamp
    ON song_occurrences (song_id, timestamp DESC);

-- Polar H10 chest-strap recording sessions. One row per wear-session
-- recorded via the iOS BLE pipeline; per-minute HRV rows in hrv_readings
-- reference this row by id. Optional rr_archive BYTEA carries the
-- gzipped raw RR-interval stream the iOS side uploads after the session
-- ends. Source is e.g. "polar_h10".
CREATE TABLE IF NOT EXISTS sensor_sessions (
    id                   UUID PRIMARY KEY,
    source               TEXT NOT NULL,
    start_time           TIMESTAMPTZ NOT NULL,
    end_time             TIMESTAMPTZ,
    battery_at_start     INTEGER,
    interruption_count   INTEGER NOT NULL DEFAULT 0,
    summary_json         JSONB,
    rr_archive           BYTEA,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sensor_sessions_source_start
    ON sensor_sessions (source, start_time DESC);

-- Per-minute HRV readings produced by HRVSessionRecorder. lf_power,
-- hf_power, and lf_hf_ratio are nullable: per-minute windows with
-- <30 RR intervals can compute time-domain HRV but not frequency-domain.
-- iOS writes the values when the window had ≥30 intervals, NULL otherwise.
CREATE TABLE IF NOT EXISTS hrv_readings (
    id            UUID PRIMARY KEY,
    session_id    UUID NOT NULL REFERENCES sensor_sessions(id) ON DELETE CASCADE,
    timestamp     TIMESTAMPTZ NOT NULL,
    rmssd         DOUBLE PRECISION NOT NULL,
    sdnn          DOUBLE PRECISION NOT NULL,
    pnn50         DOUBLE PRECISION NOT NULL,
    lf_power      DOUBLE PRECISION,
    hf_power      DOUBLE PRECISION,
    lf_hf_ratio   DOUBLE PRECISION,
    source        TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_hrv_readings_session
    ON hrv_readings (session_id);
CREATE INDEX IF NOT EXISTS idx_hrv_readings_timestamp
    ON hrv_readings (timestamp DESC);

-- 10-second accelerometer FFT spectral windows captured on the Watch
-- (tremor / breathing / fidget band power + overall RMS activity).
-- session_id is nullable and deliberately NOT a foreign key: Watch-side
-- capture sessions never materialize as sensor_sessions rows, so a
-- constraint would reject every Watch-origin batch. Mirrors the
-- hrv_readings indexes.
CREATE TABLE IF NOT EXISTS accel_spectrograms (
    id                    UUID PRIMARY KEY,
    session_id            UUID,
    timestamp             TIMESTAMPTZ NOT NULL,
    tremor_band_power     DOUBLE PRECISION NOT NULL,
    breathing_band_power  DOUBLE PRECISION NOT NULL,
    fidget_band_power     DOUBLE PRECISION NOT NULL,
    activity_level        DOUBLE PRECISION NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_accel_spectrograms_session
    ON accel_spectrograms (session_id);
CREATE INDEX IF NOT EXISTS idx_accel_spectrograms_timestamp
    ON accel_spectrograms (timestamp DESC);

-- Per-minute breathing rate derived from Watch accelerometer wrist
-- motion. source is "accelerometer" or "healthkit_sleep". Same nullable
-- non-FK session_id contract as accel_spectrograms above.
CREATE TABLE IF NOT EXISTS derived_breathing_rates (
    id                  UUID PRIMARY KEY,
    session_id          UUID,
    timestamp           TIMESTAMPTZ NOT NULL,
    breaths_per_minute  DOUBLE PRECISION NOT NULL,
    confidence          DOUBLE PRECISION NOT NULL,
    source              TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_derived_breathing_rates_session
    ON derived_breathing_rates (session_id);
CREATE INDEX IF NOT EXISTS idx_derived_breathing_rates_timestamp
    ON derived_breathing_rates (timestamp DESC);

-- -----------------------------------------------------------------------------
-- Delta Sync Protocol Tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS samples (
    source        INTEGER NOT NULL,
    type          INTEGER NOT NULL,
    timestamp     DOUBLE PRECISION NOT NULL,
    value         DOUBLE PRECISION NOT NULL,
    extra         BYTEA,
    hlc_physical  BIGINT NOT NULL,
    hlc_logical   INTEGER NOT NULL,
    node_id       BYTEA NOT NULL,
    PRIMARY KEY (source, type, timestamp)
);

CREATE INDEX IF NOT EXISTS idx_samples_hlc
    ON samples (node_id, hlc_physical, hlc_logical);

CREATE TABLE IF NOT EXISTS sample_tombstones (
    source            INTEGER NOT NULL,
    type              INTEGER NOT NULL,
    ts_start          DOUBLE PRECISION NOT NULL,
    ts_end            DOUBLE PRECISION NOT NULL,
    hlc_physical      BIGINT NOT NULL,
    hlc_logical       INTEGER NOT NULL,
    node_id           BYTEA NOT NULL,
    dropped_row_count INTEGER NOT NULL,
    reason            TEXT NOT NULL,
    PRIMARY KEY (source, type, ts_start, hlc_physical, hlc_logical, node_id)
);

CREATE INDEX IF NOT EXISTS idx_sample_tombstones_hlc
    ON sample_tombstones (node_id, hlc_physical, hlc_logical);

CREATE TABLE IF NOT EXISTS delta_sync_log (
    table_name    TEXT NOT NULL,
    row_pk        TEXT NOT NULL,
    hlc_physical  BIGINT NOT NULL,
    hlc_logical   INTEGER NOT NULL,
    node_id       BYTEA NOT NULL,
    operation     TEXT NOT NULL,
    PRIMARY KEY (table_name, row_pk)
);

CREATE INDEX IF NOT EXISTS idx_delta_sync_log_hlc
    ON delta_sync_log (node_id, hlc_physical, hlc_logical);

-- -----------------------------------------------------------------------------
-- Oura Integration Tables
-- -----------------------------------------------------------------------------


CREATE TABLE IF NOT EXISTS oura_credentials (
    id SERIAL PRIMARY KEY,
    access_token BYTEA NOT NULL,
    refresh_token BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    scope TEXT NOT NULL,
    oura_user_id TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS oura_ibi (
    ts TIMESTAMPTZ NOT NULL,
    ibi_ms INTEGER NOT NULL,
    validity INTEGER NOT NULL,
    PRIMARY KEY (ts)
);

CREATE TABLE IF NOT EXISTS oura_heartrate (
    ts TIMESTAMPTZ NOT NULL,
    bpm INTEGER NOT NULL,
    source TEXT NOT NULL,
    PRIMARY KEY (ts)
);

CREATE TABLE IF NOT EXISTS oura_sleep (
    day DATE NOT NULL PRIMARY KEY,
    stages_hypnogram TEXT,
    hrv_5min INTEGER[],
    rr DOUBLE PRECISION[],
    resp_rate DOUBLE PRECISION,
    efficiency INTEGER,
    latency INTEGER,
    document_id TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS oura_daily (
    day DATE NOT NULL PRIMARY KEY,
    readiness INTEGER,
    sleep_score INTEGER,
    activity_score INTEGER,
    stress_high_s INTEGER,
    recovery_high_s INTEGER,
    resilience_level TEXT,
    temp_deviation_c DOUBLE PRECISION,
    spo2_avg DOUBLE PRECISION,
    bdi DOUBLE PRECISION,
    vascular_age DOUBLE PRECISION,
    pwv DOUBLE PRECISION,
    vo2_max DOUBLE PRECISION,
    document_id TEXT NOT NULL UNIQUE
);

-- -----------------------------------------------------------------------------
-- AirSense 11 (aircannect) Integration Tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS as11_therapy_session (
    id SERIAL PRIMARY KEY,
    bridge_id TEXT NOT NULL,
    start_utc TIMESTAMPTZ NOT NULL,
    end_utc TIMESTAMPTZ,
    mode TEXT,
    set_pressure DOUBLE PRECISION,
    min_pressure DOUBLE PRECISION,
    max_pressure DOUBLE PRECISION,
    median_pressure DOUBLE PRECISION,
    p95_leak DOUBLE PRECISION,
    ahi DOUBLE PRECISION,
    event_counts JSONB,
    mask_on_fraction DOUBLE PRECISION,
    source TEXT NOT NULL,
    settings_snapshot JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_as11_therapy_session_start
    ON as11_therapy_session (start_utc DESC);

CREATE TABLE IF NOT EXISTS as11_stream_sample (
    id SERIAL PRIMARY KEY,
    bridge_id TEXT NOT NULL,
    ts_utc TIMESTAMPTZ NOT NULL,
    channel TEXT NOT NULL,
    value DOUBLE PRECISION NOT NULL,
    unit TEXT,
    ingest_ts_utc TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    session_id INTEGER REFERENCES as11_therapy_session(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_as11_stream_sample_ts
    ON as11_stream_sample (ts_utc DESC);

-- Sub-project C: server redundant alert channel (backstop + heartbeat + push).
-- Buffer of SpO2/HR samples the app uploads during an armed BLE-active session;
-- the conservative backstop and the no-data heartbeat run over these rows.
CREATE TABLE IF NOT EXISTS session_sample_buffer (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    ts_utc TIMESTAMPTZ NOT NULL,
    channel TEXT NOT NULL,
    value DOUBLE PRECISION NOT NULL,
    -- Which sensor produced the sample (e.g. 'emay', 'as11'). The backstop
    -- evaluates each source independently so a normal reading from one
    -- concurrently-active SpO2 source can't reset (mask) a sustained low on
    -- another. Nullable: an omitted source groups as a single stream.
    source TEXT,
    ingest_ts_utc TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_session_sample_buffer_session_ts
    ON session_sample_buffer (session_id, ts_utc DESC);

-- Supports the heartbeat sweep's per-session MAX(ingest_ts_utc) lookup.
CREATE INDEX IF NOT EXISTS idx_session_sample_buffer_session_ingest
    ON session_sample_buffer (session_id, ingest_ts_utc DESC);

-- APNs device push tokens registered by the app (dedup on token).
CREATE TABLE IF NOT EXISTS device_push_token (
    id SERIAL PRIMARY KEY,
    token TEXT NOT NULL UNIQUE,
    env TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- At most one row per (session_id, kind) event. The push is delivery-gated:
-- the row is written (INSERT ... ON CONFLICT DO NOTHING) only AFTER a successful
-- push, so a crash mid-push leaves no row and the alert stays retryable. The
-- UNIQUE index keeps a concurrent append/sweep from creating a duplicate row;
-- exactly-once holds for the row, though a rare same-key race may still
-- double-push (acceptable for a redundant channel). The row is deleted when the
-- heartbeat clears on resume, so a later occurrence can re-fire.
CREATE TABLE IF NOT EXISTS alert_event (
    id SERIAL PRIMARY KEY,
    session_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    ts_utc TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_alert_event_session_kind
    ON alert_event (session_id, kind);


