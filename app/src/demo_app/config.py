from pydantic_settings import BaseSettings, SettingsConfigDict


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="DEMO_APP_")

    # Database
    db_host: str = "pooler-demo-rw.demo-db.svc.cluster.local"
    db_port: int = 5432
    db_name: str = "demo"
    db_user: str = "app"
    db_password: str = ""  # From ESO/Vault secret
    db_schema: str = "public"

    # Application
    app_version: str = "0.1.0"
    debug: bool = False
    log_level: str = "INFO"

    # Observability
    otlp_endpoint: str = "http://otel-collector.otel.svc.cluster.local:4317"
    metrics_enabled: bool = True
    tracing_enabled: bool = False  # v1: off, v2: on

    # Server
    host: str = "0.0.0.0"
    port: int = 8000

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    @property
    def database_url_sync(self) -> str:
        """Sync URL for Alembic migrations."""
        return (
            f"postgresql+psycopg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )
