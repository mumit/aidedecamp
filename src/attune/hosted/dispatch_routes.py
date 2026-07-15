"""Strict infrastructure-owned dispatch route configuration."""

from __future__ import annotations

import json

from .dispatch_broker import BrokerRoute


def parse_routes(value: str) -> dict[str, BrokerRoute]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("dispatch routes must be valid JSON") from error
    if not isinstance(parsed, list) or not parsed or len(parsed) > 32:
        raise ValueError("between 1 and 32 dispatch routes are required")
    routes = {}
    for item in parsed:
        if not isinstance(item, dict) or set(item) != {
            "purpose",
            "queue",
            "target_url",
            "audience",
        }:
            raise ValueError("dispatch route fields do not match the contract")
        route = BrokerRoute(**item)
        if route.purpose in routes:
            raise ValueError("dispatch route purposes must be unique")
        routes[route.purpose] = route
    return routes
