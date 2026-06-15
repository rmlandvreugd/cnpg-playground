from advanced_alchemy.extensions.litestar import (
    AlembicAsyncConfig,
    AsyncSessionConfig,
    EngineConfig,
    SQLAlchemyAsyncConfig,
)

from demo_app.config import AppSettings


def get_sqlalchemy_config(settings: AppSettings) -> SQLAlchemyAsyncConfig:
    """Create SQLAlchemy async config from app settings."""
    return SQLAlchemyAsyncConfig(
        connection_string=settings.database_url_async,
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
        engine_config=EngineConfig(
            pool_size=5,
            max_overflow=10,
            pool_pre_ping=True,
            pool_recycle=300,
            pool_timeout=30,
            # Pin the asyncpg connection's search_path to the configured schema
            # (migrations create it). Sent as a startup parameter, so it is not
            # subject to SQL injection.
            connect_args={"server_settings": {"search_path": settings.db_schema}},
        ),
    )
