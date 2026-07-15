"""Registered deterministic hosted worker capabilities."""

from __future__ import annotations

from .repositories import HostedJob
from .tenant import TenantContext
from .worker_dispatch import TaskRoute


def platform_smoke(context: TenantContext, job: HostedJob) -> None:
    if not isinstance(context, TenantContext):
        raise TypeError("verified tenant context is required")
    if job.payload != {"probe": "dispatch-v1"}:
        raise ValueError("platform smoke payload does not match the contract")


def registered_routes() -> dict[str, TaskRoute]:
    route = TaskRoute("platform.smoke", "platform.smoke", platform_smoke)
    return {route.purpose: route}
