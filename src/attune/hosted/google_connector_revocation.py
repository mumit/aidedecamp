"""Principal-bound Google Workspace connector disconnection ceremony."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Protocol


class RevocationRepository(Protocol):
    def request(self, context, *, principal_id, expires_at): ...


class RevocationBroker(Protocol):
    def revoke(self, intent_id) -> None: ...


class GoogleConnectorRevocation:
    def __init__(self, repository: RevocationRepository, broker: RevocationBroker):
        self._repository = repository
        self._broker = broker

    def disconnect(self, context, *, principal_id) -> None:
        requested = self._repository.request(
            context,
            principal_id=principal_id,
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
        )
        if requested is not None:
            self._broker.revoke(requested.credential_intent_id)
