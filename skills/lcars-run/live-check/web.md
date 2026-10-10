# Live check — a generated or deployed page

Run every item from the **detached** worktree with the **throwaway HOME** that
`autopilot.sh live-check <mission> --type web` prints.

A green suite is not evidence that a page renders. A DOM harness is a stub of a
browser: seven fix rounds on the modelled project were cured only when someone
opened real headless Chrome and **looked at the screenshot**.

---

### 1. Generate the page from real data you just created, not a fixture

Create a couple of records through the product's own front door (its CLI, its
API, its form), then run the real renderer the real way it is invoked. Read the
renderer's own output line.

**Evidence:** `live-check/01-render.txt` — the commands that created the data,
the render command, and its exact output.

**DEFECT:** a renderer that only works from a hand-written fixture; a row count
that does not match the records you created; a render that writes nowhere, or
writes outside the path the spec names; an invocation form that differs from the
one the workflow uses (check `workflow.md` item 4 as well).

```run:
{
  "argv": ["<renderer>", "<its-real-invocation-form>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/01-render.txt",
  "expect": {
    "dataCameFromTheProduct": "created through the real front door, no fixture",
    "rowCountMatches": "<the number of records you created>",
    "writesTo": "<the path the spec names>"
  }
}
```

---

### 2. Open it in real headless Chrome at desktop width, and look at the shot

Screenshot the generated file (`file://` is fine for a local page; the deployed
URL once there is one) at 1280×900, then **open the PNG and look at it**.

**Evidence:** `live-check/02-desktop.png`, plus a one-line caption in
`live-check/02-desktop.txt` saying what you see.

**DEFECT:** a blank or white page; content off-screen; overlapping or clipped
text; a visible template placeholder (`None`, `undefined`, `{{`); a stylesheet
or font that did not load; a console error in the capture log.

```run:
{
  "argv": ["<headless-chrome>", "--headless", "--disable-gpu", "--window-size=1280,900", "--screenshot=<evidence-dir>/02-desktop.png", "<page-url-or-file-url>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/02-desktop.png",
  "expect": {
    "shotIsNotBlank": true,
    "lookedAt": "a caption in 02-desktop.txt saying what is on the screen",
    "note": "producing the shot is not the check; looking at it is"
  }
}
```

---

### 3. Phone width — ask the browser for a **400 px viewport**, then shoot

The phone layout is a different layout, and it is where the faults the captain
finds by hand actually live. If you are driving the browser, ask it for the
width before you take the picture:

```json
[{"viewport": {"width": 400}}, {"screenshot": "phone"}]
```

`{"viewport": {"width": 400}}` lays the page out at 400 CSS px and leaves it
there, so the shot that follows is a 400 CSS px picture of a real 400 px layout.
`"height"` is optional (`{"viewport": {"width": 400, "height": 900}}`), and a
second step — `{"viewport": {"width": 1440}}` — takes you back to desktop
**inside the same look**, so you can shoot both widths without a second run.

**Prefer the viewport step over the iframe wrapper below for anything taken
through the browser**: it is the real layout rather than a picture of a wrapper
document, and the shot lands with its `{url, title, textSample, screen}`
readout beside it, which is what lets a row cite the picture and keep its
verdict instead of being graded "I could not check this".

**THE TRAP, and it is the whole reason this step exists.** A `--window-size` of
400 does **not** give you a 400 px layout. Headless Chrome **will not lay out
below 500 px** of window, so the flag on its own yields `window.innerWidth =
500` — measured — while the viewport step yields `400`. The flag sets the
WINDOW; the step sets the LAYOUT, through a different mechanism that does go
under that floor. A picture taken with the flag and captioned "phone" is a
500-pixel-wide picture of a layout no phone ever renders, and the bug you were
looking for is not in it.

**Evidence:** `live-check/03-phone.png`, plus a caption in
`live-check/03-phone.txt` — say in the caption what width the page reported, not
what you asked for.

**DEFECT:** horizontal scrolling the page did not ask for; a column that never
collapses; text under 12 px; a media query that never fires because it is keyed
below 400 px; controls too small or overlapping; anything hidden at phone width
that the spec says must be readable; **a header, label, caption or sibling that
stays visible when a media query hides the thing it describes.**

