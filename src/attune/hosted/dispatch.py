"""Durable producer and broker repositories for hosted task dispatch."""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from uuid import UUID

from .repositories import (
    ConnectionFactory,
    HostedJob,
    _bounded_object,
    _bounded_text,
    _canonical_json,
    _fixed_hash,
    _job,
)
from .tenant import TenantContext, tenant_transaction

PRODUCER_KINDS = frozenset({"control_plane", "ingress", "worker"})


@dataclass(frozen=True)
class HostedDispatchIntent:
    id: UUID
    job_id: UUID
    delivery_id: UUID
    producer_kind: str
    purpose: str
    capability: str
    state: str
    attempts: int
    expires_at: datetime

    @property
    def task_id(self) -> str:
        """Deterministic Cloud Tasks identifier for crash-safe creation."""

        return f"attune-{self.id.hex}"


@dataclass(frozen=True)
class EnqueuedDispatch:
    job: HostedJob
    intent: HostedDispatchIntent


@dataclass(frozen=True)
class LeasedDispatch:
    id: UUID
    tenant: TenantContext
    job_id: UUID
    delivery_id: UUID
    purpose: str
    capability: str
    state: str
    attempts: int
    expires_at: datetime

    @property
    def task_id(self) -> str:
        return f"attune-{self.id.hex}"


class PostgresDispatchProducerRepository:
    """Create a canonical job and dispatch intent in one tenant transaction."""

    def __init__(
        self,
        connection_factory: ConnectionFactory,
        *,
        producer_kind: str,
    ):
        if producer_kind not in {"control_plane", "worker"}:
            raise ValueError("this producer has no direct dispatch-intent role")
        self._connect = connection_factory
        self._producer_kind = producer_kind

    def enqueue(
        self,
        context: TenantContext,
        *,
        kind: str,
        capability: str,
        payload: dict[str, Any],
        idempotency_key: bytes,
        expires_at: datetime,
    ) -> EnqueuedDispatch:
        _bounded_text("kind", kind, 80)
        _bounded_text("capability", capability, 120)
        _bounded_object("payload", payload, 262_144)
        _fixed_hash("idempotency_key", idempotency_key)
        if expires_at.tzinfo is None:
            raise ValueError("expires_at must be timezone-aware")
        if expires_at <= datetime.now(expires_at.tzinfo):
            raise ValueError("expires_at must be in the future")

        with closing(self._connect()) as connection:
            with tenant_transaction(connection, context) as cursor:
                cursor.execute(
                    """
                    INSERT INTO attune.jobs
                        (tenant_id, kind, capability, payload, idempotency_key)
                    VALUES (%s, %s, %s, %s::jsonb, %s)
                    ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
                    RETURNING id, kind, state, capability, payload, attempts,
                              available_at, lease_expires_at
                    """,
                    (
                        context.tenant_id,
                        kind,
                        capability,
                        _canonical_json(payload),
                        idempotency_key,
                    ),
                )
                job_row = cursor.fetchone()
                if job_row is None:
                    cursor.execute(
                        """
                        SELECT id, kind, state, capability, payload, attempts,
                               available_at, lease_expires_at
                          FROM attune.jobs
                         WHERE tenant_id = %s AND idempotency_key = %s
                        """,
                        (context.tenant_id, idempotency_key),
                    )
                    job_row = cursor.fetchone()
                    if job_row is None:
                        raise RuntimeError("idempotent dispatch job disappeared")
                    if (
                        job_row[1] != kind
                        or job_row[3] != capability
                        or job_row[4] != payload
                    ):
                        raise RuntimeError(
                            "idempotency key reused for a different dispatch job"
                        )
                job = _job(job_row)
                if job.state != "queued":
                    raise RuntimeError("existing dispatch job is no longer queued")

                cursor.execute(
                    """
                    INSERT INTO attune.dispatch_intents
                        (tenant_id, job_id, producer_kind, purpose, capability,
                         expires_at)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (tenant_id, job_id) DO NOTHING
                    RETURNING id, job_id, delivery_id, producer_kind, purpose,
                              capability, state, attempts, expires_at
                    """,
                    (
                        context.tenant_id,
                        job.id,
                        self._producer_kind,
                        kind,
                        capability,
                        expires_at,
                    ),
                )
                intent_row = cursor.fetchone()
                if intent_row is None:
                    cursor.execute(
                        """
                        SELECT id, job_id, delivery_id, producer_kind, purpose,
                               capability, state, attempts, expires_at
                          FROM attune.dispatch_intents
                         WHERE tenant_id = %s AND job_id = %s
                        """,
                        (context.tenant_id, job.id),
                    )
                    intent_row = cursor.fetchone()
                    if intent_row is None:
                        raise RuntimeError("idempotent dispatch intent disappeared")
                    if (
                        intent_row[3] != self._producer_kind
                        or intent_row[4] != kind
                        or intent_row[5] != capability
                    ):
                        raise RuntimeError(
                            "job reused for a different dispatch intent"
                        )
                return EnqueuedDispatch(job, _intent(intent_row))


class PostgresDispatchBrokerRepository:
    """Cross-tenant access restricted to intent lease/finalize functions."""

    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def lease(
        self,
        intent_id: UUID,
        *,
        producer_kind: str,
        lease_seconds: int = 30,
    ) -> LeasedDispatch | None:
        _producer_kind(producer_kind)
        if not 1 <= lease_seconds <= 300:
            raise ValueError("lease_seconds must be between 1 and 300")
        with closing(self._connect()) as connection:
            try:
                with closing(connection.cursor()) as cursor:
                    cursor.execute(
                        """
                        SELECT intent_id, tenant_id, job_id, delivery_id, purpose,
                               capability, intent_state, attempts, expires_at
                          FROM attune.lease_dispatch_intent(%s, %s, %s)
                        """,
                        (intent_id, producer_kind, lease_seconds),
                    )
                    row = cursor.fetchone()
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        if row is None:
            return None
        return LeasedDispatch(
            id=row[0],
            tenant=TenantContext(row[1]),
            job_id=row[2],
            delivery_id=row[3],
            purpose=row[4],
            capability=row[5],
            state=row[6],
            attempts=row[7],
            expires_at=row[8],
        )

    def finalize(
        self,
        intent_id: UUID,
        *,
        producer_kind: str,
        outcome: str,
    ) -> bool:
        _producer_kind(producer_kind)
        if outcome not in {"dispatched", "failed", "cancelled"}:
            raise ValueError("invalid dispatch outcome")
        with closing(self._connect()) as connection:
            try:
                with closing(connection.cursor()) as cursor:
                    cursor.execute(
                        "SELECT attune.finalize_dispatch_intent(%s, %s, %s)",
                        (intent_id, producer_kind, outcome),
                    )
                    changed = cursor.fetchone()[0]
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        return changed


def _producer_kind(value: str) -> None:
    if value not in PRODUCER_KINDS:
        raise ValueError("invalid dispatch producer kind")


def _intent(row) -> HostedDispatchIntent:
    return HostedDispatchIntent(*row)
