"""Task business logic service.

Both controllers (JSON API and HTML pages) route writes through this single
service path. It is the one enforced chokepoint for value validation, so the
rules live here rather than on the DTO (advanced-alchemy's SQLAlchemyDTO does
not enforce ``msgspec.Meta`` constraints from mapped annotations).
"""
from litestar.dto import DTOData
from litestar.exceptions import ValidationException
from sqlalchemy.ext.asyncio import AsyncSession

from demo_app.db.models import Task
from demo_app.domain.tasks.repository import TaskRepository


class TaskService:
    """Service layer for task operations."""

    def __init__(self, session: AsyncSession):
        self.repo = TaskRepository(session)

    @staticmethod
    def _validate(task: Task) -> None:
        """Validate value constraints, raising a structured 400 on violation."""
        errors: dict[str, str] = {}
        if not (task.title or "").strip():
            errors["title"] = "Title must not be empty."
        if task.priority is not None and not 1 <= task.priority <= 5:
            errors["priority"] = "Priority must be between 1 and 5."
        if errors:
            raise ValidationException(detail="Invalid task data", extra=errors)

    async def get_task(self, task_id: int) -> Task | None:
        return await self.repo.get_by_id(task_id)

    async def list_tasks(self, done: bool | None = None) -> list[Task]:
        return await self.repo.list_all(done)

    async def create(self, task: Task) -> Task:
        """Persist a fully-formed Task (decoded by a DTO or built from a form)."""
        self._validate(task)
        return await self.repo.create(task)

    async def update(self, task_id: int, data: "DTOData[Task]") -> Task | None:
        """Apply a partial update from a DTOData payload to an existing task."""
        task = await self.repo.get_by_id(task_id)
        if task is None:
            return None
        data.update_instance(task)
        self._validate(task)
        return await self.repo.update(task)

    async def update_fields(self, task_id: int, **fields: object) -> Task | None:
        """Apply a partial update from explicit keyword fields (HTML form path).

        Only keys present in ``fields`` are applied, mirroring the partial
        semantics of :meth:`update` for callers that parse a form themselves
        rather than decoding a DTO.
        """
        task = await self.repo.get_by_id(task_id)
        if task is None:
            return None
        for key, value in fields.items():
            setattr(task, key, value)
        self._validate(task)
        return await self.repo.update(task)

    async def delete_task(self, task_id: int) -> bool:
        task = await self.repo.get_by_id(task_id)
        if task is None:
            return False
        await self.repo.delete(task)
        return True
