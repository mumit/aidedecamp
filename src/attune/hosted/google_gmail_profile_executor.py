"""Deterministic worker executor for the fixed Gmail profile operation."""

from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone
from typing import Callable, Protocol
from uuid import UUID

from .repositories import HostedJob
from .secret_broker_client import GmailProfile, SecretBrokerClient
from .tenant import TenantContext
from .vault import CredentialIntent, PostgresCredentialIntentRepository

CAPABILITY = "google.gmail.profile.read"


class IntentRepository(Protocol):
    def request(
        self,
        context: TenantContext,
        *,
        connector_id: UUID,
        operation: str,
        capability: str,
        idempotency_key: bytes,
        expires_at: datetime,
    ) -> CredentialIntent: ...


class GmailProfileBroker(Protocol):
    def google_gmail_profile(self, intent_id: UUID) -> GmailProfile: ...


class GoogleGmailProfileExecutor:
    def __init__(
        self,
        intents: PostgresCredentialIntentRepository | IntentRepository,
        broker: SecretBrokerClient | GmailProfileBroker,
        *,
        now: Callable[[], datetime] | None = None,
    ):
        self._intents = intents
        self._broker = broker
        self._now = now or (lambda: datetime.now(timezone.utc))

    def __call__(self, context: TenantContext, job: HostedJob) -> None:
        if not isinstance(context, TenantContext):
            raise TypeError("verified tenant context is required")
        if job.kind != CAPABILITY or job.capability != CAPABILITY:
            raise ValueError("Gmail profile job does not match the fixed route")
        if not isinstance(job.payload, dict) or set(job.payload) != {"connector_id"}:
            raise ValueError("Gmail profile payload does not match the contract")
        raw_connector = job.payload["connector_id"]
        if not isinstance(raw_connector, str):
            raise ValueError("connector_id must be a canonical UUID")
        try:
            connector_id = UUID(raw_connector)
        except ValueError as error:
            raise ValueError("connector_id must be a canonical UUID") from error
        if str(connector_id) != raw_connector:
            raise ValueError("connector_id must be a canonical UUID")

        now = self._now()
        if now.tzinfo is None:
            raise RuntimeError("worker clock must be timezone-aware")
        key = hashlib.sha256(
            (
                f"attune-google-gmail-profile-v1:{context.tenant_id}:"
                f"{job.id}:{connector_id}"
            ).encode()
        ).digest()
        intent = self._intents.request(
            context,
            connector_id=connector_id,
            operation="use",
            capability=CAPABILITY,
            idempotency_key=key,
            expires_at=now + timedelta(minutes=2),
        )
        if intent.state == "consumed":
            return
        if intent.state != "requested":
            raise RuntimeError("credential intent is not available")
        self._broker.google_gmail_profile(intent.id)
