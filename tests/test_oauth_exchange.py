from __future__ import annotations

from types import SimpleNamespace
from uuid import UUID

from attune.hosted.oauth_exchange import OAuthExchange
from attune.hosted.oauth_transaction import create_oauth_transaction_secrets

TRANSACTION = UUID("10000000-0000-4000-8000-000000000701")
INTENT = UUID("10000000-0000-4000-8000-000000000702")


class Repository:
    def __init__(self, transaction=None, *, fail_lease=False, fail_finalize=False):
        self.transaction = transaction
        self.fail_lease = fail_lease
        self.fail_finalize = fail_finalize
        self.calls = []

    def lease(self, **kwargs):
        self.calls.append(("lease", kwargs))
        if self.fail_lease:
            raise RuntimeError("database detail")
        value, self.transaction = self.transaction, None
        return value

    def finalize(self, transaction_id, **kwargs):
        self.calls.append(("finalize", transaction_id, kwargs))
        if self.fail_finalize:
            raise RuntimeError("database detail")
        return True


class Broker:
    def __init__(self, *, result=True, raises=False):
        self.result = result
        self.raises = raises
        self.calls = []

    def exchange_google_code(self, **kwargs):
        self.calls.append(kwargs)
        if self.raises:
            raise RuntimeError("provider secret")
        return self.result


def transaction(secrets):
    return SimpleNamespace(
        id=TRANSACTION,
        credential_intent_id=INTENT,
        provider="google",
        pkce_verifier=secrets.pkce_verifier,
        nonce_hash=secrets.nonce_hash,
        redirect_uri="https://dev.attune.mumit.org/oauth/google/callback",
        scopes=("openid", "email"),
    )


def test_exchange_resolves_all_authority_and_finalizes_once():
    secrets = create_oauth_transaction_secrets()
    repository = Repository(transaction(secrets))
    broker = Broker()
    result = OAuthExchange(repository, broker).exchange(
        authorization_code="synthetic-code",
        state=secrets.state,
        binding=secrets.binding,
    )
    assert result.status_code == 204
    assert set(broker.calls[0]) == {
        "credential_intent_id",
        "authorization_code",
        "pkce_verifier",
        "nonce_hash",
        "redirect_uri",
        "scopes",
    }
    assert broker.calls[0]["credential_intent_id"] == INTENT
    assert repository.calls[-1][2]["outcome"] == "completed"


def test_exchange_rejects_invalid_or_unknown_values_without_broker_call():
    secrets = create_oauth_transaction_secrets()
    for code, state, binding in (
        ("contains whitespace", secrets.state, secrets.binding),
        ("code", "short", secrets.binding),
        ("code", secrets.state, "short"),
    ):
        broker = Broker()
        assert (
            OAuthExchange(Repository(), broker)
            .exchange(authorization_code=code, state=state, binding=binding)
            .status_code
            == 400
        )
        assert broker.calls == []


def test_exchange_fails_closed_and_consumes_transaction_on_broker_failure():
    secrets = create_oauth_transaction_secrets()
    repository = Repository(transaction(secrets))
    result = OAuthExchange(repository, Broker(raises=True)).exchange(
        authorization_code="code",
        state=secrets.state,
        binding=secrets.binding,
    )
    assert result.status_code == 503
    assert repository.calls[-1][2]["outcome"] == "failed"
    assert (
        OAuthExchange(repository, Broker())
        .exchange(
            authorization_code="code",
            state=secrets.state,
            binding=secrets.binding,
        )
        .status_code
        == 400
    )


def test_exchange_hides_storage_failure_as_unavailable():
    secrets = create_oauth_transaction_secrets()
    result = OAuthExchange(Repository(fail_lease=True), Broker()).exchange(
        authorization_code="code",
        state=secrets.state,
        binding=secrets.binding,
    )
    assert result.status_code == 503
