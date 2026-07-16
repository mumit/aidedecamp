from __future__ import annotations

from uuid import UUID

from attune.hosted.google_connector_revocation import GoogleConnectorRevocation
from attune.hosted.oauth import RequestedGoogleRevocation
from attune.hosted.tenant import TenantContext

TENANT = TenantContext(UUID("10000000-0000-4000-8000-000000000541"))
PRINCIPAL = UUID("10000000-0000-4000-8000-000000000542")
INTENT = UUID("10000000-0000-4000-8000-000000000543")


class Repository:
    def __init__(self, requested):
        self.requested = requested
        self.calls = []

    def request(self, context, **kwargs):
        self.calls.append((context, kwargs))
        return self.requested


class Broker:
    def __init__(self):
        self.calls = []

    def revoke(self, intent_id):
        self.calls.append(intent_id)


def test_disconnect_resolves_authority_then_invokes_only_the_intent():
    repository = Repository(RequestedGoogleRevocation(INTENT))
    broker = Broker()
    GoogleConnectorRevocation(repository, broker).disconnect(
        TENANT, principal_id=PRINCIPAL
    )
    assert repository.calls[0][0] == TENANT
    assert repository.calls[0][1]["principal_id"] == PRINCIPAL
    assert repository.calls[0][1]["expires_at"].tzinfo is not None
    assert broker.calls == [INTENT]


def test_disconnect_is_idempotent_when_no_active_connector_remains():
    repository = Repository(None)
    broker = Broker()
    GoogleConnectorRevocation(repository, broker).disconnect(
        TENANT, principal_id=PRINCIPAL
    )
    assert broker.calls == []
