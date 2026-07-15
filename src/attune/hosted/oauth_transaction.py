"""Secret-safe primitives for one hosted OAuth authorization transaction."""

from __future__ import annotations

import base64
import hashlib
import secrets
from dataclasses import dataclass

_STATE_BYTES = 32
_BINDING_BYTES = 32
_NONCE_BYTES = 32
_VERIFIER_BYTES = 64


def _base64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def opaque_hash(value: str) -> bytes:
    """Hash one bounded base64url secret for durable lookup or comparison."""
    if not isinstance(value, str) or not 43 <= len(value) <= 128:
        raise ValueError("OAuth opaque value must contain 43 to 128 characters")
    if any(character not in _BASE64URL for character in value):
        raise ValueError("OAuth opaque value must be unpadded base64url")
    return hashlib.sha256(value.encode("ascii")).digest()


_BASE64URL = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")


@dataclass(frozen=True, repr=False)
class OAuthTransactionSecrets:
    """Browser/provider values that must never be logged or persisted together."""

    state: str
    binding: str
    nonce: str
    pkce_verifier: str
    pkce_challenge: str

    def __repr__(self) -> str:
        return "OAuthTransactionSecrets(<redacted>)"

    @property
    def state_hash(self) -> bytes:
        return opaque_hash(self.state)

    @property
    def binding_hash(self) -> bytes:
        return opaque_hash(self.binding)

    @property
    def nonce_hash(self) -> bytes:
        return opaque_hash(self.nonce)


def create_oauth_transaction_secrets() -> OAuthTransactionSecrets:
    """Generate independent state, cookie binding, nonce, and PKCE S256 values."""
    state = _base64url(secrets.token_bytes(_STATE_BYTES))
    binding = _base64url(secrets.token_bytes(_BINDING_BYTES))
    nonce = _base64url(secrets.token_bytes(_NONCE_BYTES))
    verifier = _base64url(secrets.token_bytes(_VERIFIER_BYTES))
    challenge = _base64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return OAuthTransactionSecrets(
        state=state,
        binding=binding,
        nonce=nonce,
        pkce_verifier=verifier,
        pkce_challenge=challenge,
    )
