# Mission: Primary action buttons render with oversized icons and labels wrapped onto 2–3 lines

**Type:** bug
**Goal:** Every MBR primary action button renders like the drawing — a small icon inline to the left of (or after) a single-line label — on the start card, the collect step, the builder header and the preview header.
**Acceptance Criteria:**
- "Pull data & start" (Reviews start card) shows a small download icon inline with a one-line label, as in the drawing's start card
- "Continue to builder" (collect step) shows a one-line label with a small arrow, as in the drawing's collect step
- "Lock month" (builder header) shows a small padlock inline with a one-line label, as in the drawing's builder header
- "Back to builder" (Preview header) shows a small icon inline with a one-line label
- No icon spills past its button's edge at a 1440px-wide viewport
**Out of Scope:**
- Changing button colours, wording or behaviour
**Constraints:**
- Reported by the product owner (stand-in) comparing the build to the drawing. Their words: "Across the flow, every green/gold pill button collapses to a narrow width so its label wraps onto 2–3 lines and its icon jumps *above* the text instead of sitting inline beside it. The drawing shows single-line buttons with the icon to the left of the label. Instances: the start card's "Pull data & start" (icon-over-"Pull / data & / start" vs drawing's inline "⬇ Pull data & start"), the collect step's "Continue to builder" (vs drawing's single-line "Continue to builder →"), and the builder header's "Lock month" ("Lock / month" wrapped vs drawing's single-line "🔒 Lock month"). Same defect also on the Preview header's "Back to builder." This is a systemic button sizing/layout regression and it's visible on every screen."
