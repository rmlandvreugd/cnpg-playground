"""Seed the database with sample tasks.

Run with:  uv run python -m demo_app.seed

Idempotent: if the tasks table already has rows, seeding is skipped. Uses the
async engine built from app settings (honours DEMO_APP_DATABASE_URL), so it
works through PgBouncer or a direct Postgres connection.
"""

import asyncio
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from demo_app.config import AppSettings
from demo_app.db.models import Task

SAMPLE_TASKS = [
    {"title": "Set up local dev environment", "done": True, "priority": 1},
    {"title": "Wire up Alembic migrations", "done": True, "priority": 1},
    {"title": "Write the seed script", "done": False, "assignee": "alice", "priority": 2},
    {
        "title": "Add task list UI",
        "done": False,
        "assignee": "bob",
        "priority": 3,
        "due_date": datetime.now(timezone.utc) + timedelta(days=7),
    },
    {"title": "Configure observability", "done": False, "priority": 4},
]


async def seed() -> None:
    settings = AppSettings()
    engine = create_async_engine(settings.database_url_async)
    session_factory = async_sessionmaker(engine, expire_on_commit=False)

    try:
        async with session_factory() as session:
            existing = await session.scalar(select(func.count()).select_from(Task))
            if existing:
                print(f"Tasks table already has {existing} row(s); skipping seed.")
                return

            session.add_all([Task(**row) for row in SAMPLE_TASKS])
            await session.commit()
            print(f"Seeded {len(SAMPLE_TASKS)} sample task(s).")
    finally:
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(seed())
