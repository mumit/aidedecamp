"""Cloud SQL IAM connection factory for private hosted services."""

from __future__ import annotations

import atexit
import os
from threading import Lock
from typing import Any

_connector: Any = None
_connector_lock = Lock()


def iam_connection() -> Any:
    """Open one private-IP connection using the workload's IAM identity."""

    from google.cloud.sql.connector import Connector, IPTypes, RefreshStrategy

    global _connector
    with _connector_lock:
        if _connector is None:
            _connector = Connector(refresh_strategy=RefreshStrategy.LAZY)
    return _connector.connect(
        os.environ["ATTUNE_CLOUD_SQL_INSTANCE"],
        "pg8000",
        user=os.environ["ATTUNE_DB_USER"],
        db=os.environ.get("ATTUNE_DB_NAME", "attune"),
        enable_iam_auth=True,
        ip_type=IPTypes.PRIVATE,
    )


def close_connector() -> None:
    global _connector
    with _connector_lock:
        if _connector is not None:
            _connector.close()
            _connector = None


atexit.register(close_connector)
