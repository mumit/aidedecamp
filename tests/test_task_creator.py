from __future__ import annotations

from datetime import datetime, timezone
from types import SimpleNamespace
from uuid import UUID

import pytest

from attune.hosted.dispatch import LeasedDispatch
from attune.hosted.dispatch_broker import BrokerRoute, TaskAlreadyExists
from attune.hosted.task_creator import GoogleCloudTaskCreator
from attune.hosted.tenant import TenantContext

QUEUE = "projects/test/locations/test/queues/jobs"
ORIGIN = "https://worker.example.run.app"
TARGET = f"{ORIGIN}/v1/tasks/dispatch"
DELIVERY_SA = "dispatch@example.iam.gserviceaccount.com"


class AlreadyExists(Exception):
    pass


class Client:
    def __init__(self, *, error=None, returned_name=None):
        self.error = error
        self.returned_name = returned_name
        self.requests = []

    def create_task(self, request):
        self.requests.append(request)
        if self.error:
            raise self.error
        return SimpleNamespace(
            name=self.returned_name or request["task"]["name"]
        )


def dispatch():
    return LeasedDispatch(
        UUID("10000000-0000-4000-8000-000000000601"),
        TenantContext(UUID("10000000-0000-4000-8000-000000000602")),
        UUID("10000000-0000-4000-8000-000000000603"),
        UUID("10000000-0000-4000-8000-000000000604"),
        "gmail.reconcile",
        "gmail.read",
        "leased",
        1,
        datetime.now(timezone.utc),
    )


def creator(client):
    return GoogleCloudTaskCreator(
        DELIVERY_SA,
        client=client,
        already_exists_error=AlreadyExists,
    )


def test_task_creator_uses_fixed_route_identity_and_deterministic_name():
    client = Client()
    leased = dispatch()
    body = b'{"version":1}'
    creator(client).create(
        BrokerRoute("gmail.reconcile", QUEUE, TARGET, ORIGIN),
        leased,
        body,
    )
    task = client.requests[0]["task"]
    assert client.requests[0]["parent"] == QUEUE
    assert task["name"] == f"{QUEUE}/tasks/{leased.task_id}"
    assert task["http_request"] == {
        "http_method": "POST",
        "url": TARGET,
        "headers": {"Content-Type": "application/json"},
        "body": body,
        "oidc_token": {
            "service_account_email": DELIVERY_SA,
            "audience": ORIGIN,
        },
    }


def test_task_creator_normalizes_only_already_exists():
    route = BrokerRoute("gmail.reconcile", QUEUE, TARGET, ORIGIN)
    with pytest.raises(TaskAlreadyExists):
        creator(Client(error=AlreadyExists())).create(route, dispatch(), b"{}")
    with pytest.raises(RuntimeError):
        creator(Client(returned_name=f"{QUEUE}/tasks/other")).create(
            route, dispatch(), b"{}"
        )


@pytest.mark.parametrize(
    ("target", "audience"),
    [
        ("http://worker.example/run", "http://worker.example"),
        ("https://user@worker.example/run", "https://worker.example"),
        ("https://worker.example/run?next=other", "https://worker.example"),
        ("https://worker.example/run", "https://worker.example/audience"),
    ],
)
def test_route_rejects_unsafe_or_cross_origin_targets(target, audience):
    with pytest.raises(ValueError):
        BrokerRoute("gmail.reconcile", QUEUE, target, audience)
