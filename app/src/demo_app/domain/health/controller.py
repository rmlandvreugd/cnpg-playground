"""Health check controller (domain layer)."""
from litestar import Controller, get
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


class HealthDomainController(Controller):
    """Health check endpoints at the domain layer."""
    path = "/api/v1/health"

    @get(path="/", status_code=200)
    async def health(self) -> dict:
        return {"status": "healthy"}

    @get(path="/ready", status_code=200)
    async def ready(self, db_session: AsyncSession) -> dict:
        try:
            await db_session.execute(text("SELECT 1"))
            return {"status": "ready", "db": "connected"}
        except Exception as e:
            return {"status": "degraded", "db": f"error: {str(e)}"}
