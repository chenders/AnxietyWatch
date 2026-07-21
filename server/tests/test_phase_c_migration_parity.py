"""Schema ↔ migration parity for the Phase C alert-channel tables.

The pytest harness builds the DB from ``schema.sql`` (``_init_db`` executes it
verbatim), but production applies the Alembic migrations. If the two drift, a
Phase C table (``session_sample_buffer`` / ``device_push_token`` /
``alert_event``) could exist under pytest yet never be created by a fresh
``alembic upgrade`` — the same silent gap the CLAUDE.md "syncs UP but no way
back DOWN" rule warns about, applied to DDL.

This test applies the migration's ``upgrade()`` into a throwaway schema and
diffs every Phase C table's columns and indexes against the schema.sql-built
copy in ``public``. It runs the real migration function (with an Alembic
``Operations`` bound to a private-schema connection), so a migration that fails
to run at all — or that creates a structurally different table — fails here.
"""
import importlib.util
import os

import pytest
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, text

from tests.test_server import DATABASE_URL, _init_db  # noqa: F401  (pytest fixture)

PHASE_C_TABLES = ("session_sample_buffer", "device_push_token", "alert_event")
PARITY_SCHEMA = "phase_c_parity"

_VERSIONS_DIR = os.path.join(os.path.dirname(__file__), "..", "alembic", "versions")
# Applied in order — the second ALTERs the table the first creates, so the
# private schema ends up matching schema.sql (which has `source`).
MIGRATION_FILES = [
    os.path.join(_VERSIONS_DIR, "c5d7e9f10a2b_add_alert_channel_tables.py"),
    os.path.join(_VERSIONS_DIR, "d6e8fa0b1c34_add_source_to_session_sample_buffer.py"),
]


def _load_migration(path):
    """Import a migration module by path (it is not on the import path)."""
    spec = importlib.util.spec_from_file_location("phase_c_migration_under_test", path)
    assert spec is not None and spec.loader is not None, f"cannot load migration at {path}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _columns(conn, schema):
    """{table: {column: (data_type, is_nullable, has_default)}} for the Phase C tables."""
    rows = conn.execute(
        text(
            """
            SELECT table_name, column_name, data_type, is_nullable,
                   (column_default IS NOT NULL) AS has_default
            FROM information_schema.columns
            WHERE table_schema = :schema AND table_name = ANY(:tables)
            """
        ),
        {"schema": schema, "tables": list(PHASE_C_TABLES)},
    ).fetchall()
    out = {t: {} for t in PHASE_C_TABLES}
    for table_name, column, data_type, is_nullable, has_default in rows:
        out[table_name][column] = (data_type, is_nullable, has_default)
    return out


def _indexes(conn, schema):
    """{table: {normalized index definitions}} — schema qualifier stripped so the
    two schemas compare equal (index/constraint names are identical in both)."""
    rows = conn.execute(
        text(
            "SELECT tablename, indexdef FROM pg_indexes "
            "WHERE schemaname = :schema AND tablename = ANY(:tables)"
        ),
        {"schema": schema, "tables": list(PHASE_C_TABLES)},
    ).fetchall()
    out = {t: set() for t in PHASE_C_TABLES}
    for table_name, indexdef in rows:
        out[table_name].add(indexdef.replace(f"{schema}.", ""))
    return out


@pytest.fixture(scope="module")
def parity_engine(_init_db):  # noqa: F811  (pytest fixture injection shadows the import)
    """Apply the migration into ``PARITY_SCHEMA`` once; drop it on teardown.

    Depends on ``_init_db`` (session-scoped) so the schema.sql-built ``public``
    tables the test diffs against are present.
    """
    engine = create_engine(DATABASE_URL)
    try:
        with engine.begin() as conn:
            conn.execute(text(f"DROP SCHEMA IF EXISTS {PARITY_SCHEMA} CASCADE"))
            conn.execute(text(f"CREATE SCHEMA {PARITY_SCHEMA}"))
            conn.execute(text(f"SET search_path TO {PARITY_SCHEMA}"))
            # Apply the migration chain in order. Bind each migration's op proxy
            # to THIS connection/schema and run the real upgrade() so any
            # failure-to-run surfaces as a test failure.
            for path in MIGRATION_FILES:
                migration = _load_migration(path)
                migration.op = Operations(MigrationContext.configure(connection=conn))
                migration.upgrade()
        yield engine
    finally:
        with engine.begin() as conn:
            conn.execute(text(f"DROP SCHEMA IF EXISTS {PARITY_SCHEMA} CASCADE"))
        engine.dispose()


def test_migration_creates_all_phase_c_tables(parity_engine):
    with parity_engine.connect() as conn:
        created = _columns(conn, PARITY_SCHEMA)
    for table in PHASE_C_TABLES:
        assert created[table], f"migration upgrade() did not create {table}"


@pytest.mark.parametrize("table", PHASE_C_TABLES)
def test_columns_match_schema_sql(parity_engine, table):
    with parity_engine.connect() as conn:
        schema_sql_cols = _columns(conn, "public")[table]
        migration_cols = _columns(conn, PARITY_SCHEMA)[table]
    assert migration_cols == schema_sql_cols, (
        f"{table}: migration columns diverge from schema.sql\n"
        f"  schema.sql: {schema_sql_cols}\n  migration:  {migration_cols}"
    )


@pytest.mark.parametrize("table", PHASE_C_TABLES)
def test_indexes_match_schema_sql(parity_engine, table):
    with parity_engine.connect() as conn:
        schema_sql_idx = _indexes(conn, "public")[table]
        migration_idx = _indexes(conn, PARITY_SCHEMA)[table]
    assert migration_idx == schema_sql_idx, (
        f"{table}: migration indexes diverge from schema.sql\n"
        f"  schema.sql: {sorted(schema_sql_idx)}\n  migration:  {sorted(migration_idx)}"
    )
