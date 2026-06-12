"""Data transfer objects for Task CRUD operations."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class TaskCreateDTO:
    """DTO for creating a task."""
    title: str
    done: bool = False
    assignee: Optional[str] = None
    due_date: Optional[datetime] = None
    priority: Optional[int] = None


@dataclass
class TaskUpdateDTO:
    """DTO for updating a task."""
    title: Optional[str] = None
    done: Optional[bool] = None
    assignee: Optional[str] = None
    due_date: Optional[datetime] = None
    priority: Optional[int] = None


@dataclass
class TaskResponseDTO:
    """DTO for task responses."""
    id: int
    title: str
    done: bool
    created_at: Optional[datetime] = None
    assignee: Optional[str] = None
    due_date: Optional[datetime] = None
    priority: Optional[int] = None
