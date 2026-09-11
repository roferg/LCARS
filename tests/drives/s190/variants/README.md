# S190 owner-treatment variants — three looks, one markup

The shipped default is the **LCARS pill**: the avatar inset in a fully-rounded
left cap, the handle in uppercase Antonio on the colour block beside it (see the
`S190 — THE OWNER PILL` block in `web/static/board.css`). These two files are the
alternates the captain asked to see photographed from the real board before
choosing. **Neither is shipped**, and neither needs a single line of product
markup to work: `board.js` renders exactly one shape —
`.owner > .owner-av > img` plus `.owner-handle`, with `.owner.dead` when the
image fails and `.card.owned-by-other` when the mission is someone else's — and
all three treatments are nothing but different CSS over that shape. Choosing one
is therefore a **CSS block swap**: delete the default's block from `board.css`,
paste the chosen variant's rules in its place, and nothing else in LCARS moves.
That is what keeps the decision cheap and reversible, and it is why these live
here as *overrides* rather than as a fork of the stylesheet.

To photograph one, load the board as usual and inject the file over the shipped
sheet — the screenshot rig appends it as a second `<link>`/`<style>` after
`board.css`, so ordinary cascade order does the rest. Everything the variants
touch is deliberately reachable that way: they redefine only geometry and the two
local custom properties the default declares (`--owner-h`, `--owner-col`), and —
per ADR-007 — **no `--lcars-*` token is redefined by any of them**. Colour still
comes from the one shared source, `docs/lcars.css`.

The design problem all three are answering is the same one: **a GitHub avatar is
a photograph, and LCARS has no photographs.** The default *frames* the photo in a
solid cap; variant B *brackets* it with the frame's own elbow motif; variant C
*flattens* it into two-tone console art. Judge them on which one still looks like
a starship console with a stranger's face on it.
