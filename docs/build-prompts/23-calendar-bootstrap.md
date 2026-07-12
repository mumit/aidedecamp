# 23 — Calendar bootstrap suppression + hold-offer caps

**Milestone:** M6 stabilization · **Fixes review finding #8 (P2)**

---

Read `CLAUDE.md`, `docs/decisions.md`, and the M6 section of
`docs/roadmap.md`. Run `pytest` before and after.

## Problem

A missing or expired (410) sync token triggers `full_calendar_sync`, which
returns **every event on the calendar as "changed"**. Each pre-existing
overlap then produces a conflict notification and a hold-proposal card —
and symmetric pairs (A overlaps B, B overlaps A) produce two of each. First
run on a busy calendar = a wall of unsolicited cards. Gmail and Chat
polling both got "baseline now, never replay" first-run semantics; Calendar
didn't.

## Task

1. **Rebaseline without dispatching.** In
   `dispatcher.handle_calendar_notification`, a `SyncExpired` recovery
   (first-ever sync OR 410) calls `full_calendar_sync` to store the fresh
   token but then **returns no conflicts** — no notifications, no offers.
   Record one `"ops"` `calendar_rebaselined` audit event (with the event
   count that was skipped) so the silence is explainable. Changes *after*
   the new baseline flow normally. This mirrors poll-mode Gmail/Chat
   first-run semantics exactly.
2. **Symmetric-pair dedupe.** Before offering a hold, check the pending
   registry for a live card on EITHER side of the conflict
   (`event.event_id` or `conflicting_with.event_id`) — one card per
   collision, not two.
3. **Per-run offer cap.** At most `MAX_HOLD_OFFERS_PER_RUN = 3` hold
   proposals per notification (mirroring the follow-up nudge cap);
   conflicts beyond the cap still `notify` (read-only heads-up costs
   nothing) but post no card, and the skip is logged.

## Constraints

- Notify-only detection behavior for normal (non-bootstrap) notifications
  is unchanged; the cap applies to *offers*, never to conflict detection
  or notifications themselves — except during rebaseline, where both are
  suppressed deliberately.
- No new settings unless truly needed; the cap is a module constant like
  the nudge cap.

## Acceptance

- Tests: first-ever sync (no stored token) → token stored, zero
  notifications/offers, `calendar_rebaselined` audited; 410 recovery →
  same; post-baseline change → normal flow; symmetric conflict pair →
  exactly one card; 5 conflicts in one notification → 5 notifies, 3 cards.
- decisions.md entry + CLAUDE.md touch-up.
