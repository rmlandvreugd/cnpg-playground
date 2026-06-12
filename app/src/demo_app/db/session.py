from advanced_alchemy.extensions.litestar import SQLAlchemyAsyncConfig, AsyncSessionConfig
from demo_app.config import AppSettings


def get_sqlalchemy_config(settings: AppSettings) -> SQLAlchemyAsyncConfig:
    """Create SQLAlchemy async config from app settings."""
    return SQLAlchemyAsyncConfig(
        connection_string=settings.database_url_async,
        before_send_handler="autocommit",
        session_config=AsyncSessionConfig(
            expire_on_commit=False,
        ),
        engine_config={
            "pool_size": 5,
            "max_overflow": 10,
            "pool_pre_ping": True,
            "pool_recycle": 300,
            "pool_timeout": 30,
        },
    )
