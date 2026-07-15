"""Production composition root for the private OAuth exchange."""

from __future__ import annotations

import os

from .cloud_sql import iam_connection
from .oauth import PostgresOAuthExchangeRepository
from .oauth_broker_client import OAuthSecretBrokerClient
from .oauth_exchange import OAuthExchange
from .oauth_exchange_service import create_app


def create_production_app():
    exchange = OAuthExchange(
        PostgresOAuthExchangeRepository(iam_connection),
        OAuthSecretBrokerClient(
            os.environ["ATTUNE_SECRET_BROKER_URL"],
            os.environ["ATTUNE_SECRET_BROKER_AUDIENCE"],
        ),
    )
    return create_app(
        exchange,
        expected_audience=os.environ["ATTUNE_EXPECTED_AUDIENCE"],
        expected_callback=os.environ["ATTUNE_OAUTH_CALLBACK_SERVICE_ACCOUNT"],
    )


app = create_production_app()
