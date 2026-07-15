"""Credential-free reachability check for the two fixed Google endpoints."""

from __future__ import annotations

from typing import Any, Protocol

from .google_provider import GMAIL_PROFILE_URL, GOOGLE_TOKEN_URL, REQUEST_TIMEOUT


class HttpSession(Protocol):
    trust_env: bool

    def post(self, url: str, **kwargs: Any): ...

    def get(self, url: str, **kwargs: Any): ...


def check_fixed_google_egress(session: HttpSession | None = None) -> None:
    """Prove TLS reachability by requiring Google's unauthenticated refusals."""

    if session is None:
        import requests

        session = requests.Session()
    session.trust_env = False
    token_response = None
    profile_response = None
    try:
        token_response = session.post(
            GOOGLE_TOKEN_URL,
            data={},
            headers={"Accept": "application/json"},
            allow_redirects=False,
            timeout=REQUEST_TIMEOUT,
            stream=True,
        )
        if token_response.status_code != 400:
            raise RuntimeError("fixed Google token endpoint check failed")
        profile_response = session.get(
            GMAIL_PROFILE_URL,
            headers={"Accept": "application/json"},
            allow_redirects=False,
            timeout=REQUEST_TIMEOUT,
            stream=True,
        )
        if profile_response.status_code not in {401, 403}:
            raise RuntimeError("fixed Gmail endpoint check failed")
    finally:
        for response in (token_response, profile_response):
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass


def main() -> int:
    check_fixed_google_egress()
    print("PASS fixed Google endpoint egress")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
