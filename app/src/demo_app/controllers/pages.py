from typing import Annotated

from litestar import Controller, get, post
from litestar.enums import RequestEncodingType
from litestar.params import Body
from litestar.response import Template, Redirect
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from demo_app.db.models import Task


class PageController(Controller):
    path = "/"

    @get(status_code=200, operation_id="IndexPage")
    async def index(self, db_session: AsyncSession) -> Template:
        """Landing page showing app version and DB status."""
        db_ok = False
        try:
            from sqlalchemy import text

            await db_session.execute(text("SELECT 1"))
            db_ok = True
        except Exception:
            db_ok = False

        return Template(
            template_name="index.html",
            context={"db_ok": db_ok, "version": "0.1.0"},
        )

    @get(path="/tasks", status_code=200, operation_id="TasksPage")
    async def tasks_list(self, db_session: AsyncSession) -> Template:
        """Task list page with CRUD operations."""
        result = await db_session.execute(select(Task).order_by(Task.id))
        tasks = result.scalars().all()
        return Template(
            template_name="tasks/list.html",
            context={"tasks": tasks},
        )

    @get(path="/tasks/new", status_code=200, operation_id="NewTaskPage")
    async def new_task(self) -> Template:
        """New task creation form."""
        return Template(
            template_name="tasks/form.html",
            context={"task": None, "action": "/tasks/create"},
        )

    @get(path="/tasks/{task_id:int}", status_code=200, operation_id="TaskDetailPage")
    async def task_detail(self, db_session: AsyncSession, task_id: int) -> Template:
        """Task detail page."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        return Template(
            template_name="tasks/detail.html",
            context={"task": task},
        )

    @get(path="/tasks/{task_id:int}/edit", status_code=200, operation_id="EditTaskPage")
    async def edit_task(self, db_session: AsyncSession, task_id: int) -> Template:
        """Edit task form."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        return Template(
            template_name="tasks/form.html",
            context={"task": task, "action": f"/tasks/{task_id}/update"},
        )

    @post(path="/tasks/create", status_code=303, operation_id="CreateTaskPage")
    async def create_task_page(
        self,
        db_session: AsyncSession,
        data: Annotated[dict, Body(media_type=RequestEncodingType.URL_ENCODED)],
    ) -> Redirect:
        """Handle task creation form submission."""
        priority = data.get("priority")
        task = Task(
            title=data.get("title", ""),
            done=data.get("done") == "true",
            assignee=data.get("assignee") or None,
            priority=int(priority) if priority else None,
        )
        db_session.add(task)
        await db_session.flush()
        return Redirect(path="/tasks")

    @post(path="/tasks/{task_id:int}/update", status_code=303, operation_id="UpdateTaskPage")
    async def update_task_page(
        self,
        db_session: AsyncSession,
        task_id: int,
        data: Annotated[dict, Body(media_type=RequestEncodingType.URL_ENCODED)],
    ) -> Redirect:
        """Handle task update form submission."""
        task = await db_session.get(Task, task_id)
        if task is None:
            from litestar.exceptions import NotFoundException

            raise NotFoundException(detail=f"Task {task_id} not found")
        priority = data.get("priority")
        task.title = data.get("title", task.title)
        task.done = data.get("done") == "true"
        task.assignee = data.get("assignee") or None
        task.priority = int(priority) if priority else None
        await db_session.flush()
        return Redirect(path=f"/tasks/{task_id}")

    @post(path="/tasks/{task_id:int}/delete", status_code=303, operation_id="DeleteTaskPage")
    async def delete_task_page(self, db_session: AsyncSession, task_id: int) -> Redirect:
        """Handle task deletion form submission."""
        task = await db_session.get(Task, task_id)
        if task:
            await db_session.delete(task)
        return Redirect(path="/tasks")
