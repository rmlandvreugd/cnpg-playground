"""Task repository for database operations."""
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from demo_app.db.models import Task


class TaskRepository:
    """Repository for Task CRUD operations."""

    def __init__(self, session: AsyncSession):
        self.session = session

    async def get_by_id(self, task_id: int) -> Task | None:
        return await self.session.get(Task, task_id)

    async def list_all(self, done: bool | None = None) -> list[Task]:
        stmt = select(Task).order_by(Task.id)
        if done is not None:
            stmt = stmt.where(Task.done == done)
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def create(self, task: Task) -> Task:
        self.session.add(task)
        await self.session.flush()
        return task

    async def update(self, task: Task) -> Task:
        await self.session.flush()
        return task

    async def delete(self, task: Task) -> None:
        await self.session.delete(task)
