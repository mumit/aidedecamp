"""Composition root for the dormant hosted OAuth callback scrubber."""

from __future__ import annotations

import os

from .oauth_callback_service import create_app

app = create_app(os.environ["ATTUNE_PUBLIC_HOST"])
