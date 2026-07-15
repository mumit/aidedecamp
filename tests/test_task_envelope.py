from __future__ import annotations

import json
from uuid import UUID

import pytest

from attune.hosted.task_envelope import verify_task_envelope

AUDIENCE = "https://worker.example.test/tasks"
SERVICE_ACCOUNT = "attune-dispatch@example.iam.gserviceaccount.com"
TENANT = "10000000-0000-4000-8000-000000000001"
JOB = "10000000-0000-4000-8000-000000000002"
DELIVERY = "10000000-0000-4000-8000-000000000003"
NOW = 1_800_000_000


def _claims(**overrides):
    claims = {
        "iss": "https://accounts.google.com",
        "aud": AUDIENCE,
        "email": SERVICE_ACCOUNT,
        "email_verified": True,
        "sub": "123456789",
        "iat": NOW - 10,
        "exp": NOW + 290,
    }
    claims.update(overrides)
    return claims


def _body(**overrides) -> bytes:
    body = {
        "version": 1,
        "tenant_id": TENANT,
        "job_id": JOB,
        "delivery_id": DELIVERY,
        "purpose": "workspace.reconcile",
    }
    body.update(overrides)
    return json.dumps(body).encode()


def _verify(claims=None, body=None, authorization="Bearer signed-token"):
    return verify_task_envelope(
        authorization=authorization,
        raw_body=_body() if body is None else body,
        expected_audience=AUDIENCE,
        expected_service_account=SERVICE_ACCOUNT,
        allowed_purposes={"workspace.reconcile"},
        token_verifier=lambda token, audience: _claims()
        if claims is None
        else claims,
        now=NOW,
    )


def test_verified_task_envelope_contains_identifiers_only():
    envelope = _verify()
    assert envelope.tenant.tenant_id == UUID(TENANT)
    assert envelope.job_id == UUID(JOB)
    assert envelope.delivery_id == UUID(DELIVERY)
    assert envelope.purpose == "workspace.reconcile"
    assert envelope.caller_subject == "123456789"


@pytest.mark.parametrize(
    "claims",
    [
        _claims(iss="attacker"),
        _claims(aud="https://other.example.test"),
        _claims(email="attacker@example.com"),
        _claims(email_verified=False),
        _claims(iat=NOW + 31),
        _claims(exp=NOW),
        _claims(exp=NOW + 3700),
    ],
)
def test_oidc_claim_mismatch_is_denied(claims):
    with pytest.raises(PermissionError):
        _verify(claims=claims)


def test_token_is_never_accepted_from_body_or_query_style_text():
    with pytest.raises(PermissionError):
        _verify(authorization="signed-token")
    with pytest.raises(PermissionError):
        _verify(authorization="Bearer signed token")


@pytest.mark.parametrize(
    "body",
    [
        _body(extra="provider content"),
        _body(version=2),
        _body(purpose="database.migrate"),
        _body(tenant_id="not-a-uuid"),
        _body(job_id="ABCDEF00-0000-4000-8000-000000000002"),
        b"not-json",
        b"",
        b"{}" * 3000,
    ],
)
def test_envelope_schema_and_bounds_fail_closed(body):
    error = PermissionError if b"database.migrate" in body else ValueError
    with pytest.raises(error):
        _verify(body=body)
