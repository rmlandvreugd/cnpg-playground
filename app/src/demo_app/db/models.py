from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base


class Task(Base):
    """Task tracker model — v1 schema with v2 nullable columns.

    Value constraints (non-empty title, priority 1-5) are enforced at the
    request boundary by ``TaskService`` rather than via ``msgspec.Meta`` on the
    mapped annotations: advanced-alchemy's ``SQLAlchemyDTO`` does not surface
    ``Meta`` from mapped types (verified — it only enforces the column's base
    type), so a guard in the service is the single enforced chokepoint shared by
    both controllers. No DB CHECK constraints are added (no schema change).
    """
    __tablename__ = "tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    done: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    # v2 columns (nullable for backward compatibility)
    assignee: Mapped[str | None] = mapped_column(String(255), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    priority: Mapped[int | None] = mapped_column(Integer, nullable=True)

    def __repr__(self) -> str:
        return f"<Task id={self.id} title='{self.title}' done={self.done}>"
