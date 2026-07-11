"""Memory-layer tests. A fake stands in for the real Mem0 ``Memory`` object so
the suite needs neither mem0 nor a vector store, while still exercising our
adapter, config wiring, and capture-signal logic.
"""

from __future__ import annotations

import uuid

import pytest

from aidedecamp.fuelix import FUELIX_BASE_URL, Model, EmbeddingModel
from aidedecamp.memory import (
    ActionSignal,
    DEFAULT_EMBEDDING_MODEL,
    Mem0Store,
    Message,
    build_mem0_config,
    capture_action_signal,
    capture_correction,
)


class FakeMem0:
    """Minimal stand-in for mem0.Memory capturing calls and returning shapes
    that match Mem0's dict contract."""

    def __init__(self):
        self.store: dict[str, dict] = {}
        self.add_calls: list[dict] = []

    def add(self, payload, user_id, metadata=None, infer=True):
        self.add_calls.append(
            {"payload": payload, "user_id": user_id, "metadata": metadata, "infer": infer}
        )
        mid = str(uuid.uuid4())
        text = payload if isinstance(payload, str) else payload[-1]["content"]
        rec = {"id": mid, "memory": text, "metadata": metadata or {}}
        self.store[mid] = rec
        return {"results": [rec]}

    def search(self, query, user_id, limit=8):
        return {
            "results": [
                {**r, "score": 0.9} for r in list(self.store.values())[:limit]
            ]
        }

    def get_all(self, user_id, limit=100):
        return {"results": list(self.store.values())[:limit]}

    def delete(self, memory_id):
        self.store.pop(memory_id, None)


@pytest.fixture
def store():
    return Mem0Store(memory=FakeMem0())


# --- config wiring -------------------------------------------------------

def test_config_points_extraction_llm_at_fuelix(monkeypatch):
    monkeypatch.setenv("FUELIX_TOKEN", "tok-abc")
    cfg = build_mem0_config()
    assert cfg["llm"]["config"]["openai_base_url"] == FUELIX_BASE_URL
    assert cfg["llm"]["config"]["api_key"] == "tok-abc"
    # extraction runs on every write -> cheap model
    assert cfg["llm"]["config"]["model"] == Model.HAIKU_4_5.value


def test_default_embedder_and_dims_are_coupled(monkeypatch):
    monkeypatch.setenv("FUELIX_TOKEN", "tok-abc")
    cfg = build_mem0_config()
    # default is 3-small @ 1536, and the vector store dims match automatically
    assert cfg["embedder"]["config"]["model"] == "text-embedding-3-small"
    assert cfg["vector_store"]["config"]["embedding_model_dims"] == 1536
    assert DEFAULT_EMBEDDING_MODEL is EmbeddingModel.TEXT_3_SMALL


def test_large_model_flips_dims_to_3072(monkeypatch):
    monkeypatch.setenv("FUELIX_TOKEN", "tok-abc")
    cfg = build_mem0_config(embedding_model=EmbeddingModel.TEXT_3_LARGE)
    # choosing large derives 3072 everywhere — mismatch is impossible
    assert cfg["embedder"]["config"]["model"] == "text-embedding-3-large"
    assert cfg["vector_store"]["config"]["embedding_model_dims"] == 3072


def test_embedding_model_dims_lookup():
    assert EmbeddingModel.TEXT_3_LARGE.dims == 3072
    assert EmbeddingModel.TEXT_3_SMALL.dims == 1536
    assert EmbeddingModel.ADA_002.dims == 1536


def test_qdrant_host_env_points_store_at_service(monkeypatch):
    """ADC_QDRANT_HOST lets the containerized assistant reach the compose
    stack's qdrant service (prompt 10); unset keeps mem0's default."""
    monkeypatch.setenv("FUELIX_TOKEN", "tok-abc")
    monkeypatch.setenv("ADC_QDRANT_HOST", "qdrant")
    cfg = build_mem0_config()
    assert cfg["vector_store"]["config"]["host"] == "qdrant"
    assert cfg["vector_store"]["config"]["port"] == 6333

    monkeypatch.delenv("ADC_QDRANT_HOST")
    cfg = build_mem0_config()
    assert "host" not in cfg["vector_store"]["config"]


# --- store adapter -------------------------------------------------------

def test_add_and_search_roundtrip(store):
    store.add("Mumit prefers concise replies", user_id="mumit")
    hits = store.search("reply length", user_id="mumit")
    assert hits and hits[0].text == "Mumit prefers concise replies"
    assert hits[0].score == 0.9


def test_min_score_filter(store):
    store.add("x", user_id="mumit")
    assert store.search("x", user_id="mumit", min_score=0.95) == []


def test_message_list_add(store):
    store.add(
        [Message(role="user", content="hi"), Message(role="assistant", content="yo")],
        user_id="mumit",
    )
    assert store._memory.add_calls[0]["payload"][-1]["content"] == "yo"


# --- capture signals -----------------------------------------------------

def test_correction_captured_with_inference(store):
    out = capture_correction(
        store,
        user_id="mumit",
        domain="mail",
        proposed="Dear Sir or Madam, I hope this message finds you well.",
        sent="Hi — quick one:",
    )
    assert out  # something was stored
    call = store._memory.add_calls[-1]
    assert call["infer"] is True
    assert call["metadata"]["signal"] == "correction"
    assert "diff" in call["metadata"]


def test_identical_correction_is_noop(store):
    out = capture_correction(
        store, user_id="mumit", domain="mail", proposed="same", sent="same"
    )
    assert out == []
    assert store._memory.add_calls == []


def test_action_signal_stored_verbatim(store):
    capture_action_signal(
        store,
        user_id="mumit",
        domain="calendar",
        signal=ActionSignal.APPROVED,
        summary="approved 9am hold with no external attendees",
    )
    call = store._memory.add_calls[-1]
    assert call["infer"] is False  # ground truth, not paraphrased
    assert call["metadata"]["action"] == "approved"
    assert call["payload"].startswith("[approved] calendar:")
