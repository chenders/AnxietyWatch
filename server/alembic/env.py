"""Alembic environment — connects to PostgreSQL via DATABASE_URL."""

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine

config = context.config

if config.config_file_name is not None:
    # disable_existing_loggers=False: create_app() runs `alembic upgrade` at
    # startup, and fileConfig's default (True) would silently disable every
    # logger created before that point — including Flask's app logger — so
    # app.logger.warning() calls would produce nothing in any process that
    # creates more than one app (tests, reloaders).
    fileConfig(config.config_file_name, disable_existing_loggers=False)

# No SQLAlchemy models — we use raw SQL migrations.
target_metadata = None


def get_url():
    """Read database URL from environment, falling back to alembic.ini."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    url = config.get_main_option("sqlalchemy.url", "")
    if url:
        return url
    raise RuntimeError(
        "DATABASE_URL environment variable is not set "
        "and no sqlalchemy.url configured in alembic.ini"
    )


def run_migrations_offline():
    """Emit SQL to stdout without connecting to a database."""
    context.configure(
        url=get_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online():
    """Run migrations against a live database."""
    engine = create_engine(get_url())
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
