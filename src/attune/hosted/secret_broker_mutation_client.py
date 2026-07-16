"""Authenticated client for fixed control-plane credential mutations."""

from __future__ import annotations

from typing import Any, Callable
from uuid import UUID

from .audit_client import _google_id_token
from .secret_broker_client import _bounded_body, _close, _https_origin


class SecretBrokerMutationClient:
    def __init__(
        self,
        service_url: str,
        audience: str,
        *,
        token_provider: Callable[[str], str] | None = None,
        session: Any | None = None,
        timeout_seconds: float = 15.0,
    ):
        self._service_url = _https_origin(service_url, "secret broker URL")
        self._audience = _https_origin(audience, "secret broker audience")
        if not 1 <= timeout_seconds <= 30:
            raise ValueError("secret broker timeout must be between 1 and 30 seconds")
        self._token_provider = token_provider or _google_id_token
        if session is None:
            import requests

            session = requests.Session()
            session.trust_env = False
        self._session = session
        self._timeout = timeout_seconds

    def revoke(self, intent_id: UUID) -> None:
        if not isinstance(intent_id, UUID):
            raise TypeError("intent_id must be a UUID")
        token = self._token_provider(self._audience)
        if not isinstance(token, str) or not token:
            raise RuntimeError("secret broker identity token is unavailable")
        response = self._session.post(
            f"{self._service_url}/v1/credentials/revoke",
            json={"intent_id": str(intent_id)},
            headers={"Authorization": f"Bearer {token}"},
            timeout=self._timeout,
            allow_redirects=False,
            stream=True,
        )
        try:
            if response.status_code != 204 or _bounded_body(response):
                raise RuntimeError("secret broker revocation failed")
        finally:
            _close(response)
