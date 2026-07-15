"""Composition root for the locked hosted control-plane shell."""

from __future__ import annotations

import os

from .cloud_sql import iam_connection
from .control_plane_service import create_app
from .identity_session import PostgresIdentitySessionRepository


def create_production_app():
    enabled = os.environ.get("ATTUNE_IDENTITY_ENABLED", "false")
    if enabled not in {"true", "false"}:
        raise ValueError("ATTUNE_IDENTITY_ENABLED must be true or false")
    identity_enabled = enabled == "true"
    return create_app(
        os.environ["ATTUNE_PUBLIC_HOST"],
        identity_enabled=identity_enabled,
        project_id=os.environ.get("ATTUNE_IDENTITY_PROJECT")
        if identity_enabled
        else None,
        identity_api_key=os.environ.get("ATTUNE_IDENTITY_API_KEY")
        if identity_enabled
        else None,
        identity_auth_domain=os.environ.get("ATTUNE_IDENTITY_AUTH_DOMAIN")
        if identity_enabled
        else None,
        sessions=(
            PostgresIdentitySessionRepository(iam_connection)
            if identity_enabled
            else None
        ),
    )


app = create_production_app()
