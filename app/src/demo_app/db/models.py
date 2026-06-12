from datetime import datetime
from sqlalchemy import String, Boolean, Integer, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base


class Task(Base):
    """Task tracker model — v1 schema with v2 nullable columns."""
    __tablename__ = "tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(255), nullable=False)
    done: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )

    # v2 columns (nullable for backward compatibility)
    assignee: Mapped[str | None] = mapped_column(String(255), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    priority: Mapped[int | None] = mapped_column(Integer, nullable=True)

    def __repr__(self) -> str:
        return f"<Task id={self.id} title='{self.title}' done={self.done}>"
