from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import pytest

from attune.hosted.google_gmail_profile_executor import (
    CAPABILITY,
    GoogleGmailProfileExecutor,
)
from attune.hosted.repositories import HostedJob
from attune.hosted.secret_broker_client import GmailProfile
from attune.hosted.tenant import TenantContext
from attune.hosted.vault import CredentialIntent

TENANT = TenantContext(UUID("10000000-0000-4000-8000-000000000531"))
JOB = UUID("10000000-0000-4000-8000-000000000532")
CONNECTOR = UUID("aaaaaaaa-0000-4000-8000-000000000533")
INTENT = UUID("10000000-0000-4000-8000-000000000534")
NOW = datetime(2026, 7, 14, 16, 0, tzinfo=timezone.utc)


def job(payload=None, *, kind=CAPABILITY, capability=CAPABILITY):
    return HostedJob(
        JOB,
        kind,
        "leased",
        capability,
        payload or {"connector_id": str(CONNECTOR)},
        1,
        NOW,
        NOW,
    )


class Intents:
    def __init__(self, state="requested"):
        self.state = state
        self.calls = []

    def request(self, context, **kwargs):
        self.calls.append((context, kwargs))
        return CredentialIntent(
            INTENT,
            CONNECTOR,
            "worker",
            "use",
            CAPABILITY,
            self.state,
        )


class Broker:
    def __init__(self):
        self.calls = []

    def google_gmail_profile(self, intent_id):
        self.calls.append(intent_id)
        return GmailProfile("123", 4, 3)


def test_executor_creates_one_fixed_short_lived_intent_and_calls_broker():
    intents = Intents()
    broker = Broker()
    GoogleGmailProfileExecutor(intents, broker, now=lambda: NOW)(TENANT, job())
    assert broker.calls == [INTENT]
    context, request = intents.calls[0]
    assert context == TENANT
    assert request["connector_id"] == CONNECTOR
    assert request["operation"] == "use"
    assert request["capability"] == CAPABILITY
    assert len(request["idempotency_key"]) == 32
    assert (request["expires_at"] - NOW).total_seconds() == 120


def test_executor_treats_consumed_intent_as_idempotent_success():
    intents = Intents("consumed")
    broker = Broker()
    GoogleGmailProfileExecutor(intents, broker, now=lambda: NOW)(TENANT, job())
    assert broker.calls == []


@pytest.mark.parametrize(
    "candidate",
    [
        job({"connector_id": str(CONNECTOR), "url": "https://evil.example"}),
        job({"connector_id": str(CONNECTOR).upper()}),
        job({"connector_id": "not-a-uuid"}),
        job(kind="other"),
        job(capability="google.gmail.modify"),
    ],
)
def test_executor_rejects_authority_outside_fixed_contract(candidate):
    intents = Intents()
    broker = Broker()
    with pytest.raises(ValueError):
        GoogleGmailProfileExecutor(intents, broker, now=lambda: NOW)(
            TENANT,
            candidate,
        )
    assert intents.calls == []
    assert broker.calls == []


def test_executor_rejects_ambiguous_intent_state():
    with pytest.raises(RuntimeError):
        GoogleGmailProfileExecutor(
            Intents("leased"),
            Broker(),
            now=lambda: NOW,
        )(TENANT, job())
