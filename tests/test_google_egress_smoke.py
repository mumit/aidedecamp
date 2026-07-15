from __future__ import annotations

import pytest

from attune.hosted.google_egress_smoke import check_fixed_google_egress
from attune.hosted.google_provider import (
    GMAIL_PROFILE_URL,
    GOOGLE_TOKEN_URL,
    REQUEST_TIMEOUT,
)


class Response:
    def __init__(self, status_code):
        self.status_code = status_code
        self.closed = False

    def close(self):
        self.closed = True


class Session:
    def __init__(self, token_status=400, profile_status=401):
        self.trust_env = True
        self.token = Response(token_status)
        self.profile = Response(profile_status)
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append(("post", url, kwargs))
        return self.token

    def get(self, url, **kwargs):
        self.calls.append(("get", url, kwargs))
        return self.profile


def test_probe_uses_only_fixed_endpoints_without_credentials_or_redirects():
    session = Session()
    check_fixed_google_egress(session)
    assert session.trust_env is False
    assert [call[1] for call in session.calls] == [
        GOOGLE_TOKEN_URL,
        GMAIL_PROFILE_URL,
    ]
    assert session.calls[0][2]["data"] == {}
    assert all(call[2]["allow_redirects"] is False for call in session.calls)
    assert all(call[2]["timeout"] == REQUEST_TIMEOUT for call in session.calls)
    assert session.token.closed and session.profile.closed


@pytest.mark.parametrize("token_status,profile_status", [(200, 401), (400, 200)])
def test_probe_rejects_unexpected_endpoint_responses(token_status, profile_status):
    session = Session(token_status, profile_status)
    with pytest.raises(RuntimeError):
        check_fixed_google_egress(session)
    assert session.token.closed
    if token_status == 400:
        assert session.profile.closed
