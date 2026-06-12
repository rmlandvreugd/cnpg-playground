"""Database seeding script.

Run with: python -m demo_app.seed

Inserts ~20 sample tasks with varied states.
"""
import asyncio
import os
import sys

# Ensure src is on the path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker

from demo_app.config import AppSettings
from demo_app.db.models import Task


async def seed() -> None:
    """Seed the database with sample tasks."""
    settings = AppSettings()
    engine = create_async_engine(settings.database_url, echo=True)
    async_session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async with async_session() as session:
        # Check if data already exists
        result = await session.execute(text("SELECT COUNT(*) FROM tasks"))
        count = result.scalar()
        if count > 0:
            print(f"Tasks table already has {count} rows, skipping seed.")
            return

        tasks = [
            Task(title="Set up CI/CD pipeline", done=True, priority=1),
            Task(title="Write API documentation", done=False, priority=2, assignee="alice"),
            Task(title="Fix login page CSS bug", done=False, priority=1, assignee="bob"),
            Task(title="Add unit tests for auth module", done=False, priority=2),
            Task(title="Deploy staging environment", done=True, priority=3, assignee="charlie"),
            Task(title="Review PR #42", done=False, priority=1, assignee="alice"),
            Task(title="Update dependencies", done=False, priority=3),
            Task(title="Implement password reset flow", done=False, priority=1, assignee="bob"),
            Task(title="Set up monitoring alerts", done=True, priority=2, assignee="charlie"),
            Task(title="Refactor database queries", done=False, priority=3, assignee="alice"),
            Task(title="Add rate limiting middleware", done=False, priority=2),
            Task(title="Write integration tests", done=False, priority=2, assignee="bob"),
            Task(title="Optimize image loading", done=True, priority=3),
            Task(title="Fix memory leak in worker", done=False, priority=1, assignee="charlie"),
            Task(title="Update README with setup instructions", done=True, priority=3, assignee="alice"),
            Task(title="Add CORS configuration", done=False, priority=2),
            Task(title="Implement search functionality", done=False, priority=1, assignee="bob"),
            Task(title="Set up database backups", done=True, priority=2, assignee="charlie"),
            Task(title="Add user profile page", done=False, priority=3, assignee="alice"),
            Task(title="Configure auto-scaling policies", done=False, priority=2, assignee="charlie"),
        ]

        session.add_all(tasks)
        await session.commit()
        print(f"Seeded {len(tasks)} tasks successfully.")

    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(seed())
