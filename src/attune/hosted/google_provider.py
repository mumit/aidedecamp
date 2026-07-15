"""Fixed, bounded Google operations for the hosted secret broker."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Mapping, Protocol

GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GMAIL_PROFILE_URL = "https://gmail.googleapis.com/gmail/v1/users/me/profile"
GMAIL_READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
MAX_PROVIDER_RESPONSE_BYTES = 32_768
MAX_ACCESS_TOKEN_CHARS = 8_192
REQUEST_TIMEOUT = (3.05, 10)


class ProviderFailure(RuntimeError):
    """A content-free provider failure safe for broker control flow."""


class HttpSession(Protocol):
    def post(self, url: str, **kwargs: Any): ...

    def get(self, url: str, **kwargs: Any): ...


@dataclass(frozen=True)
class GmailProfile:
    history_id: str
    messages_total: int
    threads_total: int

    def response(self) -> dict[str, Any]:
        # Google also returns emailAddress. The broker deliberately omits it.
        return {
            "history_id": self.history_id,
            "messages_total": self.messages_total,
            "threads_total": self.threads_total,
        }


class GoogleProvider:
    """Construct only reviewed Google requests; never accept URLs from callers."""

    def __init__(self, session: HttpSession | None = None):
        if session is None:
            import requests

            session = requests.Session()
            # Provider credentials must not be routed through ambient proxy
            # variables inherited from the process environment.
            session.trust_env = False
        self._session = session

    def gmail_profile(self, credential: Mapping[str, Any]) -> GmailProfile:
        oauth = _authorized_user_credential(credential)
        try:
            token_response = self._session.post(
                GOOGLE_TOKEN_URL,
                data={
                    "grant_type": "refresh_token",
                    "refresh_token": oauth["refresh_token"],
                    "client_id": oauth["client_id"],
                    "client_secret": oauth["client_secret"],
                },
                headers={"Accept": "application/json"},
                allow_redirects=False,
                timeout=REQUEST_TIMEOUT,
                stream=True,
            )
        except Exception as error:
            raise ProviderFailure("token request failed") from error
        token_body = _json_response(token_response, expected_status=200)
        access_token = token_body.get("access_token")
        token_type = token_body.get("token_type")
        if (
            not isinstance(access_token, str)
            or not 1 <= len(access_token) <= MAX_ACCESS_TOKEN_CHARS
            or any(character.isspace() for character in access_token)
            or not isinstance(token_type, str)
            or token_type.lower() != "bearer"
        ):
            raise ProviderFailure("invalid token response")

        try:
            profile_response = self._session.get(
                GMAIL_PROFILE_URL,
                headers={
                    "Accept": "application/json",
                    "Authorization": f"Bearer {access_token}",
                },
                allow_redirects=False,
                timeout=REQUEST_TIMEOUT,
                stream=True,
            )
        except Exception as error:
            raise ProviderFailure("Gmail request failed") from error
        profile = _json_response(profile_response, expected_status=200)
        history_id = profile.get("historyId")
        messages_total = profile.get("messagesTotal")
        threads_total = profile.get("threadsTotal")
        if (
            not isinstance(history_id, str)
            or not history_id.isdecimal()
            or len(history_id) > 32
            or not _bounded_count(messages_total)
            or not _bounded_count(threads_total)
        ):
            raise ProviderFailure("invalid Gmail profile response")
        return GmailProfile(history_id, messages_total, threads_total)


def _authorized_user_credential(value: Mapping[str, Any]) -> dict[str, str]:
    if not isinstance(value, Mapping):
        raise ProviderFailure("invalid credential")
    required = ("refresh_token", "client_id", "client_secret")
    parsed: dict[str, str] = {}
    for field in required:
        candidate = value.get(field)
        if not isinstance(candidate, str) or not 1 <= len(candidate) <= 8_192:
            raise ProviderFailure("invalid credential")
        parsed[field] = candidate
    token_uri = value.get("token_uri", GOOGLE_TOKEN_URL)
    if token_uri != GOOGLE_TOKEN_URL:
        raise ProviderFailure("unapproved token endpoint")
    scopes = value.get("scopes")
    if scopes is not None:
        if (
            not isinstance(scopes, list)
            or not all(isinstance(scope, str) for scope in scopes)
            or GMAIL_READONLY_SCOPE not in scopes
        ):
            raise ProviderFailure("required scope is unavailable")
    return parsed


def _json_response(response: Any, *, expected_status: int) -> dict[str, Any]:
    try:
        if response.status_code != expected_status:
            raise ProviderFailure("provider rejected request")
        raw = response.raw.read(MAX_PROVIDER_RESPONSE_BYTES + 1, decode_content=True)
        if len(raw) > MAX_PROVIDER_RESPONSE_BYTES:
            raise ProviderFailure("provider response exceeds limit")
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            raise ProviderFailure("provider response must be an object")
        return parsed
    except ProviderFailure:
        raise
    except Exception as error:
        raise ProviderFailure("provider request failed") from error
    finally:
        try:
            response.close()
        except Exception:
            pass


def _bounded_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value < 2**63
