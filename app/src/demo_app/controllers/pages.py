"""HTML page controller (server-rendered forms).

Like the JSON API in ``controllers/tasks.py``, every read and write is routed
through :class:`~demo_app.domain.tasks.service.TaskService` — the single
validation chokepoint. Browsers submit ``application/x-www-form-urlencoded``
bodies where blank optional fields arrive as empty strings (e.g. ``priority=''``,
``assignee=''``) and an empty ``<select>`` always sends ``''``; a strict
model-DTO decode 500s on ``""``\\ ->\\ ``int`` and cannot express "clear this
field". So the form is normalized explicitly here, then handed to the same
service ``create`` / ``update_fields`` path used by the API.
"""
from typing import Annotated

from litestar import Controller, Request, get, post
from litestar.enums import RequestEncodingType
from litestar.exceptions import NotFoundException
from litestar.params import Body
from litestar.response import Redirect, Template
from sqlalchemy.ext.asyncio import AsyncSession

from demo_app.db.models import Task
from demo_app.domain.tasks.service import TaskService


def _normalize_task_form(data: dict) -> dict:
    """Coerce a URL-encoded task form into typed field values.

    Blank optional fields (empty strings) become ``None``; ``done`` is decoded
    from the ``"true"``/``"false"`` select (fixing the old truthiness bug where
    the string ``"false"`` was stored as truthy).
    """
    title = (data.get("title") or "").strip()
    assignee = (data.get("assignee") or "").strip() or None
    priority_raw = (data.get("priority") or "").strip()
    return {
        "title": title,
        "done": data.get("done") == "true",
        "assignee": assignee,
        "priority": int(priority_raw) if priority_raw else None,
    }


class PageController(Controller):
    path = "/"

    @get(status_code=200, operation_id="IndexPage")
    async def index(self, request: Request, db_session: AsyncSession) -> Template:
        """Landing page showing app version and DB status."""
        db_ok = False
        try:
            from sqlalchemy import text

            await db_session.execute(text("SELECT 1"))
            db_ok = True
        except Exception:
            db_ok = False

        # Single-source the version from settings (stashed in app.state at
        # startup) instead of a hard-coded literal that drifts on bumps.
        version = request.app.state.get("version", "unknown")
        return Template(
            template_name="index.html",
            context={"db_ok": db_ok, "version": version},
        )

    @get(path="/tasks", status_code=200, operation_id="TasksPage")
    async def tasks_list(self, db_session: AsyncSession) -> Template:
        """Task list page with CRUD operations."""
        tasks = await TaskService(db_session).list_tasks()
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
        task = await TaskService(db_session).get_task(task_id)
        if task is None:
            raise NotFoundException(detail=f"Task {task_id} not found")
        return Template(
            template_name="tasks/detail.html",
            context={"task": task},
        )

    @get(path="/tasks/{task_id:int}/edit", status_code=200, operation_id="EditTaskPage")
    async def edit_task(self, db_session: AsyncSession, task_id: int) -> Template:
        """Edit task form."""
        task = await TaskService(db_session).get_task(task_id)
        if task is None:
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
        """Handle task creation form submission (validated via the service)."""
        fields = _normalize_task_form(data)
        await TaskService(db_session).create(Task(**fields))
        return Redirect(path="/tasks")

    @post(
        path="/tasks/{task_id:int}/update",
        status_code=303,
        operation_id="UpdateTaskPage",
    )
    async def update_task_page(
        self,
        db_session: AsyncSession,
        task_id: int,
        data: Annotated[dict, Body(media_type=RequestEncodingType.URL_ENCODED)],
    ) -> Redirect:
        """Handle task update form submission (validated via the service)."""
        fields = _normalize_task_form(data)
        task = await TaskService(db_session).update_fields(task_id, **fields)
        if task is None:
            raise NotFoundException(detail=f"Task {task_id} not found")
        return Redirect(path=f"/tasks/{task_id}")

    @post(
        path="/tasks/{task_id:int}/delete",
        status_code=303,
        operation_id="DeleteTaskPage",
    )
    async def delete_task_page(
        self, db_session: AsyncSession, task_id: int
    ) -> Redirect:
        """Handle task deletion form submission."""
        await TaskService(db_session).delete_task(task_id)
        return Redirect(path="/tasks")
