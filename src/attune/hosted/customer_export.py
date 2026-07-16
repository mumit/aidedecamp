"""Fixed-scope database boundary for dormant hosted customer exports."""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
from datetime import datetime
from typing import Literal
from uuid import UUID

from .repositories import ConnectionFactory, _fixed_hash
from .tenant import TenantContext, tenant_transaction

ExportScope = Literal["account", "conversations", "memories", "activity"]
EXPORT_SCOPES = frozenset({"account", "conversations", "memories", "activity"})


@dataclass(frozen=True)
class CustomerExportRequest:
    id: UUID
    scope: ExportScope
    state: str
    created_at: datetime


class PostgresCustomerExportRequests:
    """Create only canonical, recent-session-bound export requests."""

    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def request(
        self,
        context: TenantContext,
        *,
        principal_id: UUID,
        session_id: UUID,
        scope: ExportScope,
        idempotency_key: bytes,
    ) -> CustomerExportRequest:
        if not isinstance(principal_id, UUID) or not isinstance(session_id, UUID):
            raise TypeError("principal_id and session_id must be UUIDs")
        if scope not in EXPORT_SCOPES:
            raise ValueError("unsupported customer export scope")
        _fixed_hash("idempotency_key", idempotency_key)
        with closing(self._connect()) as connection:
            with tenant_transaction(connection, context) as cursor:
                cursor.execute(
                    "SELECT * FROM attune.request_customer_export(%s,%s,%s,%s)",
                    (principal_id, session_id, scope, idempotency_key),
                )
                row = cursor.fetchone()
                if row is None:
                    raise RuntimeError("customer export request was not created")
                return CustomerExportRequest(*row)


@dataclass(frozen=True)
class ClaimedCustomerExport:
    tenant_id: UUID
    id: UUID
    requested_by: UUID
    scope: ExportScope
    lease_expires_at: datetime


class PostgresCustomerExportClaims:
    """Claim one opaque queued export through the dedicated executor role."""

    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def claim(self, export_id: UUID, *, run_id: UUID) -> ClaimedCustomerExport | None:
        if not isinstance(export_id, UUID) or not isinstance(run_id, UUID):
            raise TypeError("export_id and run_id must be UUIDs")
        with closing(self._connect()) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT * FROM attune.claim_customer_export(%s,%s)",
                    (export_id, run_id),
                )
                row = cursor.fetchone()
            connection.commit()
        return ClaimedCustomerExport(*row) if row is not None else None
