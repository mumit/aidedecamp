from __future__ import annotations

import json

import pytest

from attune.hosted.dispatch_routes import parse_routes


def route(purpose="gmail.reconcile"):
    return {
        "purpose": purpose,
        "queue": "projects/test/locations/test/queues/jobs",
        "target_url": "https://worker.example.run.app/v1/tasks/dispatch",
        "audience": "https://worker.example.run.app",
    }


def test_routes_are_strict_unique_and_bounded():
    parsed = parse_routes(json.dumps([route()]))
    assert set(parsed) == {"gmail.reconcile"}
    with pytest.raises(ValueError):
        parse_routes(json.dumps([route(), route()]))
    with pytest.raises(ValueError):
        parse_routes(json.dumps([{**route(), "tenant_id": "untrusted"}]))
    with pytest.raises(ValueError):
        parse_routes(json.dumps([]))
