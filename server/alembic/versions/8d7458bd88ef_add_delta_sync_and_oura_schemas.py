"""Add delta sync and oura schemas

Revision ID: 8d7458bd88ef
Revises: 0013
Create Date: 2026-07-17 06:12:59.315923
"""
from alembic import op


revision = '8d7458bd88ef'
down_revision = '0013'
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""
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
    CREATE INDEX IF NOT EXISTS idx_samples_hlc ON samples(node_id, hlc_physical, hlc_logical);

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
    CREATE INDEX IF NOT EXISTS idx_sample_tombstones_hlc ON sample_tombstones(node_id, hlc_physical, hlc_logical);

    CREATE TABLE IF NOT EXISTS delta_sync_log (
        table_name    TEXT NOT NULL,
        row_pk        TEXT NOT NULL,
        hlc_physical  BIGINT NOT NULL,
        hlc_logical   INTEGER NOT NULL,
        node_id       BYTEA NOT NULL,
        operation     TEXT NOT NULL,
        PRIMARY KEY (table_name, row_pk)
    );
    CREATE INDEX IF NOT EXISTS idx_delta_sync_log_hlc ON delta_sync_log(node_id, hlc_physical, hlc_logical);

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
    """)


def downgrade():
    op.execute("""
    DROP TABLE IF EXISTS oura_daily;
    DROP TABLE IF EXISTS oura_sleep;
    DROP TABLE IF EXISTS oura_heartrate;
    DROP TABLE IF EXISTS oura_ibi;
    DROP TABLE IF EXISTS oura_credentials;
    DROP TABLE IF EXISTS delta_sync_log;
    DROP TABLE IF EXISTS sample_tombstones;
    DROP TABLE IF EXISTS samples;
    """)
