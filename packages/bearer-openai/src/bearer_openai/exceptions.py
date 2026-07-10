"""Exceptions raised by bearer-openai.

The central design goal (see the assistant's design doc, section 4.5) is that a
rejected token must fail *loudly and specifically*, not disappear into a generic
retry loop. A bearer token behind an enterprise gateway is typically long-lived
and rotated by hand, so a 401 almost always means "a human needs to rotate this
token", not "retry in a moment".
"""

from __future__ import annotations


class BearerOpenAIError(Exception):
    """Base class for all bearer-openai errors."""


class TokenNotConfiguredError(BearerOpenAIError):
    """Raised at construction time when no bearer token can be found.

    This is deliberately separate from ``TokenRejectedError``: a missing token
    is a deployment/config mistake caught before any network call, whereas a
    rejected token is a live auth failure discovered mid-flight.
    """


class TokenRejectedError(BearerOpenAIError):
    """Raised when the gateway rejects the bearer token (HTTP 401).

    Carries a clear, actionable message pointing at manual rotation rather than
    masking the failure as a transient error. The original exception from the
    underlying client is preserved on ``__cause__`` via ``raise ... from``.
    """

    def __init__(self, message: str | None = None, *, base_url: str | None = None) -> None:
        base = base_url or "the configured gateway"
        default = (
            f"Bearer token rejected by {base} (HTTP 401). "
            "This token is likely expired or revoked and needs MANUAL ROTATION. "
            "Update the token in your secrets store / environment and restart the "
            "service. This is not a transient error and should not be retried."
        )
        super().__init__(message or default)
        self.base_url = base_url
