"""Authenticated, fixed-contract client for Google OAuth credential exchange."""

from __future__ import annotations

from typing import Any, Callable, Sequence
from urllib.parse import urlsplit
from uuid import UUID

from .audit_client import _google_id_token

TokenProvider = Callable[[str], str]


class OAuthSecretBrokerClient:
    def __init__(
        self,
        service_url: str,
        audience: str,
        *,
        token_provider: TokenProvider | None = None,
        session: Any | None = None,
        timeout_seconds: float = 20.0,
    ):
        self._service_url = _https_origin(service_url, "secret broker URL")
        self._audience = _https_origin(audience, "secret broker audience")
        if not 1 <= timeout_seconds <= 30:
            raise ValueError("secret broker timeout must be between 1 and 30 seconds")
        self._token_provider = token_provider or _google_id_token
        self._session = session
        self._timeout = timeout_seconds

    def exchange_google_code(
        self,
        *,
        credential_intent_id: UUID,
        authorization_code: str,
        pkce_verifier: str,
        nonce_hash: bytes,
        redirect_uri: str,
        scopes: Sequence[str],
    ) -> bool:
        import requests

        if not isinstance(credential_intent_id, UUID):
            raise TypeError("credential_intent_id must be a UUID")
        if not isinstance(nonce_hash, bytes) or len(nonce_hash) != 32:
            raise ValueError("nonce_hash must be exactly 32 bytes")
        token = self._token_provider(self._audience)
        if not isinstance(token, str) or not token:
            raise RuntimeError("secret broker identity token is unavailable")
        session = self._session
        if session is None:
            session = requests.Session()
            session.trust_env = False
        response = session.post(
            f"{self._service_url}/v1/oauth/google/exchange",
            json={
                "intent_id": str(credential_intent_id),
                "code": authorization_code,
                "pkce_verifier": pkce_verifier,
                "nonce_hash": nonce_hash.hex(),
                "redirect_uri": redirect_uri,
                "scopes": list(scopes),
            },
            headers={"Authorization": f"Bearer {token}"},
            timeout=self._timeout,
            allow_redirects=False,
        )
        try:
            return response.status_code == 204
        finally:
            response.close()


def _https_origin(value: str, name: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError(f"{name} must be an HTTPS origin")
    return value.rstrip("/")
