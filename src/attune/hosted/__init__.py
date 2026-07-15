"""Hosted-service storage and migration primitives.

Nothing in this package is used by the single-principal local runtime. Hosted
workers opt into it explicitly after a verified tenant has been established.
"""

from .tenant import TenantContext, tenant_transaction

__all__ = ["TenantContext", "tenant_transaction"]
