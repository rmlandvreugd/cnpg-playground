"""Seed the database with sample tasks.

Run with:  uv run python -m demo_app.seed

Idempotent: if the tasks table already has rows, seeding is skipped. Uses the
async engine built from app settings (honours DEMO_APP_DATABASE_URL), so it
works through PgBouncer or a direct Postgres connection.
"""

import asyncio

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from demo_app.config import AppSettings
from demo_app.db.models import Task
from demo_app.db.session import pin_search_path

SAMPLE_TASKS = [
    {"title": "Set up CI/CD pipeline", "done": True, "priority": 1},
    {"title": "Write API documentation", "done": False, "priority": 2, "assignee": "alice"},
    {"title": "Fix login page CSS bug", "done": False, "priority": 1, "assignee": "bob"},
    {"title": "Add unit tests for auth module", "done": False, "priority": 2},
    {"title": "Deploy staging environment", "done": True, "priority": 3, "assignee": "charlie"},
    {"title": "Review PR #42", "done": False, "priority": 1, "assignee": "alice"},
    {"title": "Update dependencies", "done": False, "priority": 3},
    {"title": "Implement password reset flow", "done": False, "priority": 1, "assignee": "bob"},
    {"title": "Set up monitoring alerts", "done": True, "priority": 2, "assignee": "charlie"},
    {"title": "Refactor database queries", "done": False, "priority": 3, "assignee": "alice"},
    {"title": "Add rate limiting middleware", "done": False, "priority": 2},
    {"title": "Write integration tests", "done": False, "priority": 2, "assignee": "bob"},
    {"title": "Optimize image loading", "done": True, "priority": 3},
    {"title": "Fix memory leak in worker", "done": False, "priority": 1, "assignee": "charlie"},
    {"title": "Update README with setup instructions", "done": True, "priority": 3, "assignee": "alice"},
    {"title": "Add CORS configuration", "done": False, "priority": 2},
    {"title": "Implement search functionality", "done": False, "priority": 1, "assignee": "bob"},
    {"title": "Set up database backups", "done": True, "priority": 2, "assignee": "charlie"},
    {"title": "Add user profile page", "done": False, "priority": 3, "assignee": "alice"},
    {"title": "Configure auto-scaling policies", "done": False, "priority": 2, "assignee": "charlie"},
]


async def seed() -> None:
    settings = AppSettings()
    engine = create_async_engine(settings.database_url_async)
    # Select the configured schema per connection (PgBouncer-safe); without
    # this the seeder writes to the default search_path, not db_schema.
    pin_search_path(engine, settings.db_schema)
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
