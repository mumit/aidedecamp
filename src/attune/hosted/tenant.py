"""Fail-closed PostgreSQL tenant transaction helpers."""

from __future__ import annotations

from contextlib import closing, contextmanager
from dataclasses import dataclass
from typing import Any, Iterator
from uuid import UUID


@dataclass(frozen=True)
class TenantContext:
    """A tenant identifier already derived by a trusted authentication layer.

    Constructing this value does not authenticate a request. Callers must derive
    it from a verified server-side session, installation, or signed job—not a
    URL, model argument, or unsigned payload.
    """

    tenant_id: UUID

    def __post_init__(self) -> None:
        if not isinstance(self.tenant_id, UUID):
            raise TypeError("tenant_id must be a UUID derived by trusted code")

    @classmethod
    def parse(cls, value: str | UUID) -> "TenantContext":
        return cls(value if isinstance(value, UUID) else UUID(value))


@contextmanager
def tenant_transaction(connection: Any, context: TenantContext) -> Iterator[Any]:
    """Open one transaction with a transaction-local RLS tenant setting.

    The setting is deliberately local to the transaction so pooled connections
    cannot retain one tenant and leak it into the next request. A rollback is
    guaranteed on every exception.
    """

    if not isinstance(context, TenantContext):
        raise TypeError("a verified TenantContext is required")
    try:
        with closing(connection.cursor()) as cursor:
            cursor.execute(
                "SELECT set_config('attune.tenant_id', %s, true)",
                (str(context.tenant_id),),
            )
            yield cursor
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
