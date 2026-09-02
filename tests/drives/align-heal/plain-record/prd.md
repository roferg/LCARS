# Recently viewed strip — internal docs site

## What this is

A horizontal row of small cards above the search box on the internal docs site,
showing the last five documents this person opened. Each card shows the title,
the section the document lives in, and how long ago they looked at it. Clicking
a card reopens that document. When the person has never opened anything, the
strip is not rendered at all — no empty box, no placeholder, no heading.

## Decisions already taken

These are settled. They are recorded here so nobody has to be asked again.

- **Where the history lives: the browser, not the server.** `localStorage`, keyed
  per origin. No new table, no new endpoint, no account association. The strip is
  a convenience; it is not worth a schema change or a privacy review.
- **It does not sync across devices, and that is fine.** Someone on a laptop and
  a phone sees two different strips. We are not building a reading history
  product.
- **Exactly five, most recent first.** Not configurable. The sixth push evicts
  the oldest.
- **"Opened" means the document page rendered.** Not a hover, not a search-result
  impression, not a preview. One entry per document — reopening a document moves
  it to the front rather than adding a duplicate.
- **Relative time, coarse.** "just now", "2h ago", "yesterday", "3d ago". No
  clock times, no seconds, no localisation work.
- **The relative time is computed when the strip renders, and does not tick.**
  No timer, no live-updating labels while the page sits open. It is recomputed
  on the next navigation, which is often enough for a convenience label.
- **Card click is a normal navigation.** Same-tab, same as clicking the document
  anywhere else on the site. No new tab, no modal preview, no middle-click
  special-casing beyond what the browser does for a normal link.
- **Long titles truncate with an ellipsis** at one line. No tooltip, no wrapping,
  no shrinking the font to fit.
- **The strip is keyboard reachable** in normal tab order, and each card is a
  real link. No custom arrow-key navigation, no roving tabindex.
- **A document that no longer exists is dropped silently** the next time the
  strip renders. No tombstone card, no error, no "this document was removed"
  state.
- **The strip is not part of search.** It sits above the search box and does not
  filter, reorder or otherwise interact with search results.
- **Mobile: the same strip, horizontally scrollable.** No separate layout, no
  collapse-into-a-menu behaviour.
- **Storage failures are non-events.** If `localStorage` is unavailable or throws
  (private windows, blocked site data), the strip simply does not render and the
  rest of the page behaves exactly as it does today. It never surfaces an error
  to the reader.

## Out of scope

Pinning or favouriting. Clearing the history from the UI. Any server-side
recording of what anyone read. Sharing a strip between people. Analytics on
what is in it.

## How we will know it works

Open three documents, and the three appear newest-first above the search box
with their sections and relative times. Reopen the middle one and it moves to
the front without duplicating. Open six and the oldest falls off. Clear site
data and the strip disappears entirely rather than rendering empty.
