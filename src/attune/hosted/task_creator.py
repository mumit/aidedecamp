"""Fixed-route Google Cloud Tasks adapter for the dispatch broker."""

from __future__ import annotations

from typing import Any

from .dispatch import LeasedDispatch
from .dispatch_broker import BrokerRoute, TaskAlreadyExists


class GoogleCloudTaskCreator:
    def __init__(
        self,
        delivery_service_account: str,
        *,
        client: Any | None = None,
        already_exists_error: type[Exception] | None = None,
    ):
        if not delivery_service_account.endswith(".gserviceaccount.com"):
            raise ValueError("task delivery identity must be a service account")
        if client is None:
            from google.cloud import tasks_v2

            client = tasks_v2.CloudTasksClient()
        if already_exists_error is None:
            from google.api_core.exceptions import AlreadyExists

            already_exists_error = AlreadyExists
        self._client = client
        self._already_exists_error = already_exists_error
        self._delivery_service_account = delivery_service_account

    def create(
        self,
        route: BrokerRoute,
        dispatch: LeasedDispatch,
        body: bytes,
    ) -> None:
        task_name = f"{route.queue}/tasks/{dispatch.task_id}"
        task = {
            "name": task_name,
            "http_request": {
                "http_method": "POST",
                "url": route.target_url,
                "headers": {"Content-Type": "application/json"},
                "body": body,
                "oidc_token": {
                    "service_account_email": self._delivery_service_account,
                    "audience": route.audience,
                },
            },
        }
        try:
            created = self._client.create_task(
                request={"parent": route.queue, "task": task}
            )
        except self._already_exists_error as error:
            raise TaskAlreadyExists from error
        if created.name != task_name:
            raise RuntimeError("Cloud Tasks returned an unexpected task name")
