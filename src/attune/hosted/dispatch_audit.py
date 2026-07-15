"""Intent-only audit adapter for the dispatch broker."""

from __future__ import annotations

from .audit import PostgresDispatchAuditRepository
from .audit_client import AuditWriterClient


class DispatchBrokerAudit:
    def __init__(
        self,
        intents: PostgresDispatchAuditRepository,
        writer: AuditWriterClient,
    ):
        self._intents = intents
        self._writer = writer

    def record(
        self,
        dispatch_intent_id,
        *,
        outcome: str,
        error_code: str | None = None,
    ) -> bool:
        audit_intent_id = self._intents.request(
            dispatch_intent_id,
            outcome=outcome,
            error_code=error_code,
        )
        return (
            audit_intent_id is not None and self._writer.write(audit_intent_id)
        )
