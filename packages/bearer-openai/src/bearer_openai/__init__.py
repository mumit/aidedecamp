"""bearer-openai: an OpenAI-compatible client for bearer-token gateways.

Gateway-agnostic by design. It carries no vendor base URLs or model IDs; the
consuming application supplies those. See :mod:`bearer_openai.client`.
"""

from .client import AsyncBearerClient, BearerClient, resolve_token
from .exceptions import (
    BearerOpenAIError,
    TokenNotConfiguredError,
    TokenRejectedError,
)

__version__ = "0.1.0"

__all__ = [
    "BearerClient",
    "AsyncBearerClient",
    "resolve_token",
    "BearerOpenAIError",
    "TokenNotConfiguredError",
    "TokenRejectedError",
    "__version__",
]
