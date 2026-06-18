import asyncio
import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool, text
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config
from sqlalchemy.schema import CreateSchema

from demo_app.config import AppSettings

# Import the Base metadata and models so autogenerate can detect them
from demo_app.db.base import Base
from demo_app.db.models import Task  # noqa: F401

# this is the Alembic Config object
config = context.config

# Interpret the config file for Python logging.
# advanced-alchemy's CLI sets config_file_name to "alembic.ini" even though no
# physical ini file exists here, so guard on the file actually being present.
if config.config_file_name is not None and os.path.exists(config.config_file_name):
    fileConfig(config.config_file_name)

# Set the database URL from app settings (use sync driver for Alembic)
settings = AppSettings()
config.set_main_option("sqlalchemy.url", settings.database_url_sync)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    """Run migrations with a sync connection, honoring DEMO_APP_DB_SCHEMA.

    Tables (and alembic_version) land in ``db_schema`` instead of always in
    ``public``. The schema is created on demand and pinned via search_path so
    unqualified DDL resolves to it.
    """
    schema = settings.db_schema or "public"
    non_public = schema != "public"
    quoted = connection.dialect.identifier_preparer.quote_schema(schema)

    if non_public:
        connection.execute(CreateSchema(schema, if_not_exists=True))
    connection.execute(text(f"SET search_path TO {quoted}, public"))
    connection.commit()

    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        version_table_schema=schema if non_public else None,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    """Run migrations in 'online' mode with async engine."""
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


def run_migrations_online() -> None:
    """Entry point for online migrations."""
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
