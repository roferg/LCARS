# Mission: Shareable page links and a neighbours rail

**Type:** feature

**Goal:** Every published page carries a correct canonical URL, offers a "Copy
link" and a "Copy for Slack" control that copy that URL, and shows a rail of
neighbouring pages below its comments — all built at publish time, with the
preview server and the published viewer rendering from one shared renderer.

**Acceptance Criteria:**

- Every published page carries its real canonical URL in a `<link rel=canonical>`.
- The canonical URL is derived at publish time, never guessed in the browser.
- "Copy link" copies that derived canonical URL and nothing else.
- "Copy for Slack" copies the same URL wrapped in the Slack link form.
- Both controls write `text/plain` only, with no `text/html` alternative.
- A copy that fails tells the reader it failed; it never reports success.
- Below 400px viewport width "Copy link" renders icon-only, with a label for
   assistive technology.
- The confirmation toast reads exactly "Copied for Slack" for the Slack control.
- The toast dismisses itself after 3 seconds and is dismissible before that.
- The neighbours rail renders below the comments block, never above it.
- The rail shows at most six neighbours, ordered by publish date descending.
- A page with no neighbours renders no rail at all — not an empty one.
- Each rail entry links to a published page that exists at build time.
- The rail is built at publish time; it issues no client-side request.
- The preview server and the published viewer share ONE renderer module.
- A renderer change is visible in preview without a separate publish step.
- Keyboard focus order runs: copy controls, comments, then the rail.
- Every new control has an accessible name and a visible focus ring.
- No page's first contentful paint regresses by more than 50ms.
- The whole feature degrades to plain links with JavaScript disabled.

**Out of Scope:**

- Redesigning any existing viewer chrome.
- Any change to how comments themselves are stored or rendered.
- Server-side rendering of the rail on request.

**Open Questions:**

- None outstanding; the canonical-URL source was settled in Research.
