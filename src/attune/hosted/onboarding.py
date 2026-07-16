"""Versioned, tenant-bound state for resumable hosted onboarding."""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
from uuid import UUID

from .repositories import ConnectionFactory
from .tenant import TenantContext, tenant_transaction


@dataclass(frozen=True)
class HostedOnboardingState:
    schema_version: int
    revision: int
    workspace: str
    channels: str
    policy: str
    activation: str

    @property
    def status(self) -> str:
        steps = (self.workspace, self.channels, self.policy, self.activation)
        if all(step == "validated" for step in steps):
            return "ready"
        if any(step in {"failed", "externally_modified"} for step in steps):
            return "attention_required"
        return "in_progress"


class PostgresHostedOnboardingRepository:
    def __init__(self, connection_factory: ConnectionFactory):
        self._connect = connection_factory

    def read(
        self, context: TenantContext, *, principal_id: UUID
    ) -> HostedOnboardingState | None:
        _principal(principal_id)
        with closing(self._connect()) as connection:
            with tenant_transaction(connection, context) as cursor:
                cursor.execute(
                    """
                    SELECT schema_version, revision, workspace_status,
                           channels_status, policy_status, activation_status
                      FROM attune.hosted_onboarding_states
                     WHERE tenant_id = %s AND owner_principal_id = %s
                    """,
                    (context.tenant_id, principal_id),
                )
                row = cursor.fetchone()
                return _state(row)

    def start(
        self, context: TenantContext, *, principal_id: UUID
    ) -> HostedOnboardingState:
        _principal(principal_id)
        with closing(self._connect()) as connection:
            with tenant_transaction(connection, context) as cursor:
                cursor.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                    (f"{context.tenant_id}:hosted-onboarding",),
                )
                cursor.execute(
                    """
                    SELECT EXISTS (
                        SELECT 1 FROM attune.principals
                         WHERE tenant_id = %s AND id = %s AND status = 'active'
                    )
                    """,
                    (
                        context.tenant_id,
                        principal_id,
                    ),
                )
                principal_active = cursor.fetchone()[0]
                if not principal_active:
                    raise RuntimeError("onboarding principal is unavailable")
                cursor.execute(
                    """
                    INSERT INTO attune.hosted_onboarding_states
                        (tenant_id, owner_principal_id)
                    VALUES (%s, %s)
                    ON CONFLICT (tenant_id) DO NOTHING
                    """,
                    (
                        context.tenant_id,
                        principal_id,
                    ),
                )
                cursor.execute(
                    """
                    SELECT schema_version, revision, workspace_status,
                           channels_status, policy_status, activation_status
                      FROM attune.hosted_onboarding_states
                     WHERE tenant_id = %s AND owner_principal_id = %s
                    """,
                    (context.tenant_id, principal_id),
                )
                state = _state(cursor.fetchone())
                if state is None:
                    raise RuntimeError("hosted onboarding authority is ambiguous")
                return state


def _principal(principal_id: UUID) -> None:
    if not isinstance(principal_id, UUID):
        raise TypeError("principal_id must be a UUID")


def _state(row) -> HostedOnboardingState | None:
    return HostedOnboardingState(*row) if row is not None else None
