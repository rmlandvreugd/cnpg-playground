from advanced_alchemy.extensions.litestar import (
    AlembicAsyncConfig,
    AsyncSessionConfig,
    SQLAlchemyAsyncConfig,
)
from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from demo_app.config import AppSettings


def pin_search_path(engine: AsyncEngine, schema: str) -> None:
    """Issue ``SET search_path`` on every new connection of ``engine``.

    The app talks to PgBouncer (session pooling), which silently *ignores*
    connection startup parameters such as asyncpg's ``server_settings``
    search_path — so the schema must be selected with a SET command after
    connect, not via a startup parameter. ``schema`` comes from trusted config.
    """

    @event.listens_for(engine.sync_engine, "connect")
    def _set_search_path(dbapi_connection, _connection_record):  # noqa: ANN202
        cursor = dbapi_connection.cursor()
        cursor.execute(f'SET search_path TO "{schema}", public')
        cursor.close()


def get_sqlalchemy_config(settings: AppSettings) -> SQLAlchemyAsyncConfig:
    """Create SQLAlchemy async config from app settings."""
    engine = create_async_engine(
        settings.database_url_async,
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,
        pool_recycle=300,
        pool_timeout=30,
    )
    pin_search_path(engine, settings.db_schema)

    return SQLAlchemyAsyncConfig(
        engine_instance=engine,
        # "autocommit" only commits on 2xx responses; our page handlers use the
        # POST-redirect-GET pattern and return 3xx redirects, so we need the
        # variant that also commits on redirect responses — otherwise writes are
        # silently rolled back at session teardown.
        before_send_handler="autocommit_include_redirects",
        # Point the `litestar database` CLI at the in-package migrations dir
        # (default is "migrations" relative to CWD, which doesn't exist here).
        alembic_config=AlembicAsyncConfig(
            script_location="src/demo_app/migrations",
        ),
        session_config=AsyncSessionConfig(
            expire_on_commit=False,
        ),
    )
