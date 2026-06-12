"""Task business logic service."""
from datetime import datetime
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession
from demo_app.db.models import Task
from demo_app.domain.tasks.repository import TaskRepository


class TaskService:
    """Service layer for task operations."""

    def __init__(self, session: AsyncSession):
        self.repo = TaskRepository(session)

    async def get_task(self, task_id: int) -> Task | None:
        return await self.repo.get_by_id(task_id)

    async def list_tasks(self, done: bool | None = None) -> list[Task]:
        return await self.repo.list_all(done)

    async def create_task(
        self,
        title: str,
        done: bool = False,
        assignee: Optional[str] = None,
        due_date: Optional[datetime] = None,
        priority: Optional[int] = None,
    ) -> Task:
        task = Task(
            title=title,
            done=done,
            assignee=assignee,
            due_date=due_date,
            priority=priority,
        )
        return await self.repo.create(task)

    async def update_task(
        self,
        task_id: int,
        title: Optional[str] = None,
        done: Optional[bool] = None,
        assignee: Optional[str] = None,
        priority: Optional[int] = None,
    ) -> Task | None:
        task = await self.repo.get_by_id(task_id)
        if task is None:
            return None
        if title is not None:
            task.title = title
        if done is not None:
            task.done = done
        if assignee is not None:
            task.assignee = assignee
        if priority is not None:
            task.priority = priority
        return await self.repo.update(task)

    async def delete_task(self, task_id: int) -> bool:
        task = await self.repo.get_by_id(task_id)
        if task is None:
            return False
        await self.repo.delete(task)
        return True
