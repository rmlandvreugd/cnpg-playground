"""Data transfer objects for Task CRUD operations.

These are model-derived ``SQLAlchemyDTO``s — they put validation, type coercion,
and mass-assignment protection on the request path for both the JSON API
(``controllers/tasks.py``) and the HTML form controller (``controllers/pages.py``).
"""
from advanced_alchemy.extensions.litestar.dto import SQLAlchemyDTO, SQLAlchemyDTOConfig

from demo_app.db.models import Task


class TaskWriteDTO(SQLAlchemyDTO[Task]):
    """Request DTO for creating a task.

    Excludes server-managed fields so they cannot be mass-assigned by the client.
    """

    config = SQLAlchemyDTOConfig(exclude={"id", "created_at"})


class TaskUpdateDTO(SQLAlchemyDTO[Task]):
    """Request DTO for partial updates (PATCH/form edit).

    ``partial=True`` makes the handler receive a ``DTOData[Task]`` carrying only
    the submitted fields; apply with ``data.update_instance(existing_task)``.
    """

    config = SQLAlchemyDTOConfig(exclude={"id", "created_at"}, partial=True)


class TaskReadDTO(SQLAlchemyDTO[Task]):
    """Response DTO — full read model serialized for JSON responses."""

    config = SQLAlchemyDTOConfig()
