# Mission: Data-pull (collect) step still shows September 2026 after pulling the August review

**Type:** bug
**Goal:** The data-pull step's heading shows the same month as the start card's "Next up" and the builder — the month of the review being created.
**Acceptance Criteria:**
- With July 2026 as the last published month, pressing "Pull data & start" on the "Next up · August 2026" card shows "Pulling data · August 2026" on the collect step (not September 2026)
- The collect step, the builder header and the start card show the same month throughout one pull
**Out of Scope:**
- Changing how the next-up month is chosen (fixed by #209)
**Constraints:**
- Follow-up to #209, whose fix made the saved draft and the builder August but left the collect step on today's month. The collect heading reads `monthLabel(monthKeyOf(draftId ?? today))` (src/views/MbrBuilderView.tsx ~l.546) and falls back to today.
- Reported by the product owner (stand-in) at re-verify, verbatim: "bug #209 is still visibly wrong: the collect step reads "Pulling data · September 2026" while the start card and builder both say August, so the month is inconsistent within one flow. I'd log a new bug: "Data-pull/collect step shows September 2026; must read August 2026 to match the start card and builder." Fix that one spot and I'll accept."
