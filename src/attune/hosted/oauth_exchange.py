"""One-time OAuth callback exchange core with canonical authority lookup."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .oauth import PostgresOAuthExchangeRepository
from .oauth_transaction import opaque_hash


class OAuthBroker(Protocol):
    def exchange_google_code(self, **kwargs) -> bool: ...


@dataclass(frozen=True)
class OAuthExchangeResult:
    status_code: int


class OAuthExchange:
    def __init__(
        self,
        repository: PostgresOAuthExchangeRepository,
        broker: OAuthBroker,
    ):
        self._repository = repository
        self._broker = broker

    def exchange(
        self, *, authorization_code: str, state: str, binding: str
    ) -> OAuthExchangeResult:
        if not _authorization_code_is_valid(authorization_code):
            return OAuthExchangeResult(400)
        try:
            state_hash = opaque_hash(state)
            binding_hash = opaque_hash(binding)
        except ValueError:
            return OAuthExchangeResult(400)
        try:
            transaction = self._repository.lease(
                state_hash=state_hash,
                binding_hash=binding_hash,
                lease_seconds=30,
            )
        except Exception:
            return OAuthExchangeResult(503)
        if transaction is None or transaction.provider != "google":
            return OAuthExchangeResult(400)
        try:
            installed = self._broker.exchange_google_code(
                credential_intent_id=transaction.credential_intent_id,
                authorization_code=authorization_code,
                pkce_verifier=transaction.pkce_verifier,
                nonce_hash=transaction.nonce_hash,
                redirect_uri=transaction.redirect_uri,
                scopes=transaction.scopes,
            )
        except Exception:
            installed = False
        try:
            finalized = self._repository.finalize(
                transaction.id,
                binding_hash=binding_hash,
                outcome="completed" if installed else "failed",
            )
        except Exception:
            return OAuthExchangeResult(503)
        return OAuthExchangeResult(204 if installed and finalized else 503)


def _authorization_code_is_valid(value: str) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 4096
        and all(0x21 <= ord(character) <= 0x7E for character in value)
    )
