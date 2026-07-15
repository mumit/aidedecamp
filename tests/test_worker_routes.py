from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

import pytest

from attune.hosted.repositories import HostedJob
from attune.hosted.tenant import TenantContext
from attune.hosted.worker_routes import platform_smoke, registered_routes


def job(payload):
    return HostedJob(
        UUID("10000000-0000-4000-8000-000000000711"),
        "platform.smoke",
        "leased",
        "platform.smoke",
        payload,
        1,
        datetime.now(timezone.utc),
        datetime.now(timezone.utc),
    )


def test_only_registered_smoke_route_has_no_external_effect_arguments():
    routes = registered_routes()
    assert set(routes) == {"platform.smoke"}
    route = routes["platform.smoke"]
    assert route.capability == "platform.smoke"
    platform_smoke(
        TenantContext(UUID("10000000-0000-4000-8000-000000000712")),
        job({"probe": "dispatch-v1"}),
    )
    with pytest.raises(ValueError):
        platform_smoke(
            TenantContext(UUID("10000000-0000-4000-8000-000000000712")),
            job({"url": "https://untrusted.example"}),
        )