That last one is why you open the PNG. Compare every heading, header cell,
caption and legend against the element it names at 400 px: a surviving `<th>`
over an empty column, row borders that stop halfway across, a legend above a
control that is gone, a field label with no field. The usual cause is a rule
applied to the `<td>`s and not to the `<th>` — and **not one of the defects
above catches it**: the page scrolls fine, the column *did* collapse, the text
is big enough, the breakpoint is right, there is nothing to overlap, and the
spec never said the hidden thing had to be readable. Every bullet answers "no"
while the page is visibly broken on the screen in front of you.

**FALLBACK — the 400 px iframe wrapper, and ONLY for a look that is reaching
with `run:` instead of driving the browser.** Write a tiny local wrapper page
that embeds the real page in a 400 px wide iframe, screenshot the wrapper, and
look at the iframe's contents:

```html
<!doctype html><html><body style="margin:0;background:#888">
<iframe src="<page-url-or-file-url>" style="width:400px;height:900px;border:0"></iframe>
</body></html>
```

Keep the wrapper same-origin with the page (write it next to the page) so it can
be scrolled and measured. Know what you are giving up: the picture is of a
second document with its own grey gutter around it, every measurement has to be
read across a frame boundary, and the raw `chrome --screenshot=` below writes a
PNG with **no readout beside it** — so a row citing that picture is graded "I
could not check this" even when the picture is perfectly good. Use it when you
have no browser to drive, and say in the caption that it is the wrapper.

```run:
{
  "argv": ["<headless-chrome>", "--headless", "--disable-gpu", "--window-size=520,960", "--screenshot=<evidence-dir>/03-phone.png", "<400px-iframe-wrapper-url>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/03-phone.png",
  "expect": {
    "preferTheViewportStep": "{\"viewport\": {\"width\": 400}} then a screenshot — this wrapper is the fallback for a look with no browser to drive",
    "iframeWidth": "400px — headless Chrome will not lay out below 500 px directly, and --window-size=400 gives you 500",
    "noHorizontalScroll": true,
    "mediaQueryActuallyFires": "check the breakpoint value against 400 px",
    "labelSurvivesItsValue": "compare every heading, header cell, caption and legend against the element it names: a label still on screen while the media query hid the thing it describes is a DEFECT (a surviving <th> over an empty column, borders stopping halfway across a row)"
  }
}
```

---

### 4. Every element the spec names is in the page, with the id the spec gives it

Read the rendered HTML and find each element id, class or landmark the PRD or
the mockup names. Compare the attribute values, not just the text.

**Evidence:** `live-check/04-ids.txt` — each name the spec gives, and the line
of rendered HTML carrying it (or `ABSENT`).

**DEFECT:** a named id absent, renamed or duplicated; an id generated from a
field that can collide; a `<title>`, heading or label that does not match the
spec's words; an element present but empty.

```read:
{
  "path": "<rendered-page-path>",
  "evidence": "live-check/04-ids.txt",
  "expect": {
    "containsEveryNamedId": "<the ids the PRD or mockup names>",
    "idsAreUnique": true,
    "titleMatchesSpec": "<the title the spec gives>"
  }
}
```

---

### 5. The values on the page are the values in the store — follow the data

For one record you created in item 1, print the **stored** record and the
**rendered** row side by side, field by field. Choose values that are not the
defaults, so a silent fallback is visible.

**Evidence:** `live-check/05-page-vs-store.txt` — the stored JSON, the rendered
row, and a field-by-field comparison.

**DEFECT:** any field whose rendered value differs from the stored one; a
rendered **default** where the store holds a real value (the producer/consumer
field-name mismatch always looks like this); a value HTML-escaped into
nonsense, or not escaped at all; ordering that contradicts the spec.

```read:
{
  "path": "<rendered-page-path>",
  "evidence": "live-check/05-page-vs-store.txt",
  "expect": {
    "everyFieldMatchesTheStoredRecord": "<the stored record path>",
    "noSilentDefault": "a rendered default where the store has a value is a DEFECT",
    "chooseNonDefaultValues": true
  }
}
```

---

### 6. Read the **deployed artifact**, not "deploy succeeded"

Once a deploy has run, fetch what was actually published — the artifact zip, the
deployed URL, the served file — and read it. A green deploy job says the upload
worked; it says nothing about what was uploaded. On the modelled weekend the
deploy was green while the page was stale, and five stacked faults sat behind
that one line.

**Evidence:** `live-check/06-deployed-artifact.txt` — how you fetched it, and
the part of the content that proves it is the build you expect (a value only the
new build has).

