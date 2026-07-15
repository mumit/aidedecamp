from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import pytest

from attune.hosted.tenant import TenantContext
from attune.hosted.vault import PostgresCredentialIntentRepository


def forbidden_connection():
    raise AssertionError("invalid requests must not reach PostgreSQL")


def test_credential_producer_rejects_wrong_operations_before_database():
    control = PostgresCredentialIntentRepository(
        forbidden_connection, producer_kind="control_plane"
    )
    with pytest.raises(ValueError, match="not allowed"):
        control.request(
            TenantContext(UUID("10000000-0000-4000-8000-000000000001")),
            connector_id=UUID("10000000-0000-4000-8000-000000000002"),
            operation="use",
            capability="gmail.read",
            idempotency_key=bytes(32),
            expires_at=datetime.now(timezone.utc),
        )


def test_credential_producer_kind_is_fixed_at_construction():
    with pytest.raises(ValueError, match="producer kind"):
        PostgresCredentialIntentRepository(
            forbidden_connection, producer_kind="model_selected"
        )
