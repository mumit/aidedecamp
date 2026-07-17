"""Production composition root for private customer-export generation."""

from __future__ import annotations

import os

from .cloud_sql import iam_connection
from .customer_export import (
    PostgresCustomerExportClaims,
    PostgresCustomerExportExecution,
)
from .customer_export_writer import CustomerExportWriter
from .export_crypto import ExportEnvelopeCipher
from .export_storage import GoogleExportObjectStore
from .export_writer_service import (
    ExportTaskDispatcher,
    PostgresExportTaskAuthority,
    create_app,
)
from .vault_crypto import GoogleKmsKeyWrapper


def create_production_app():
    writer = CustomerExportWriter(
        claims=PostgresCustomerExportClaims(iam_connection),
        execution=PostgresCustomerExportExecution(iam_connection),
        cipher=ExportEnvelopeCipher(
            GoogleKmsKeyWrapper(os.environ["ATTUNE_EXPORT_KMS_KEY"])
        ),
        objects=GoogleExportObjectStore(os.environ["ATTUNE_EXPORT_BUCKET"]),
    )
    return create_app(
        ExportTaskDispatcher(
            authority=PostgresExportTaskAuthority(iam_connection),
            writer=writer,
            expected_audience=os.environ["ATTUNE_EXPECTED_AUDIENCE"],
            expected_service_account=os.environ[
                "ATTUNE_TASK_DISPATCH_SERVICE_ACCOUNT"
            ],
        )
    )


app = create_production_app()
