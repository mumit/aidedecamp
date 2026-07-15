"""Identity Platform token verification for the hosted sign-in boundary."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping

from .google_oauth import FixedGoogleCertRequest

FIREBASE_CERTS_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/"
    "securetoken@system.gserviceaccount.com"
)
MAX_ID_TOKEN_CHARS = 16_384
MAX_AUTH_AGE = timedelta(minutes=5)
PROJECT_ID = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")


class IdentityRefused(ValueError):
    """A public sign-in credential failed a deterministic identity check."""


@dataclass(frozen=True, repr=False)
class VerifiedIdentity:
    issuer: str
    subject_hash: bytes
    authenticated_at: datetime

    def __repr__(self) -> str:
        return (
            "VerifiedIdentity(issuer=<fixed>, subject_hash=<redacted>, "
            f"authenticated_at={self.authenticated_at!r})"
        )


def verify_identity_platform_token(
    token: str,
    project_id: str,
    *,
    now: datetime | None = None,
    verifier: Callable[[str, str], Mapping[str, Any]] | None = None,
) -> VerifiedIdentity:
    """Verify one fresh Google-provider Identity Platform ID token."""
    if (
        not isinstance(token, str)
        or not 1 <= len(token) <= MAX_ID_TOKEN_CHARS
        or not isinstance(project_id, str)
        or not PROJECT_ID.fullmatch(project_id)
    ):
        raise IdentityRefused("invalid sign-in credential")
    checked_at = now or datetime.now(timezone.utc)
    if checked_at.tzinfo is None:
        raise ValueError("identity verification time must be timezone-aware")
    verify = verifier or _verify_firebase_token
    try:
        claims = verify(token, project_id)
    except Exception as error:
        raise IdentityRefused("invalid sign-in credential") from error

    issuer = f"https://securetoken.google.com/{project_id}"
    subject = claims.get("sub")
    auth_time = claims.get("auth_time")
    firebase = claims.get("firebase")
    if (
        claims.get("iss") != issuer
        or claims.get("aud") != project_id
        or not isinstance(subject, str)
        or not 1 <= len(subject) <= 128
        or not isinstance(auth_time, (int, float))
        or isinstance(auth_time, bool)
        or not isinstance(firebase, dict)
        or firebase.get("sign_in_provider") != "google.com"
        or claims.get("email_verified") is not True
    ):
        raise IdentityRefused("invalid sign-in credential")
    authenticated_at = datetime.fromtimestamp(auth_time, timezone.utc)
    age = checked_at - authenticated_at
    if age < -timedelta(seconds=30) or age > MAX_AUTH_AGE:
        raise IdentityRefused("fresh sign-in required")
    return VerifiedIdentity(
        issuer=issuer,
        subject_hash=hashlib.sha256(subject.encode("utf-8")).digest(),
        authenticated_at=authenticated_at,
    )


def _verify_firebase_token(token: str, project_id: str) -> Mapping[str, Any]:
    from google.oauth2 import id_token

    claims = id_token.verify_firebase_token(
        token,
        FixedGoogleCertRequest(FIREBASE_CERTS_URL),
        audience=project_id,
        clock_skew_in_seconds=30,
    )
    if not claims:
        raise IdentityRefused("invalid sign-in credential")
    return claims
