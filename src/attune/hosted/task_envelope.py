"""Verification boundary for minimal Cloud Tasks job envelopes."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any, Callable, Collection, Mapping
from uuid import UUID

from .tenant import TenantContext

TokenVerifier = Callable[[str, str], Mapping[str, Any]]


@dataclass(frozen=True)
class VerifiedJobEnvelope:
    """Identifiers authenticated as coming from the task-dispatch identity."""

    tenant: TenantContext
    job_id: UUID
    delivery_id: UUID
    purpose: str
    caller_subject: str


def verify_task_envelope(
    *,
    authorization: str,
    raw_body: bytes,
    expected_audience: str,
    expected_service_account: str,
    allowed_purposes: Collection[str],
    token_verifier: TokenVerifier | None = None,
    now: int | None = None,
) -> VerifiedJobEnvelope:
    """Authenticate OIDC caller identity, then strictly parse the tiny body.

    Provider content and executable arguments are intentionally forbidden. The
    worker uses these verified identifiers to fetch and reauthorize canonical
    job state from PostgreSQL; a duplicate delivery loses the atomic claim.
    """

    if not expected_audience.startswith("https://"):
        raise ValueError("expected_audience must be an exact HTTPS URL")
    if not expected_service_account.endswith(".gserviceaccount.com"):
        raise ValueError("expected_service_account must be a service account email")
    if len(authorization) > 16_384 or not authorization.startswith("Bearer "):
        raise PermissionError("a bearer OIDC token is required")
    token = authorization[7:]
    if not token or any(character.isspace() for character in token):
        raise PermissionError("malformed bearer OIDC token")
    verifier = token_verifier or _google_token_verifier
    claims = verifier(token, expected_audience)
    _verify_claims(
        claims,
        expected_audience=expected_audience,
        expected_service_account=expected_service_account,
        now=int(time.time()) if now is None else now,
    )

    if not 1 <= len(raw_body) <= 4096:
        raise ValueError("task envelope body must be between 1 and 4096 bytes")
    try:
        body = json.loads(raw_body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("task envelope must be valid UTF-8 JSON") from exc
    expected_keys = {"version", "tenant_id", "job_id", "delivery_id", "purpose"}
    if not isinstance(body, dict) or set(body) != expected_keys:
        raise ValueError("task envelope fields do not match the versioned contract")
    if body["version"] != 1:
        raise ValueError("unsupported task envelope version")
    purpose = body["purpose"]
    if not isinstance(purpose, str) or purpose not in allowed_purposes:
        raise PermissionError("task purpose is not allowed by this worker")
    try:
        tenant = TenantContext.parse(body["tenant_id"])
        job_id = UUID(body["job_id"])
        delivery_id = UUID(body["delivery_id"])
    except (TypeError, ValueError, AttributeError) as exc:
        raise ValueError("task identifiers must be canonical UUIDs") from exc
    for field, parsed in (
        ("tenant_id", tenant.tenant_id),
        ("job_id", job_id),
        ("delivery_id", delivery_id),
    ):
        if body[field] != str(parsed):
            raise ValueError(f"{field} must use canonical UUID text")
    return VerifiedJobEnvelope(
        tenant=tenant,
        job_id=job_id,
        delivery_id=delivery_id,
        purpose=purpose,
        caller_subject=str(claims["sub"]),
    )


def _verify_claims(
    claims: Mapping[str, Any],
    *,
    expected_audience: str,
    expected_service_account: str,
    now: int,
) -> None:
    if claims.get("iss") not in {"https://accounts.google.com", "accounts.google.com"}:
        raise PermissionError("unexpected OIDC issuer")
    if claims.get("aud") != expected_audience:
        raise PermissionError("unexpected OIDC audience")
    if claims.get("email") != expected_service_account:
        raise PermissionError("unexpected task-dispatch identity")
    if claims.get("email_verified") is not True:
        raise PermissionError("task-dispatch email is not verified")
    subject = claims.get("sub")
    issued_at = claims.get("iat")
    expires_at = claims.get("exp")
    if not isinstance(subject, str) or not subject:
        raise PermissionError("OIDC subject is missing")
    if not isinstance(issued_at, int) or not isinstance(expires_at, int):
        raise PermissionError("OIDC lifetime claims are missing")
    if issued_at > now + 30 or expires_at <= now or expires_at - issued_at > 3600:
        raise PermissionError("OIDC token lifetime is invalid")


def _google_token_verifier(token: str, audience: str) -> Mapping[str, Any]:
    from google.auth.transport.requests import Request
    from google.oauth2 import id_token

    return id_token.verify_oauth2_token(token, Request(), audience=audience)
