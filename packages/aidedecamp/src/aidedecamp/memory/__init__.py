"""Memory: capture / consolidate / retrieve (design doc 2.2).

v1 substrate is Mem0, self-hosted, with a migration path to Graphiti once
temporal 'who owns what, as of when' queries start to matter (2.3). Key capture
signals: correction diffs (draft vs sent) and implicit action signals
(approved / edited / ignored / rejected). Consolidation runs on a schedule, not
in real time, and supersedes stale facts rather than overwriting them.

The interface here should stay substrate-agnostic (add / search / consolidate)
so the Mem0 -> Graphiti swap is an implementation change, not an API change.
"""
