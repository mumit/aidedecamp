from __future__ import annotations

from uuid import UUID

import pytest

from attune.hosted.secret_broker_mutation_client import SecretBrokerMutationClient

INTENT = UUID("10000000-0000-4000-8000-000000000531")
URL = "https://attune-secret-broker.example.run.app"
AUDIENCE = "https://attune-secret-broker.attune.internal"


class Response:
    def __init__(self, status=204, chunks=()):
        self.status_code = status
        self.headers = {}
        self.chunks = chunks
        self.closed = False

    def iter_content(self, chunk_size):
        assert chunk_size == 4096
        yield from self.chunks

    def close(self):
        self.closed = True


class Session:
    def __init__(self, response=None):
        self.response = response or Response()
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.response


def test_revoke_uses_fixed_route_audience_and_empty_204_contract():
    session = Session()
    audiences = []
    result = SecretBrokerMutationClient(
        URL,
        AUDIENCE,
        token_provider=lambda audience: audiences.append(audience) or "token",
        session=session,
    ).revoke(INTENT)
    assert result is None
    assert audiences == [AUDIENCE]
    assert session.calls == [
        (
            f"{URL}/v1/credentials/revoke",
            {
                "json": {"intent_id": str(INTENT)},
                "headers": {"Authorization": "Bearer token"},
                "timeout": 15.0,
                "allow_redirects": False,
                "stream": True,
            },
        )
    ]
    assert session.response.closed


@pytest.mark.parametrize("response", [Response(200), Response(204, (b"x",))])
def test_revoke_fails_closed_on_ambiguous_response(response):
    with pytest.raises(RuntimeError, match="revocation failed"):
        SecretBrokerMutationClient(
            URL,
            AUDIENCE,
            token_provider=lambda audience: "token",
            session=Session(response),
        ).revoke(INTENT)
    assert response.closed
