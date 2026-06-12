from litestar import Controller, get, post, put, delete
from litestar.status_codes import HTTP_200_OK, HTTP_201_CREATED, HTTP_204_NO_CONTENT
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from demo_app.db.models import Task


class TaskController(Controller):
    path = "/api/v1/tasks"

    @get(status_code=HTTP_200_OK, operation_id="ListTasks")
    async def list_tasks(
        self,
        db_session: AsyncSession,
        done: bool | None = None,
    ) -> list[dict]:
        """List all tasks, optionally filtered by done status."""
        stmt = select(Task).order_by(Task.id)
        if done is not None:
            stmt = stmt.where(Task.done == done)
        result = await db_session.execute(stmt)
        tasks = result.scalars().all()
        return [
            {
                "id": t.id,
                "title": t.title,
                "done": t.done,
                "created_at": t.created_at.isoformat() if t.created_at else None,
                "assignee": t.assignee,
                "due_date": t.due_date.isoformat() if t.due_date else None,
                "priority": t.priority,
            }
            for t in tasks
        ]

    @get(path="/{task_id:int}", status_code=HTTP_200_OK, operation_id="GetTask")
    async def get_task(self, db_session: AsyncSession, task_id: int) -> dict:
        """Get a single task by ID."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        return {
            "id": task.id,
            "title": task.title,
            "done": task.done,
            "created_at": task.created_at.isoformat() if task.created_at else None,
            "assignee": task.assignee,
            "due_date": task.due_date.isoformat() if task.due_date else None,
            "priority": task.priority,
        }

    @post(status_code=HTTP_201_CREATED, operation_id="CreateTask")
    async def create_task(self, db_session: AsyncSession, data: dict) -> dict:
        """Create a new task."""
        task = Task(
            title=data.get("title", ""),
            done=data.get("done", False),
            assignee=data.get("assignee"),
            due_date=data.get("due_date"),
            priority=data.get("priority"),
        )
        db_session.add(task)
        await db_session.flush()
        return {
            "id": task.id,
            "title": task.title,
            "done": task.done,
            "created_at": task.created_at.isoformat() if task.created_at else None,
            "assignee": task.assignee,
            "due_date": task.due_date.isoformat() if task.due_date else None,
            "priority": task.priority,
        }

    @put(path="/{task_id:int}", status_code=HTTP_200_OK, operation_id="UpdateTask")
    async def update_task(
        self, db_session: AsyncSession, task_id: int, data: dict
    ) -> dict:
        """Update an existing task."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        for key, value in data.items():
            if hasattr(task, key) and key != "id":
                setattr(task, key, value)
        await db_session.flush()
        return {
            "id": task.id,
            "title": task.title,
            "done": task.done,
            "created_at": task.created_at.isoformat() if task.created_at else None,
            "assignee": task.assignee,
            "due_date": task.due_date.isoformat() if task.due_date else None,
            "priority": task.priority,
        }

    @delete(path="/{task_id:int}", status_code=HTTP_204_NO_CONTENT, operation_id="DeleteTask")
    async def delete_task(self, db_session: AsyncSession, task_id: int) -> None:
        """Delete a task."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        await db_session.delete(task)
