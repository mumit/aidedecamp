from __future__ import annotations

import base64
import hashlib

import pytest

from attune.hosted.oauth_transaction import (
    create_oauth_transaction_secrets,
    opaque_hash,
)


def _challenge(verifier: str) -> str:
    return (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest())
        .rstrip(b"=")
        .decode("ascii")
    )


def test_transaction_secrets_are_independent_bounded_and_pkce_s256():
    values = create_oauth_transaction_secrets()

    assert len({values.state, values.binding, values.nonce, values.pkce_verifier}) == 4
    assert len(values.state) == 43
    assert len(values.binding) == 43
    assert len(values.nonce) == 43
    assert 43 <= len(values.pkce_verifier) <= 128
    assert values.pkce_challenge == _challenge(values.pkce_verifier)
    assert len(values.pkce_challenge) == 43
    assert "=" not in values.state + values.binding + values.nonce


def test_transaction_secret_repr_is_redacted():
    values = create_oauth_transaction_secrets()
    rendered = repr(values)

    assert rendered == "OAuthTransactionSecrets(<redacted>)"
    assert values.state not in rendered
    assert values.binding not in rendered
    assert values.nonce not in rendered
    assert values.pkce_verifier not in rendered


def test_hashes_are_fixed_and_values_are_fresh():
    first = create_oauth_transaction_secrets()
    second = create_oauth_transaction_secrets()

    assert len(first.state_hash) == 32
    assert len(first.binding_hash) == 32
    assert len(first.nonce_hash) == 32
    assert first.state_hash != second.state_hash
    assert first.binding_hash != second.binding_hash
    assert first.nonce_hash != second.nonce_hash


@pytest.mark.parametrize(
    "value",
    [
        "",
        "a" * 42,
        "a" * 129,
        "a" * 42 + "=",
        "a" * 42 + "+",
        "a" * 42 + "/",
        "a" * 42 + " ",
    ],
)
def test_opaque_hash_rejects_unbounded_or_non_base64url_values(value: str):
    with pytest.raises(ValueError):
        opaque_hash(value)


def test_opaque_hash_rejects_non_text():
    with pytest.raises(ValueError):
        opaque_hash(b"a" * 43)  # type: ignore[arg-type]
