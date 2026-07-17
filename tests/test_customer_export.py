"""Unit tests for customer-export database adapters."""

from datetime import datetime, timezone
from uuid import UUID

from attune.hosted.customer_export import PostgresCustomerExportClaims


def test_export_claims_support_pg8000_cursors_without_context_manager():
    tenant_id = UUID(int=1)
    export_id = UUID(int=2)
    run_id = UUID(int=3)

    class Cursor:
        def execute(self, query, parameters):
            self.query = query
            self.parameters = parameters

        def fetchone(self):
            return (
                tenant_id,
                export_id,
                UUID(int=4),
                "account",
                datetime.now(timezone.utc),
            )

        def close(self):
            self.closed = True

    class Connection:
        def __init__(self):
            self.value = Cursor()

        def cursor(self):
            return self.value

        def commit(self):
            self.committed = True

        def close(self):
            self.closed = True

    connection = Connection()
    claim = PostgresCustomerExportClaims(lambda: connection).claim(
        export_id, run_id=run_id, expected_tenant_id=tenant_id
    )
    assert claim is not None and claim.tenant_id == tenant_id
    assert "claim_customer_export_for_tenant" in connection.value.query
    assert connection.value.parameters == (tenant_id, export_id, run_id)
    assert connection.value.closed and connection.committed and connection.closed
