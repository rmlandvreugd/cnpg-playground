from litestar import Controller, get
from litestar.exceptions import ServiceUnavailableException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


class HealthController(Controller):
    path = "/health"

    @get(path="/", status_code=200, operation_id="HealthCheck")
    async def health(self) -> dict:
        """Liveness probe — always returns healthy if the app is running."""
        return {"status": "healthy"}

    @get(path="/ready", status_code=200, operation_id="ReadinessCheck")
    async def ready(self, db_session: AsyncSession) -> dict:
        """Readiness probe — checks database connectivity."""
        try:
            await db_session.execute(text("SELECT 1"))
            return {"status": "ready", "db": "connected"}
        except Exception as e:
            # 503 so orchestrators (k8s/Helm /health/ready) stop routing to a
            # pod that cannot reach the database.
            raise ServiceUnavailableException(
                detail=f"database unavailable: {e}"
            ) from e

    @get(path="/startup", status_code=200, operation_id="StartupCheck")
    async def startup(self) -> dict:
        """Startup probe — confirms the app has initialized."""
        return {"status": "started"}
