-- Anxiety Watch Sync Server — PostgreSQL Schema
-- Applied automatically on app startup via init_db()

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
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
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
    ahi                 DOUBLE PRECISION NOT NULL,
    total_usage_minutes INTEGER NOT NULL,
    leak_rate_95th      DOUBLE PRECISION,
    pressure_min        DOUBLE PRECISION,
    pressure_max        DOUBLE PRECISION,
    pressure_mean       DOUBLE PRECISION,
    obstructive_events  INTEGER NOT NULL DEFAULT 0,
    central_events      INTEGER NOT NULL DEFAULT 0,
    hypopnea_events     INTEGER NOT NULL DEFAULT 0,
    import_source       TEXT NOT NULL DEFAULT 'sd_card'
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
    respiratory_rate        DOUBLE PRECISION,
    spo2_avg                DOUBLE PRECISION,
    steps                   INTEGER,
    active_calories         DOUBLE PRECISION,
    exercise_minutes        INTEGER,
    environmental_sound_avg DOUBLE PRECISION,
    bp_systolic             DOUBLE PRECISION,
    bp_diastolic            DOUBLE PRECISION,
    blood_glucose_avg       DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS barometric_readings (
    timestamp           TIMESTAMPTZ NOT NULL PRIMARY KEY,
    pressure_kpa        DOUBLE PRECISION NOT NULL,
    relative_altitude_m DOUBLE PRECISION NOT NULL
);

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
    quantity                INTEGER NOT NULL,
    refills_remaining       INTEGER NOT NULL DEFAULT 0,
    date_filled             TIMESTAMPTZ NOT NULL,
    estimated_run_out_date  TIMESTAMPTZ,
    pharmacy_name           TEXT NOT NULL DEFAULT '',
    notes                   TEXT NOT NULL DEFAULT '',
    daily_dose_count        DOUBLE PRECISION,
    prescriber_name         TEXT NOT NULL DEFAULT '',
    ndc_code                TEXT NOT NULL DEFAULT '',
    rx_status               TEXT NOT NULL DEFAULT '',
    last_fill_date          TIMESTAMPTZ,
    import_source           TEXT NOT NULL DEFAULT 'manual',
    walgreens_rx_id         TEXT,
    directions              TEXT NOT NULL DEFAULT '',
    days_supply             INTEGER,
    patient_pay             DOUBLE PRECISION,
    plan_pay                DOUBLE PRECISION,
    dosage_form             TEXT NOT NULL DEFAULT '',
    drug_type               TEXT NOT NULL DEFAULT ''
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

-- Indexes for common query patterns (only on non-PK / non-UNIQUE columns)
CREATE INDEX IF NOT EXISTS idx_sync_log_received_at ON sync_log (received_at DESC);
