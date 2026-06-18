"""add assignee, due_date, priority columns

Revision ID: 002
Revises: 001
Create Date: 2025-01-15
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "002"
down_revision: str | None = "001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("tasks", sa.Column("assignee", sa.String(255), nullable=True))
    op.add_column("tasks", sa.Column("due_date", sa.DateTime(timezone=True), nullable=True))
    op.add_column("tasks", sa.Column("priority", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("tasks", "priority")
    op.drop_column("tasks", "due_date")
    op.drop_column("tasks", "assignee")
