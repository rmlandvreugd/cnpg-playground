from litestar import Controller, delete, get, post, put
from litestar.dto import DTOData
from litestar.exceptions import NotFoundException
from litestar.status_codes import HTTP_200_OK, HTTP_201_CREATED, HTTP_204_NO_CONTENT
from sqlalchemy.ext.asyncio import AsyncSession

from demo_app.db.models import Task
from demo_app.domain.tasks.dto import TaskReadDTO, TaskUpdateDTO, TaskWriteDTO
from demo_app.domain.tasks.service import TaskService


class TaskController(Controller):
    path = "/api/v1/tasks"
    # All JSON responses are serialized through the read DTO.
    return_dto = TaskReadDTO
    signature_types = [Task]

    @get(status_code=HTTP_200_OK, operation_id="ListTasks")
    async def list_tasks(
        self,
        db_session: AsyncSession,
        done: bool | None = None,
    ) -> list[Task]:
        """List all tasks, optionally filtered by done status."""
        return await TaskService(db_session).list_tasks(done)

    @get(path="/{task_id:int}", status_code=HTTP_200_OK, operation_id="GetTask")
    async def get_task(self, db_session: AsyncSession, task_id: int) -> Task:
        """Get a single task by ID."""
        task = await TaskService(db_session).get_task(task_id)
        if task is None:
            raise NotFoundException(detail=f"Task {task_id} not found")
        return task

    @post(status_code=HTTP_201_CREATED, operation_id="CreateTask", dto=TaskWriteDTO)
    async def create_task(self, db_session: AsyncSession, data: Task) -> Task:
        """Create a new task.

        The write DTO decodes + type-validates the body and excludes
        server-managed fields (``id``, ``created_at``); the service enforces
        value constraints. No raw-dict handling, no mass-assignment.
        """
        return await TaskService(db_session).create(data)

    @put(
        path="/{task_id:int}",
        status_code=HTTP_200_OK,
        operation_id="UpdateTask",
        dto=TaskUpdateDTO,
    )
    async def update_task(
        self, db_session: AsyncSession, task_id: int, data: DTOData[Task]
    ) -> Task:
        """Partially update an existing task.

        ``TaskUpdateDTO`` is partial, so ``data`` carries only the submitted
        fields and is applied via ``update_instance``.
        """
        task = await TaskService(db_session).update(task_id, data)
        if task is None:
            raise NotFoundException(detail=f"Task {task_id} not found")
        return task

    @delete(
        path="/{task_id:int}",
        status_code=HTTP_204_NO_CONTENT,
        operation_id="DeleteTask",
    )
    async def delete_task(self, db_session: AsyncSession, task_id: int) -> None:
        """Delete a task."""
        deleted = await TaskService(db_session).delete_task(task_id)
        if not deleted:
            raise NotFoundException(detail=f"Task {task_id} not found")
