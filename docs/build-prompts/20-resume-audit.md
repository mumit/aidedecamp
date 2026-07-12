# 20 — Resume-time audit: the earning evidence actually gets written

**Milestone:** M6 stabilization · **Fixes review finding #4 (P1)** ·
**Depends on:** 17 (actor)

---

Read `CLAUDE.md`, `docs/decisions.md`, and the M6 section of
`docs/roadmap.md`. Run `pytest` before and after.

## Problem

The graph produces `human_decision`, `applied`, and `signal_captured` on
resume — but `resume_workflow` never writes them to the JSONL audit log.
Slack resumes record nothing; Chat records only `chat_interaction_resumed`,
under domain `"chat"` even for mail/calendar work. Consequence:
`track_records()` can never observe a real human decision, so **graduation
suggestions can never fire in production**. Prompt 12's tests built audit
files synthetically — they certified the fold algorithm, not the pipeline.

## Task

1. **`resume_workflow` records the post-resume events.** New optional
   kwargs `audit_log`, `user_id`, `actor`; after the invoke, record the
   result's post-resume events (name-filtered:
   `human_decision`/`applied`/`apply_skipped`/`apply_failed`/
   `signal_captured` — the pre-interrupt events were already recorded at
   dispatch time, and auto-applied runs never resume, so the filter cannot
   duplicate) against the workflow's thread_id, **with the domain read from
   the result state** (mail/calendar — never hardcoded "chat") and the
   actor stamped onto `human_decision`.
2. **Wire it everywhere resumes happen**: the runtime's `_bound_resume`
   (both channels + the async Chat path) passes `audit_log` + `user_id`;
   channels forward `actor` (from prompt 17). Fix
   `handle_chat_interaction`'s own record to use the result's domain.
3. **The end-to-end pipeline test — zero synthetic entries**: real compiled
   graph, real `JsonlAuditLog` on tmp_path, dispatch → card → resume
   approved/edited/rejected via `resume_workflow` → assert
   `track_records()` sees the decisions and (after 10+ approvals)
   `suggest_graduations()` fires. This is the test the review said was
   missing; it must construct no audit entries by hand.

## Constraints

- Audit failures never break a resume (best-effort, logged) — but the
  happy path must be complete.
- No double-recording: assert each event name appears exactly once per
  workflow in the end-to-end test.

## Acceptance

- Tests above, plus: Slack approve/edit/reject through the bound resume
  produce audit entries with actor + correct domain; Chat interaction
  entries carry the workflow's domain.
- decisions.md entry (including the honest note that prompt 12's synthetic
  tests masked this) + CLAUDE.md audit section update.