**DEFECT:** a published artifact older than the build you just made; a
published page missing the change; a deploy that reported success while
publishing nothing; the artifact served from a different host or path than the
spec names.

```read:
{
  "path": "<deployed-artifact-or-url>",
  "evidence": "live-check/06-deployed-artifact.txt",
  "expect": {
    "containsAValueOnlyThisBuildHas": "<a string you introduced in this build>",
    "note": "\"deploy succeeded\" is not evidence — the artifact's content is"
  }
}
```

---

### 7. Re-verify after every fix round, with **different data**

After each fix round, re-run items 1–6 with **different data**: different record
text, a different count, a different non-default host, a different breakpoint
if the fix touched CSS. Take fresh shots — and look at them.

**Evidence:** `live-check/07-reverify-web-r2.png` (then `-r3` … one per round) and
`live-check/07-reverify-web-r2.txt` beside it.

**DEFECT:** a fix that holds for the first pass's data only; an item that
passed before and fails now; a page that renders one record correctly and two
incorrectly (or the reverse); a phone fix that broke desktop.

```run:
{
  "argv": ["<headless-chrome>", "--headless", "--disable-gpu", "--window-size=1280,900", "--screenshot=<evidence-dir>/07-reverify-web-r2.png", "<page-url-or-file-url>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home-3>"},
  "evidence": "live-check/07-reverify-web-r2.png",
  "expect": {
    "differentDataFromTheFirstPass": true,
    "bothWidthsReshot": "desktop and the 400 px viewport (item 3)",
    "everyEarlierItemReRun": "including the ones that passed"
  }
}
```

---

### 8. Break a page rule with the near miss

Verify each stated rule by **breaking it**, not only by satisfying it. Do not
leave "almost valid" to instinct — the near miss for a value the page has
already accepted is a **REARRANGEMENT of that value**, and the arrangements that
find faults are a short list. Work the table, and record what happened either
way.

**SEVEN NEAR MISSES THAT CATCH BUGS, and what each one is FOR.** Six rearrange
a value; the last rearranges the timing. Pick the rows that fit the rule in
front of you — running all seven blindly is not the ask.

| the near miss | what it is FOR |
| --- | --- |
| **a known-correct value, REARRANGED** — the same text typed back with the case flipped, or with two letters swapped | a field checked against what is already saved. Save it, then type the saved value back in a different arrangement and submit. **START HERE:** a check that only ever compared raw text accepts every exact-match attempt you can make. |
| **whitespace-only**, and a valid value with a space in front of it or behind it | a field that must not be blank. A field holding one space looks filled and is not, and trimming is usually the step nobody wrote. |
| **unicode look-alikes and combining forms** of a string the form accepted | a field matched as text. A Cyrillic а, a full-width character, and an é written as `e` plus a combining accent all read the same to the person at the keyboard. |
| **the numeric edges** — zero, a negative, one past the stated maximum, and the stated maximum itself | a quantity, a length, a date range, a page of results. The maximum ITSELF is the value most often wrong by one and the value most often never tried. Try the keyboard AND any stepper or slider. |
| **a second entry that NORMALISES onto one already saved** — not the same string, the same meaning after trimming, case-folding or unicode normalisation | a field that says a value must be unique, or must not already exist. Submitting the identical string twice proves only that the identical-string comparison works. |
| **the almost-right identifier** — a real name, id, slug or URL with one character changed | a lookup, a deep link, a route parameter. A page that quietly invents the missing thing, or renders empty, instead of showing a not-found is only visible this way. |
| **two requests in flight at once** — fire the second before the first has come back, instead of submitting one and then the other | any rule about something being saved, counted, kept unique, or shared between sessions. A server that reads a whole record, changes it and writes it back keeps only the last request's work, and **the giveaway is that nothing fails**: every response is a success and the page looks right. Afterwards ignore the responses and compare what is saved against the number of submissions that reported success. |

Say which rows you tried, with the exact value you entered, and say which rows
the rule in front of you made no sense for.

**Evidence:** `live-check/08-near-miss-web.txt` — the form or control, the nearly
valid input, its visible response, and whether it was turned away.

**DEFECT:** a refusal that never came is a fault; a refusal you never asked for
is simply unchecked. Where the page has rules of its own, reach an ending those
rules call a **LOSS** or a **REFUSAL**, not only the winning one.
