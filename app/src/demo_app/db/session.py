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
        before_send_handler="autocommit",
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
        ),
    )
