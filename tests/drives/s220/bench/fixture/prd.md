# Mission: Tide Board

**Type:** feature
**Goal:** A one-page tide board for Thornbury harbour, built to match the
drawing attached to this mission. A harbourmaster saves readings, publishes the
board, and locks the month's note.

**Acceptance Criteria:**
- The entry screen matches the drawing: a "Harbour" eyebrow, a "Tide Board"
  title, and a **Help** link in the **top-right** of the head.
- A **flush tab bar** runs edge to edge under the head — Readings / Sources /
  History — with the current tab underlined. There is no gap at either end.
- A **Save reading** button carries a small square icon, 16px inside a 34px
  control, with the label beside it on one line.
- A **Publish board** button is the blue primary action, 160px wide, with
  "Publish board" on **one line**.
- An **Export CSV** button sits beside Publish.
- A **stale-readings chip** reads "2 readings stale" and is **red** (#c0392b) —
  it is a warning, and it must not read as a healthy state.
- A **notice** under the buttons reads "Readings older than six hours are
  hidden from the public board automatically." It is 230px wide and, as drawn,
  it takes **two lines**. That is correct, not a defect.
- **Open the board** is the only way onto the second screen. There is no
  address for it: a person gets there by clicking.
- On the board screen, a note box and a **Lock the board** button. **Lock
  refuses while the note is blank**, and publishes once a note is written.

**Out of Scope:**
- Any server. The board is a static page.

**Attachments (the drawing):**
- attachments/attachment-01.html
