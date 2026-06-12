"""add assignee, due_date, priority columns

Revision ID: 002
Revises: 001
Create Date: 2025-01-15
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("tasks", sa.Column("assignee", sa.String(255), nullable=True))
    op.add_column("tasks", sa.Column("due_date", sa.DateTime(timezone=True), nullable=True))
    op.add_column("tasks", sa.Column("priority", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("tasks", "priority")
    op.drop_column("tasks", "due_date")
    op.drop_column("tasks", "assignee")
