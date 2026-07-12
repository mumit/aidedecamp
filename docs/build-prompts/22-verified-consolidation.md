# 22 — Verified, journaled consolidation

**Milestone:** M6 stabilization · **Fixes review finding #7 (P1)**

---

Read `CLAUDE.md`, `docs/decisions.md` (consolidation entry), and the M6
section of `docs/roadmap.md`. Run `pytest` before and after.

## Problem

The consolidation pass calls `add()`, **ignores its result**, then deletes
every absorbed memory. Mem0's `add` can legitimately return no records (its
own extraction may decide nothing is worth storing, or the write can
partially fail) — in which case the pass erases the source evidence while
writing nothing to replace it. The malformed-JSON guard protects against a
bad plan; nothing protects against a bad *write*.

## Task

1. **Verify before delete.** In `Mem0Store.consolidate`, every mutation
   (promotion, merge, supersession) checks that `add(...)` returned at
   least one record. Empty result → **no deletion for that item**, a
   `write_unverified` note, and — because a failing substrate mid-batch is
   a systemic condition, not an item-level one — **abort the rest of the
   batch** (stop processing further mutations; the next nightly run retries
   with a fresh plan).
2. **Journal every applied mutation.** `consolidate` gains an optional
   `audit_log` kwarg (base signature grows the same optional; default
   None). Each applied mutation records one `"memory"` workflow event
   (`consolidation_promoted` / `consolidation_merged` /
   `consolidation_superseded`) carrying the new record id(s) and the
   deleted id(s) — so "what did last night's pass do to my memory" is a
   query, not archaeology. Aborts record `consolidation_aborted` with the
   reason. `Runtime.run_consolidation` passes the real audit log.
3. **Delete only after verification, in write→verify→delete order per
   item** — a crash between verify and delete leaves a duplicate (harmless,
   next pass merges it) rather than a loss.

## Constraints

- The existing conservative-apply contract stays intact (malformed plan →
  nothing; unknown ids → never deleted); this prompt extends it to the
  write side.
- Journaling failures don't abort consolidation (best-effort, logged) —
  but write-verification failures DO abort, hard.

## Acceptance

- Tests: add returning `[]` → absorbed ids NOT deleted + batch aborted +
  `write_unverified`/`consolidation_aborted` notes and audit events;
  add succeeding → mutation applied + journaled with new/deleted ids;
  order: a delete never precedes its verified write (assert on a recording
  fake's call sequence); the existing eval-set knowledge-update scenario
  still passes.
- decisions.md entry + CLAUDE.md memory-module line updated.
