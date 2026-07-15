"""Composition root for the locked hosted control-plane shell."""

from __future__ import annotations

import os

from .control_plane_service import create_app

app = create_app(os.environ["ATTUNE_PUBLIC_HOST"])
