"""Tenant-bound intent-only audit adapter for hosted workers."""

from __future__ import annotations

import hashlib

from .audit import PostgresAuditProducerRepository
from .audit_client import AuditWriterClient
from .tenant import TenantContext


class WorkerAudit:
    def __init__(
        self,
        producer: PostgresAuditProducerRepository,
        writer: AuditWriterClient,
    ):
        self._producer = producer
        self._writer = writer

    def record(
        self,
        context: TenantContext,
        *,
        action: str,
        outcome: str,
        job_id: str,
        caller_subject: str,
    ) -> None:
        audit_intent = self._producer.request(
            context,
            idempotency_key=_digest(
                f"attune-worker-audit-v1:{job_id}:{action}:{outcome}"
            ),
            actor_type="workload",
            actor_ref_hash=_digest(
                f"attune-task-delivery-subject-v1:{caller_subject}"
            ),
            action=action,
            outcome=outcome,
            target_type="job",
            target_ref_hash=_digest(f"attune-job-v1:{job_id}"),
        )
        if not self._writer.write(audit_intent.id):
            raise RuntimeError("worker audit is unavailable")


def _digest(value: str) -> bytes:
    return hashlib.sha256(value.encode()).digest()
