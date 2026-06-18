from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import URL


class AppSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="DEMO_APP_")

    # Database — individual fields (used in K8s with secrets)
    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "demo"
    db_user: str = "app"
    db_password: str = ""  # From ESO/Vault secret, or set locally
    db_schema: str = "public"

    # Database — full connection string override.
    # When set, takes priority over individual DB_* fields.
    # Supports: postgresql://user:pass@host:port/dbname (driver auto-detected)
    # Also accepts: postgresql+asyncpg:// or postgresql+psycopg:// explicitly
    database_url: str | None = None

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

    # Security — secret used to sign CSRF tokens on the HTML form routes.
    # The default is deterministic, so it already works across replicas/restarts;
    # in production set DEMO_APP_CSRF_SECRET to a real secret so the signing key
    # isn't a published constant.
    csrf_secret: str = "dev-insecure-csrf-secret-change-me"

    @property
    def database_url_async(self) -> str:
        """Async database URL (asyncpg driver).

        Priority: DEMO_APP_DATABASE_URL > individual DEMO_APP_DB_* fields.
        If DATABASE_URL uses postgresql://, the driver is auto-replaced
        with postgresql+asyncpg://. If it already specifies a driver,
        it's used as-is.
        """
        if self.database_url:
            url = self.database_url
            # Replace plain postgresql:// with asyncpg driver
            if url.startswith("postgresql://"):
                url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
            # If user specified psycopg or another sync driver, swap to asyncpg
            url = url.replace("+psycopg://", "+asyncpg://", 1)
            url = url.replace("+psycopg2://", "+asyncpg://", 1)
            return url
        # URL.create percent-encodes special characters in the credentials
        # (e.g. @ : / ? in a generated password) that would otherwise break
        # URL parsing.
        return URL.create(
            "postgresql+asyncpg",
            username=self.db_user,
            password=self.db_password,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        ).render_as_string(hide_password=False)

    @property
    def database_url_sync(self) -> str:
        """Sync URL for Alembic migrations (psycopg driver).

        Priority: DEMO_APP_DATABASE_URL > individual DEMO_APP_DB_* fields.
        Always uses psycopg driver for sync operations.
        """
        if self.database_url:
            url = self.database_url
            # Normalize to sync psycopg driver
            if url.startswith("postgresql+asyncpg://"):
                url = url.replace("+asyncpg://", "+psycopg://", 1)
            elif url.startswith("postgresql://"):
                url = url.replace("postgresql://", "postgresql+psycopg://", 1)
            elif url.startswith("postgresql+psycopg2://"):
                url = url.replace("+psycopg2://", "+psycopg://", 1)
            return url
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
        ).render_as_string(hide_password=False)