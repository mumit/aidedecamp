from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

import pytest

from attune.hosted.identity import IdentityRefused, verify_identity_platform_token

PROJECT = "attune-development-502421"
NOW = datetime(2026, 7, 15, 12, 0, tzinfo=timezone.utc)


def claims(**changes):
    value = {
        "iss": f"https://securetoken.google.com/{PROJECT}",
        "aud": PROJECT,
        "sub": "identity-platform-uid",
        "auth_time": int((NOW - timedelta(seconds=30)).timestamp()),
        "email_verified": True,
        "firebase": {"sign_in_provider": "google.com"},
    }
    value.update(changes)
    return value


def test_identity_verification_minimizes_and_hashes_subject():
    identity = verify_identity_platform_token(
        "signed-token",
        PROJECT,
        now=NOW,
        verifier=lambda token, audience: claims(),
    )
    assert identity.issuer == f"https://securetoken.google.com/{PROJECT}"
    assert identity.subject_hash == hashlib.sha256(b"identity-platform-uid").digest()
    assert "identity-platform-uid" not in repr(identity)


@pytest.mark.parametrize(
    "change",
    [
        {"iss": "https://attacker.example"},
        {"aud": "another-project"},
        {"sub": ""},
        {"email_verified": False},
        {"firebase": {"sign_in_provider": "password"}},
        {"auth_time": int((NOW - timedelta(minutes=6)).timestamp())},
        {"auth_time": int((NOW + timedelta(minutes=1)).timestamp())},
    ],
)
def test_identity_verification_rejects_wrong_or_stale_claims(change):
    with pytest.raises(IdentityRefused):
        verify_identity_platform_token(
            "signed-token",
            PROJECT,
            now=NOW,
            verifier=lambda token, audience: claims(**change),
        )


def test_identity_verification_normalizes_verifier_failures():
    def refused(_token, _audience):
        raise RuntimeError("provider detail")

    with pytest.raises(IdentityRefused, match="invalid sign-in credential") as error:
        verify_identity_platform_token("signed-token", PROJECT, now=NOW, verifier=refused)
    assert "provider detail" not in str(error.value)


def test_identity_verification_rejects_unbounded_inputs():
    with pytest.raises(IdentityRefused):
        verify_identity_platform_token("x" * 16_385, PROJECT, now=NOW)
    with pytest.raises(IdentityRefused):
        verify_identity_platform_token("token", "INVALID", now=NOW)
