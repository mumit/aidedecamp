# 21 — Freshness, retries, and honest at-least-once processing

**Milestone:** M6 stabilization · **Fixes review findings #5 + #6 (P1)**

---

Read `CLAUDE.md`, `docs/decisions.md`, and the M6 section of
`docs/roadmap.md`. Run `pytest` before and after.

## Problem

1. The Gmail history cursor advances before threads are fetched, drafted,
   or posted; a `get_thread` failure is a bare silent `continue` — the
   thread is simply lost, invisibly.
2. Approval cards have no freshness precondition: the sweep deliberately
   leaves expired workflows resumable, so a week-old card can create a
   draft against a thread that has since moved on (new replies, resolved),
   or a hold against an event that was rescheduled.

Note (recorded, not fixed here): moving the cursor after dispatch would
trade this for poison-thread infinite reprocessing; full transactional
inbox/outbox is written up as the "action kernel" option in the M6
decisions entry, with multi-user or ACT_NOTIFY-at-scale as the tripwire.

## Task

1. **Retry-then-audit, never silent-skip.** `handle_gmail_notification`
   retries a failed `connector.get_thread` (2 retries, immediate), then
   records an `"ops"` `thread_fetch_failed` audit event + warning log with
   the thread id. Same for `get_event` in the calendar path. Nothing is
   silently dropped anymore — every loss is queryable.
2. **Source snapshot at proposal time.** Workflow state gains
   `source_snapshot: Optional[str]`: for mail, the thread's
   `last_message_at` ISO at draft time (dispatcher + followups set it);
   for calendar holds, the conflicted event's `start` ISO.
3. **Freshness check at apply.** `make_connector_apply_fn` re-fetches the
   source (it already re-fetches the thread) and compares: mail — a newer
   `last_message_at` than the snapshot means the thread changed since the
   card was posted; calendar — a moved `start` means the conflict may be
   gone. On staleness, apply **refuses**: `apply_error="source_changed"`,
   audit records it, and the confirmation says the decision was recorded
   but nothing was created because the source changed — re-review. No
   snapshot in state (older cards) → apply proceeds (back-compat), but new
   proposals always carry one.
4. **Swept cards resume with eyes open**: `sweep_ignored` marks entries
   `status="ignored"` (distinct from human-resolved); `resume_workflow`
   passes through unchanged — the freshness check above is what actually
   protects a late click, and the pending entry's status is now honest for
   anyone querying it.

## Constraints

- At-least-once + idempotency is the direction; at-most-once silent loss is
  what's being removed. The pending-registry dedupe (one live card per
  source) remains the duplicate-card guard.
- Freshness comparison is string-ISO equality/ordering on aware datetimes —
  no clock skew games.

## Acceptance

- Tests: fetch fails twice then succeeds → thread processed, no audit
  failure; fails three times → audited `thread_fetch_failed`, loop
  continues to the next thread; stale mail apply refused with
  `source_changed` + honest confirmation; stale hold apply refused; fresh
  applies unchanged; missing snapshot proceeds; sweep marks `ignored`.
- decisions.md entry (including the kernel-option write-up + tripwire) +
  CLAUDE.md updates.
