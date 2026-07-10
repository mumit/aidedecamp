"""Mem0-backed implementation of :class:`MemoryStore` (design doc 2.2).

Two things this module gets right that a naive Mem0 setup gets wrong:

1. **Mem0's own LLM points at Fuel iX, not OpenAI.** Mem0 uses an LLM to extract
   facts on ``add`` and an embedder to vectorize them. Both default to OpenAI.
   Since everything here must run through the TELUS gateway, we configure Mem0's
   ``openai`` provider with ``openai_base_url = https://api.fuelix.ai`` and the
   Fuel iX token, so no data leaves via a second, unmanaged OpenAI path. The
   extraction model is the *cheap* one (Haiku 4.5) per the design's "stage the
   extraction LLM on a small model" guidance — extraction runs on every write.

2. **The embedder is handled explicitly.** Mem0's embedder also defaults to
   OpenAI. If the Fuel iX gateway exposes an embeddings endpoint, point the
   embedder there too; if not, this is the one place a local embedder (Ollama /
   nomic-embed-text) plugs in. Whichever is chosen, ``embedding_model_dims`` in
   the vector store MUST match the embedder's output dims or pgvector rejects
   every insert. That coupling is made explicit in the config below rather than
   left as a lurking runtime error.

This module imports ``mem0`` lazily so the rest of the package (and its tests)
load without mem0 installed until Phase 0 actually stands up the store.
"""

from __future__ import annotations

from typing import Any

from ..fuelix import (
    DEFAULT_EMBEDDING_MODEL,
    FUELIX_BASE_URL,
    FUELIX_TOKEN_ENV,
    EmbeddingModel,
    Model,
)
from .base import (
    ConsolidationReport,
    MemoryRecord,
    MemoryStore,
    Message,
    _now,
)

import os


def build_mem0_config(
    *,
    fuelix_token: str | None = None,
    extraction_model: str = Model.HAIKU_4_5.value,
    embedding_model: EmbeddingModel = DEFAULT_EMBEDDING_MODEL,
    vector_store: dict[str, Any] | None = None,
    embedder: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Assemble a Mem0 ``from_config`` dict wired to Fuel iX for extraction.

    The embedder and the vector store's ``embedding_model_dims`` are both derived
    from a single ``embedding_model`` argument, so they cannot drift out of sync
    — the mismatch that otherwise makes every insert fail is structurally
    prevented. Override ``embedder``/``vector_store`` only for a local embedder
    (e.g. Ollama), in which case set matching dims yourself.
    """
    token = fuelix_token or os.environ.get(FUELIX_TOKEN_ENV)

    llm = {
        "provider": "openai",
        "config": {
            "model": extraction_model,
            "openai_base_url": FUELIX_BASE_URL,
            "api_key": token,
            "temperature": 0.1,
        },
    }

    # Embedder: Fuel iX-served OpenAI embedding model by default. Its dims drive
    # the vector store config below.
    resolved_embedder = embedder or {
        "provider": "openai",
        "config": {
            "model": embedding_model.value,
            "openai_base_url": FUELIX_BASE_URL,
            "api_key": token,
        },
    }

    # Vector store: dims come from the chosen embedding model. If the caller
    # supplied a custom embedder, they own the dims and we respect their store.
    if vector_store is not None:
        resolved_vs = vector_store
    else:
        resolved_vs = {
            "provider": "qdrant",
            "config": {
                "collection_name": "aidedecamp",
                "embedding_model_dims": embedding_model.dims,
            },
        }

    return {"llm": llm, "embedder": resolved_embedder, "vector_store": resolved_vs}


class Mem0Store(MemoryStore):
    """A :class:`MemoryStore` backed by a self-hosted Mem0 ``Memory`` instance."""

    def __init__(self, config: dict[str, Any] | None = None, *, memory: Any = None):
        """Either pass a ready ``memory`` object (tests inject a fake), or a
        Mem0 config dict to construct one lazily."""
        if memory is not None:
            self._memory = memory
        else:
            try:
                from mem0 import Memory  # lazy: mem0 not needed to import package
            except ImportError as exc:  # pragma: no cover
                raise ImportError(
                    "Mem0Store requires mem0ai. `pip install mem0ai` "
                    "(and a vector store) before standing up the memory layer."
                ) from exc
            self._memory = Memory.from_config(config or build_mem0_config())

    @staticmethod
    def _to_record(d: dict[str, Any]) -> MemoryRecord:
        return MemoryRecord(
            id=d.get("id", ""),
            text=d.get("memory") or d.get("text") or "",
            score=d.get("score"),
            metadata=d.get("metadata") or {},
        )

    def add(
        self,
        messages: list[Message] | str,
        *,
        user_id: str,
        metadata: dict[str, Any] | None = None,
        infer: bool = True,
    ) -> list[MemoryRecord]:
        if isinstance(messages, str):
            payload: Any = messages
        else:
            payload = [{"role": m.role, "content": m.content} for m in messages]
        result = self._memory.add(
            payload, user_id=user_id, metadata=metadata or {}, infer=infer
        )
        results = result.get("results", []) if isinstance(result, dict) else result
        return [self._to_record(r) for r in (results or [])]

    def search(
        self,
        query: str,
        *,
        user_id: str,
        limit: int = 8,
        min_score: float | None = None,
    ) -> list[MemoryRecord]:
        result = self._memory.search(query=query, user_id=user_id, limit=limit)
        results = result.get("results", []) if isinstance(result, dict) else result
        records = [self._to_record(r) for r in (results or [])]
        if min_score is not None:
            records = [r for r in records if (r.score or 0) >= min_score]
        return records

    def get_all(self, *, user_id: str, limit: int = 100) -> list[MemoryRecord]:
        result = self._memory.get_all(user_id=user_id, limit=limit)
        results = result.get("results", []) if isinstance(result, dict) else result
        return [self._to_record(r) for r in (results or [])]

    def delete(self, memory_id: str) -> None:
        self._memory.delete(memory_id=memory_id)

    def consolidate(self, *, user_id: str) -> ConsolidationReport:
        # Mem0's managed add path already does UPDATE/supersede on write. A
        # deeper scheduled pass (cross-memory dedupe, stale-fact supersession
        # via the strong model) is a Phase 4 item; report a clean no-op for now
        # so the scheduler and audit log have something well-formed to record.
        return ConsolidationReport(
            user_id=user_id,
            ran_at=_now(),
            notes=["mem0: relying on write-time update; deep pass deferred to Phase 4"],
        )
