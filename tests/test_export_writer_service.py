"""Tests for the authenticated customer-export task boundary."""

import json
import time
from uuid import UUID

import pytest

from attune.hosted.customer_export_writer import (
    ExportCleanupRequired,
    ExportExecutionFailed,
)
from attune.hosted.export_writer_service import (
    PURPOSE,
    ExportTaskClaim,
    ExportTaskDispatcher,
    create_app,
)

TENANT = UUID("10000000-0000-4000-8000-000000000001")
JOB = UUID("10000000-0000-4000-8000-000000000002")
DELIVERY = UUID("10000000-0000-4000-8000-000000000003")
EXPORT = UUID("10000000-0000-4000-8000-000000000004")
AUDIENCE = "https://attune-export.example.internal"
SERVICE_ACCOUNT = "task-dispatch@example.iam.gserviceaccount.com"


def _body(*, purpose=PURPOSE):
    return json.dumps(
        {
            "version": 1,
            "tenant_id": str(TENANT),
            "job_id": str(JOB),
            "delivery_id": str(DELIVERY),
            "purpose": purpose,
        }
    ).encode()


def _verifier(token, audience):
    now = int(time.time())
    assert token == "valid" and audience == AUDIENCE
    return {
        "iss": "https://accounts.google.com",
        "aud": AUDIENCE,
        "email": SERVICE_ACCOUNT,
        "email_verified": True,
        "sub": "1234567890",
        "iat": now - 5,
        "exp": now + 300,
    }


class Authority:
    def __init__(self, claim=ExportTaskClaim(EXPORT, "claimed"), finish="succeeded"):
        self.value = claim
        self.finish_value = finish
        self.claims = []
        self.finishes = []

    def claim(self, **identifiers):
        self.claims.append(identifiers)
        return self.value

    def finish(self, **identifiers):
        self.finishes.append(identifiers)
        if isinstance(self.finish_value, Exception):
            raise self.finish_value
        return self.finish_value


class Writer:
    def __init__(self, result=object()):
        self.result = result
        self.calls = []

    def execute(self, export_id, **authority):
        self.calls.append((export_id, authority))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def _dispatcher(authority, writer):
    return ExportTaskDispatcher(
        authority=authority,
        writer=writer,
        expected_audience=AUDIENCE,
        expected_service_account=SERVICE_ACCOUNT,
        token_verifier=_verifier,
    )


def test_dispatch_binds_authenticated_task_tenant_and_finishes():
    authority = Authority()
    writer = Writer()
    assert _dispatcher(authority, writer).dispatch(
        authorization="Bearer valid", raw_body=_body()
    ) == 204
    identifiers = {"tenant_id": TENANT, "job_id": JOB, "delivery_id": DELIVERY}
    assert authority.claims == [identifiers]
    assert authority.finishes == [identifiers]
    assert writer.calls[0][0] == EXPORT
    assert writer.calls[0][1]["expected_tenant_id"] == TENANT
    assert isinstance(writer.calls[0][1]["run_id"], UUID)


@pytest.mark.parametrize(
    "authorization,body,status",
    [
        ("invalid", _body(), 403),
        ("Bearer valid", _body(purpose="customer.export.delete"), 403),
        ("Bearer valid", b"{}", 400),
    ],
)
def test_invalid_task_never_reaches_authority(authorization, body, status):
    authority = Authority()
    writer = Writer()
    assert _dispatcher(authority, writer).dispatch(
        authorization=authorization, raw_body=body
    ) == status
    assert authority.claims == [] and writer.calls == []


@pytest.mark.parametrize(
    "state,status", [("busy", 503), ("succeeded", 204), ("failed", 204)]
)
def test_replay_and_active_claim_states_are_effect_free(state, status):
    authority = Authority(ExportTaskClaim(EXPORT, state))
    writer = Writer()
    assert _dispatcher(authority, writer).dispatch(
        authorization="Bearer valid", raw_body=_body()
    ) == status
    assert writer.calls == [] and authority.finishes == []


def test_terminal_writer_failure_finishes_canonical_failed_task():
    authority = Authority(finish="failed")
    writer = Writer(ExportExecutionFailed("archive_failed"))
    assert _dispatcher(authority, writer).dispatch(
        authorization="Bearer valid", raw_body=_body()
    ) == 204
    assert len(authority.finishes) == 1


def test_unverified_cleanup_remains_retryable_and_unfinished():
    authority = Authority()
    writer = Writer(ExportCleanupRequired("cleanup uncertain"))
    assert _dispatcher(authority, writer).dispatch(
        authorization="Bearer valid", raw_body=_body()
    ) == 503
    assert authority.finishes == []


def test_http_adapter_passes_raw_envelope_and_has_health_check():
    class Dispatcher:
        def __init__(self):
            self.calls = []

        def dispatch(self, **request):
            self.calls.append(request)
            return 204

    dispatcher = Dispatcher()
    client = create_app(dispatcher).test_client()
    body = _body()
    assert client.get("/healthz").get_json() == {"status": "ok"}
    response = client.post(
        "/v1/tasks/customer-export",
        data=body,
        headers={"Authorization": "Bearer valid"},
    )
    assert response.status_code == 204
    assert dispatcher.calls == [
        {"authorization": "Bearer valid", "raw_body": body}
    ]
