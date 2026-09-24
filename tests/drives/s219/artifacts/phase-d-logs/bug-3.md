# Mission: "Next up · August 2026" opens a September 2026 review

**Type:** bug
**Goal:** Pressing "Pull data & start" on the start card opens the review for the month the card advertises as next up (the month after the last published MBR).
**Acceptance Criteria:**
- With July 2026 as the last published month, the start card says "Next up · August 2026" and pressing "Pull data & start" opens "Pulling data · August 2026" and then "MBR builder · August 2026"
- The start card's next-up month and the month of the review it creates are always the same month
**Out of Scope:**
- Changing how the last published month is determined
**Constraints:**
- Reported by the product owner (stand-in). Their words: "The start card's "NEXT UP" is "August 2026" (correct: last published is July 2026), but pressing "Pull data & start" opens a review titled "September 2026" — the collect step and the builder header both say September 2026. The build skips a month between what it promises and what it creates." Ruling: "Yes — bug. This isn't the "demo dates" carve-out. The card and the review it launches live in the same build, and they disagree ... With July 2026 as the last published month, "next up" is correctly August, so opening September skips a month and breaks the card→review contract."
