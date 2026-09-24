# S219 — decisions the stand-in captain made in the captain's name

Mission `lcars-20260911-001-8cb0` "MBR View Builder" (DX-Scorecard issue #192).
Every answer below was written by a **live Copilot turn** (`/opt/homebrew/bin/copilot -p`, model `claude-opus-4.8`, tools denied), given the grill question verbatim + the mission's `idea.md` + the concept (`attachment-02.md`) + the mock-up HTML (`attachment-01.html`, the design authority) + DX-Scorecard's `CONTEXT.md`, under these rules:
(i) the captain's two holodeck answers are LAW — lock is PER MONTH; ALL insights need text before locking;
(ii) open question → prefer what the mock-up shows; where it is silent, the smallest change to today's app;
(iii) 1–4 plain decisive sentences; (iv) never widen scope beyond the mock-up.
The driver (a Claude sub-agent) only relayed: it checked each answer against the two laws before sending it through the real board's Align console. **Every call here is overrulable by the captain.**
Full prompts/answers: `tests/drives/s219/prompts/turn-N.*`.

## Turn 1

**Question (verbatim, as the board showed it):**

> Question 1
> 
> Let's sharpen the core data model first. The mockup shows each KPI with a per-KPI status select over the five silhouettes (On track / Watch / Off track / Tracking / WIP). My recommendation: status is **set here in the builder** per KPI (seeded from the scorecard's current status on pull, but freely overridable), because an MBR is an editorial snapshot — you're making a judgement call about each metric for this month, not just mirroring live state. Do you want status set in the builder, or strictly inherited read-only from the scorecard?
> 
> Options offered:
> Set in the builder (seeded from scorecard, overridable)
> Inherited read-only from the scorecard
> Something else

**Copilot's answer (verbatim, as sent):**

> Set in the builder, seeded from the scorecard's current status on pull but freely overridable — the mockup draws an editable per-KPI status select, and an MBR is an editorial snapshot where I want to make the judgement call for the month rather than mirror live state.
> 

**Rests on:** rule (ii) — the mock-up draws an editable per-KPI status select; no conflict with either law

**Re-asked:** no

## Turn 2

**Question (verbatim, as the board showed it):**

> Question 2
> 
> Good — that also settles the "status inherited vs set in builder" open question. Next, the **"Carried" pill**. The mockup renders a purple "Carried" pill with a clock icon, but nobody's defined what actually earns it. My recommendation: a KPI is **Carried when the data pull produced no fresh value for it this month, so the builder carries forward the value/status from the previous published MBR** — i.e. it's a data-provenance fact ("this month reuses last month's number"), not a status judgement. That keeps it objective and computable at pull time, and it's distinct from an off-track or unresolved status (which the status marker already conveys). Does that match your intent, or do you mean something else by Carried — e.g. an explicit "carry this over" choice, or off-track items specifically?
> 
> Options offered:
> Carried = no fresh value this pull; value/status carried from last MBR (data-provenance)
> Carried = an explicit per-KPI "carry over" choice
> Carried = off-track / unresolved items specifically
> Something else

**Copilot's answer (verbatim, as sent):**

> Carried = no fresh value this pull; value/status carried from last MBR (data-provenance) — that's exactly right. It's an objective, computed-at-pull-time fact that a KPI reused last MBR's number because the pull returned nothing fresh, and keeping it separate from the status marker avoids overloading "off track" with a provenance meaning it shouldn't carry.
> 

**Rests on:** rule (ii) — mock-up draws the purple Carried pill but never says what earns it; took the interviewer's objective, smallest-change reading; no conflict with either law

**Re-asked:** no

## Turn 3

**Question (verbatim, as the board showed it):**

> Question 3
> 
> Now the **manual (unwired) KPI entry model** — this one has a real conflict to resolve. The mockup edits manual values inline (a plain input, no commit step), but the app's existing Update KPIs page commits a manual value with an explicit "Lock in value" button and an editable "As of" date, then shows Edit. My recommendation: **follow the mockup — inline editing, no per-value lock/asOf step** — because within the MBR builder the whole month is the unit of commitment (the per-month "Lock month" is the real gate), so a second per-value lock would be redundant ceremony; the "As of" date can default to the pull date. That said, this is a WHAT-IT-MUST-DO area where the brief flags the conflict, so I want your explicit call. Inline (mockup) or the Lock-in-value + As-of model (existing page)?
> 
> Options offered:
> Inline editing, no lock/asOf step (follow the mockup); As-of defaults to pull date
> Lock-in-value + editable As-of date (match existing Update KPIs page)
> Inline value, but keep an editable As-of field (hybrid)

**Copilot's answer (verbatim, as sent):**

> Inline editing, no lock/asOf step — follow the mockup. Within the builder the month is the unit of commitment, so the per-month "Lock month" is the real gate and a second per-value lock would be redundant ceremony. As-of defaults to the pull date.
> 

**Rests on:** rule (ii) — mock-up edits manual values inline — AND LAW 1 (lock is per month): the month lock is the only commit gate, so no per-value lock

**Re-asked:** no

## Turn 4

**Question (verbatim, as the board showed it):**

> Question 4
> 
> Let's nail down the three navigation actions the mockup draws but never defines: **"Preview", "View" (on a published month), and "Continue to builder"**. My recommendation: - **Continue to builder** — on the collection screen, becomes enabled once the pull finishes and takes you into the draft builder for that month. - **Preview** (builder toolbar) — opens a read-only rendering of the *current draft* exactly as it will look published, without locking it (a "what will this publish as" view you can back out of). - **View** (on a Published month) — opens that month's locked, published MBR read-only (same rendering as Preview, but of the immutable snapshot). So Preview and View share one read-only presentation component; the only difference is Preview shows the live draft and View shows a locked snapshot. Does that match what you intended for the three, or should any of them differ?
> 
> Options offered:
> Yes — Continue=enter builder; Preview=read-only render of current draft; View=read-only render of published snapshot
> Preview/View differ from that — let me clarify
> Something else

**Copilot's answer (verbatim, as sent):**

> Yes — Continue enters the draft builder for August once the pull finishes; Preview renders the current draft read-only exactly as it will publish (back out without locking); View opens a published month's locked snapshot in that same read-only rendering. Preview and View share one presentation component, differing only in draft-vs-snapshot source, and View reuses the existing LockedView path.
> 

**Rests on:** rule (ii) — the three buttons are drawn in the mock-up; took the interviewer's reading (smallest change: View reuses the app's existing LockedView)

**Re-asked:** no

## Turn 5

**Question (verbatim, as the board showed it):**

> Question 5
> 
> Let's clear the **theme toggle** — it shows up twice in the open questions and they're really the same point. The app already has a global theme toggle, and the mockup draws a theme-toggle button in the builder toolbar. My recommendation: **the builder does NOT carry its own toggle — it just follows the app's global theme**, and we drop the toolbar toggle the mockup shows. A second, builder-local toggle would either fight the global one or create a confusing per-page theme; one source of truth is cleaner. This is a spot where I'd deliberately diverge from the mockup's look because the brief/app reality overrides it. Follow global theme (no builder toggle), or do you want a builder-local toggle as drawn?
> 
> Options offered:
> Follow the global theme; drop the builder's own toggle
> Keep a builder-local theme toggle as the mockup draws it
> Something else

**Copilot's answer (verbatim, as sent):**

> Follow the global theme; drop the builder's own toggle — the app already has one global toggle and CONTEXT.md is explicit about one source of truth, so a builder-local toggle would only fight it or create a confusing per-page theme. The builder just follows the app's global theme, and we drop the toolbar toggle the mockup draws.
> 

**Rests on:** smallest change to today's app (one global theme toggle) — NOTE: this DEPARTS from the mock-up, which draws a builder toolbar toggle; the driver flagged it but did not re-ask because it contradicts neither law. Overrule candidate.

**Re-asked:** no

## Turn 6

**Question (verbatim, as the board showed it):**

> Question 6
> 
> Let's settle the **completion / "done" definition** — this drives the "Insights added — 9 of 14" bar and interacts with the lock rule. You already ruled every KPI needs insight text before the month can lock. My recommendation: **the completion meter counts a KPI as done when its insight textarea is non-empty** (matching the mockup's "Insights added" label), and status is NOT part of the meter — status is always seeded on pull so it's never really "missing", whereas insight is the human work the bar is tracking. That keeps the bar's meaning identical to the lock gate (bar hits 14 of 14 ⟺ month is lockable). Is insight-text the sole completion bar, or must status also be explicitly set for a KPI to count as done?
> 
> Options offered:
> Completion = non-empty insight only (matches the lock gate); status not counted
> Completion requires both a non-empty insight AND an explicitly-set status
> Something else

**Copilot's answer (verbatim, as sent):**

> Completion = non-empty insight only; status is not part of the meter. Status is seeded on the data pull so it's never genuinely missing, and the human work this bar tracks is the insight. Keeping it insight-only makes the meter mean exactly what the lock gate enforces — 14 of 14 ⟺ the month is lockable — which is the whole point of showing it.
> 

**Rests on:** LAW 2 (all insights need text before locking) — the meter is made identical to the lock gate; plus rule (ii), the mock-up labels it 'Insights added'

**Re-asked:** no

## Turn 7

**Question (verbatim, as the board showed it):**

> Question 7
> 
> Two related threads on **where each KPI's value, target, and delta-vs-last-MBR come from**. My recommendation: - **Value/target/delta arrive with the data pull** (as the mockup shows): on pull, each wired KPI collects its fresh value; target comes from the KPI's default view/config; delta is *computed* by the builder as this month's value minus the same KPI's value in the previous published MBR. - **When a manual value is edited inline, the delta recomputes automatically** (it's derived from the value + last MBR, so it should never be hand-typed), but **status does NOT auto-recompute** — status is the captain's editorial call (seeded on pull, overridable), consistent with our earlier ruling. So editing a value refreshes the delta but leaves status alone for the human to judge. Does that split match your intent — delta always computed, status always human?
> 
> Options offered:
> Yes — value/target/delta arrive on pull; editing a manual value recomputes delta only; status stays human
> Delta should also be manual / entered by hand
> Editing a value should also auto-recompute status
> Something else

**Copilot's answer (verbatim, as sent):**

> Yes — value/target/delta arrive on pull; editing a manual value recomputes delta only; status stays human. Delta is always derived (this month's value minus the same KPI's last published MBR value), so it's never hand-typed and must refresh the moment a manual value changes. Status is the captain's editorial judgment — seeded on pull but only ever changed by a human, consistent with our earlier ruling. Target comes from the KPI's config/default view.
> 

**Rests on:** rule (ii) — mock-up shows value/target/delta arriving with the pull; delta derived, status stays editorial (consistent with turn 1)

**Re-asked:** no

## Turn 8

**Question (verbatim, as the board showed it):**

> Question 8
> 
> There's a genuine contradiction to resolve here. The mockup's lock modal implies **a KPI with no insight still publishes** (goes out with value + status, no commentary) — but you already ruled **all insights need text before the month can lock**. Those can't both hold. My recommendation: **your ruling wins — the month cannot lock until every KPI has insight text, so a published month never contains an insight-less KPI.** The mockup's "publishes anyway" implication is the account being loose; we drop it. That makes the completion meter, the lock gate, and "what gets published" all say the same thing. Confirm your all-insights-required rule governs publish (no insight-less KPI ever ships), or did you intend a way to publish with some blank?
> 
> Options offered:
> My rule governs — no month locks/publishes with any blank insight
> Allow publishing with some insights blank (relax the lock rule)
> Something else

**Copilot's answer (verbatim, as sent):**

> My rule governs — no month locks or publishes with any blank insight. Every KPI must have insight text before the month can lock, so a published month never contains an insight-less KPI. The mockup's lock-modal copy about publishing blanks is the account being loose; drop it and make the summary reflect that empty insights block the lock. Completion meter, lock gate, and what ships all say the same thing.
> 

**Rests on:** LAW 2 (all insights need text) — overrides the mock-up's lock-dialog implication that an insight-less KPI still publishes

**Re-asked:** no

## Turn 9

**Question (verbatim, as the board showed it):**

> Question 9
> 
> Two closely-related persistence questions left — let's take **draft storage** first, then insight-save, then the re-pull rule. On the draft banner ("saved locally as you go", "last edited 2 min ago"): today the app persists the draft to `data/snapshots/<id>.json` and publishes via commit + PR. My recommendation: **keep that model — the draft is stored locally (on disk under the app's data dir), not synced to any server**, and the banner wording just reflects local autosave. Publishing stays the existing commit/PR-to-publish path; "Lock month" writes the immutable snapshot locally. That matches how the app works today and CONTEXT.md's local-dev framing. Is the draft local-only (as today), or do you want it synced to a backend?
> 
> Options offered:
> Local-only on disk (as today); publish via the existing commit/PR path
> Synced to a backend service
> Something else

**Copilot's answer (verbatim, as sent):**

> Local-only on disk, as today — the draft autosaves to `data/snapshots/<id>.json` via the existing dev-write bridge, and the banner wording just reflects that local autosave. There's no backend; that's a firm ADR-003 decision, and adding one would blow scope. "Lock month" writes the immutable snapshot locally, and publishing stays the existing commit/PR path.
> 

**Rests on:** smallest change to today's app (draft already persists locally to data/snapshots) + rule (iv) never widen scope (no backend); consistent with LAW 1 (the Lock month writes the snapshot)

**Re-asked:** no

## Turn 10

**Question (verbatim, as the board showed it):**

> Question 10
> 
> Down to the last two, both about save mechanics. First, **insight autosave granularity**: the mockup shows no explicit "Save" button but a "last edited 2 min ago" meta. My recommendation: **insights autosave on blur (and debounced while typing), no explicit save action** — the whole draft persists to `data/snapshots/<id>.json` through the dev-write bridge, and the "last edited" meta reflects the most recent autosave. This matches the mockup (no visible save control) and your local-autosave ruling. Autosave-on-blur/debounced, or do you want an explicit save action?
> 
> Options offered:
> Autosave on blur + debounced while typing; no explicit save control
> Explicit save action per insight
> Something else

**Copilot's answer (verbatim, as sent):**

> Autosave on blur plus debounced while typing, no explicit save control — the mockup shows no save button and a "last edited 2 min ago" meta, so autosave is what it depicts. The whole draft persists to `data/snapshots/<id>.json` via the existing dev-write bridge, and the meta reflects the most recent autosave.
> 

**Rests on:** rule (ii) — mock-up shows no save control and a 'last edited' meta; smallest change: reuse the existing dev-write bridge

**Re-asked:** no

## Turn 11

**Question (verbatim, as the board showed it):**

> Question 11
> 
> Last open item — the **re-pull rule**. The "Refresh all data" warning box says it only collects KPIs with automated instructions (11 of 14), leaving the 3 manual KPIs unchanged. My recommendation: **re-pull re-runs collection for automated KPIs only, and never overwrites manual values or any insight (manual or automated).** Concretely: automated values refresh (and their deltas recompute); manual-entered values stay put; every insight the captain has written is preserved across a re-pull. A KPI that comes back with no fresh value stays Carried. That matches the mockup's warning copy and protects the human's work. Is that the intended re-pull behaviour?
> 
> Options offered:
> Yes — re-pull refreshes automated values only; manual values and all insights untouched; no-fresh-value stays Carried
> Re-pull should also overwrite/clear something (let me specify)
> Something else

**Copilot's answer (verbatim, as sent):**

> Yes — re-pull refreshes automated values only, recomputing their deltas, while every manual value and every insight I've written stays exactly as it is; the warning box's "11 of 14, 3 manual untouched" copy is the rule. A KPI that comes back with no fresh value stays as it was, Carried included.
> 

**Rests on:** rule (ii) — the mock-up's Refresh-all warning copy states the rule (automated only, manual values untouched); preserving insights also protects LAW 2's work

**Re-asked:** no

## Turn 12 (closing question — RE-ASKED)

**Question (verbatim):**

> Question 12
> 
> Perfect — that closes every open question from the design session (all 14 resolved). The complete PRD is on the right. Anything else before I lock it and file the Mission?

(Copilot was also given the live PRD shown on the right of the console: `prompts/turn-12.live-prd.txt`.)

**Copilot's FIRST answer (NOT sent):**

> No, nothing else — lock it and file the Mission.
> 

**Why it was re-asked:** approving that PRD would contradict LAW 1 — the draft PRD still carried per-bucket locking (a per-bucket "Locked" badge and "Unlock" button, locked buckets read-only, an "Unlock this bucket?" dialog), and its open-questions block held 13 entries where the design session left 14. The re-ask note is `prompts/turn-12.reask-note.txt`.

**Copilot's SECOND answer (verbatim, as sent):**

> Not yet — it still breaks the per-month rule I set. Locking is month-only: drop the per-bucket "Locked" badge, the per-bucket "Unlock" button, the read-only-per-bucket lock rendering, and the "Unlock this bucket?" dialog — buckets render read-only only because the whole month is locked, and the only unlock is unlocking the month. Keep LAW 2 intact: the lock gate is every KPI having a non-empty insight, so also delete the leftover mockup line that a locked month renders individual buckets' unlock control. And recount the open-questions block — it lists 13 but the session left 14 unsettled; the second theme-toggle item (builder's own toggle vs the app's existing global toggle) is missing and must be carried as a RESOLVED entry. Fix those and then file it.
> 

**Rests on:** LAW 1 (lock is per month — month-only) and LAW 2 (kept intact); the 14-item carry rule in idea.md

**Re-asked:** YES (once)


## Phase C (04:48–05:25 PDT)

No escalation reached the captain during Number One's look, so the stand-in made **no** decisions and no `ask.sh` turn was spent. Number One filed 0 logs, so there was no fix round to escalate from.


## Phase D (05:17– PDT) — the stand-in decides what to log

Number One filed 0 logs. As the captain would after reading its report, the stand-in product owner (ONE live Copilot turn,
`/opt/homebrew/bin/copilot -p`, model claude-opus-4.8, tools limited to `view` on the image dir, all 12 images also passed
as `--attachment`) compared the build to the drawing. Images: `prompts/phase-d-standin/` (drawing-* = mock-up renders 52/55/69/70;
build-* = Number One's OWN look-1 shots mbr-start/mbr-collect/mbr-build/preview + crops 54/67/66/68). Cost: 39.21 AI credits (~$0.39), 2m10s.
The prompt did NOT name any defect — it asked for a comparison and a ruling on the month mismatch only.

**Prompt (verbatim):**

```
You are the product owner of the DX Scorecard's "MBR View Builder" (the Monthly Business Review builder). You drew a design for it (a mock-up, the "drawing"), an automated pipeline built it, and the build is now waiting for your review on its pull request. Your first officer (an AI reviewer) looked at the build and filed ZERO bugs.

The images are attached, and they are also in this directory: /Users/roganferguson/Projects/LCARS-number-one/tests/drives/s219/prompts/phase-d-standin
- drawing-1-start-page.png, drawing-1b-start-card-crop.png — your drawing: the start page ("Reviews") and its "Next up" card with the "Pull data & start" button.
- drawing-2-collect-step.png — your drawing: the data-pull step with the "Continue to builder" button.
- drawing-3-builder.png — your drawing: the builder, header with "Preview" and "Lock month".
- build-1-start-page.png, build-1b-start-card-crop.png — the BUILD's start page and its "Next up" card.
- build-2-collect-step.png, build-2b-continue-button-crop.png — the BUILD's data-pull step and its "Continue to builder" button.
- build-3-builder.png, build-3b-builder-header-crop.png — the BUILD's builder and its header ("Lock month").
- build-4-preview.png, build-4b-preview-header-crop.png — the BUILD's Preview page and its header ("Back to builder"). (Your drawing has no separate preview screen.)
- prd-resolved-decisions.txt — the decisions you already made (these are settled; do not re-litigate them). Also printed below.

Two of your decisions are LAW: (1) locking is per MONTH only — there is no per-bucket lock; (2) every KPI needs insight text before the month can lock. The build uses a different, smaller data set than the drawing (19 KPIs, all manual, no automated values) — differences that come only from that data are NOT bugs. Dates in the drawing are demo dates.

Your decisions (verbatim from the PRD):
- Draft and snapshot persistence is local-only on disk (`data/snapshots/<id>.json` via the existing dev-write bridge); no backend service.
- Reuse the existing LockedView rendering path for View and Preview.
- Locking is month-only; the lock gate is every KPI having a non-empty insight (LAW 2).

## Open questions from the design session

- RESOLVED with the captain: Does "lock" happen per-bucket, per-month, or both? — Per month only; there is no per-bucket lock.
- RESOLVED with the captain: Must every KPI have an insight before the month can be locked? — All insights need text before locking.
- RESOLVED with the captain: Status set in builder or inherited from the scorecard? — Set in the builder, seeded from the scorecard's current status on pull, freely overridable.
- RESOLVED with the captain: What makes a KPI "Carried"? — No fresh value this pull; value/status carried from the previous published MBR (data-provenance), kept separate from the status marker.
- RESOLVED with the captain: Manual value entry model (inline vs Lock-in-value + As-of)? — Inline editing, no lock/asOf step (follow the mockup); As-of defaults to the pull date.
- RESOLVED with the captain: What do "Preview", "View", and "Continue to builder" do? — Continue enters the draft builder once the pull finishes; Preview renders the current draft read-only as it will publish (no lock); View opens a published month's locked snapshot in that same read-only rendering (reuses the existing LockedView path); Preview and View share one presentation component.
- RESOLVED with the captain: The theme toggle in the toolbar flips dark/light — should the builder follow the app's global theme instead of having its own toggle? — Follow the app's global theme; drop the builder's own toggle.
- RESOLVED with the captain: The mockup adds a theme-toggle button to the builder toolbar, but the app already has a global theme toggle — should the builder carry its own, or just follow the global theme? — Just follow the global theme; the builder carries no toggle of its own (single source of truth per CONTEXT.md).
- RESOLVED with the captain: Is a non-empty insight the bar for "done", or must status also be set? — Completion = non-empty insight only; status is not part of the meter; the meter equals the lock gate.
- RESOLVED with the captain: Do value/target/delta arrive with the pull, and does editing a value recompute delta/status? — Value/target/delta arrive on pull; delta is always computed (this month minus last published MBR); editing a manual value recomputes delta only; status stays human; target from the KPI's config/default view.
- RESOLVED with the captain: Does an insight-less KPI still publish? — No; the month cannot lock or publish with any blank insight, so a published month never contains an insight-less KPI. The mockup's lock-modal copy about publishing blanks is dropped.
- RESOLVED with the captain: Is the draft stored locally only or synced? — Local-only on disk via the dev-write bridge to `data/snapshots/<id>.json`; no backend; publish via the existing commit/PR path.
- RESOLVED with the captain: Is an insight saved on blur/autosaved, or does it need an explicit save action? — Autosave on blur + debounced while typing; no explicit save control; the "last edited" meta reflects the latest autosave.
- RESOLVED with the captain: Is the re-pull rule "automatic only, manual + insights untouched"? — Yes; re-pull refreshes automated values only (recomputing their deltas); manual values and all insights are untouched; a KPI with no fresh value stays as it was (Carried included).

THE TASK: Compare the build to your drawing. List the bugs you would log against this mission — each as a one-paragraph bug report (what's wrong, where, what the drawing shows). Only real, visible differences; nothing you'd accept.

Also rule on one thing specifically: the build's start card says "Next up · August 2026", but pressing "Pull data & start" opens a review titled "September 2026" (the collect step and builder both say September 2026). Is that a bug you would log? Say yes or no and why, and if yes include it as one of your bug reports.

Answer format: a numbered list of bug reports (one paragraph each, starting with a short title in bold), then a line "MONTH MISMATCH RULING:" with your ruling. If you would log nothing, say "NO BUGS" and why.
```

**Copilot's answer (verbatim; the CLI's disabled-tools preamble stripped, raw in `prompts/phase-d-standin/answer.txt`):**

> I compared each build screen to the drawing. Here are the bugs I'd log.
> 
> 1. **Primary action buttons render broken (text wrapping + icon stacked).** Across the flow, every green/gold pill button collapses to a narrow width so its label wraps onto 2–3 lines and its icon jumps *above* the text instead of sitting inline beside it. The drawing shows single-line buttons with the icon to the left of the label. Instances: the start card's "Pull data & start" (build-1b: icon-over-"Pull / data & / start" vs drawing's inline "⬇ Pull data & start"), the collect step's "Continue to builder" (build-2b vs drawing-2's single-line "Continue to builder →"), and the builder header's "Lock month" (build-3b: "Lock / month" wrapped vs drawing-3's single-line "🔒 Lock month"). Same defect also on the Preview header's "Back to builder." This is a systemic button sizing/layout regression and it's visible on every screen.
> 
> 2. **"Last edited —" in the draft banner.** The builder's Draft strip reads "Last edited — · 3 of 5 buckets complete," showing an em dash where a timestamp belongs (drawing-3 shows "Last edited 2 min ago"). The draft clearly contains authored insight prose, so an autosave has occurred and the meta should reflect it — per the resolved decision, "last edited" reflects the latest autosave. A blank timestamp on a draft with content is a visible defect, not a demo-date difference.
> 
> 3. **Advertised next-up month doesn't match the review that opens.** The start card's "NEXT UP" is "August 2026" (correct: last published is July 2026), but pressing "Pull data & start" opens a review titled "September 2026" — the collect step and the builder header both say September 2026. The build skips a month between what it promises and what it creates. (Full ruling below.)
> 
> 4. **Preview button missing its eye icon (minor).** In the builder header the drawing's "Preview" carries an eye icon (build-3b/drawing-3); the build renders "Preview" as bare text. Low severity, but a visible fidelity gap from the drawing.
> 
> MONTH MISMATCH RULING: **Yes — bug.** This isn't the "demo dates" carve-out. The card and the review it launches live in the *same* build, and they disagree: the card advertises August 2026 and the started review is September 2026. With July 2026 as the last published month, "next up" is correctly August, so opening September skips a month and breaks the card→review contract. Logged as bug #3.

**What gets logged:** all four, as the stand-in named them. **Month mismatch ruling: YES, a bug** (its #3).

### Phase D, turn D2 (06:21) — the consolidated re-verify gate

The fix round raised ONE re-verify gate on the parent. The stand-in ruled on it: ONE live Copilot turn
(claude-opus-4.8, no tools, the Phase A context + the two laws prepended — full prompt `prompts/turn-D2.prompt.txt`;
the six BEFORE/AFTER pairs 121–126 attached).

**Question (verbatim):**

> (This is not the Align interviewer — the spec is long since written and the build is at review. LCARS is asking you, the product owner, to answer ONE re-verify gate. The attached images are BEFORE/AFTER pairs of the same spots at the same screen size.)
> 
> You logged four bugs against the MBR View Builder build after comparing it to your drawing. LCARS fixed them on the mission's branch and now asks ONE consolidated question:
> 
> "4 logged bugs resolved on lcars-20260911-001-8cb0 (MBR View Builder)'s branch — ready for your single re-verify. Re-inspect the fixes (they ride this Mission's PR — no per-bug PR), then ANSWER this gate to accept them (each logged bug is folded to Done) or send the Mission back."
> 
> What the rebuilt branch shows (attached pairs 121–126):
> 1. Buttons (#207): "Pull data & start", "Continue to builder", "Lock month", "Back to builder" now have a small inline icon and a one-line label, like your drawing. (pairs 121, 122, 123, 124)
> 2. "Last edited" (#208): the Draft banner now reads "Last edited just now" instead of "Last edited —". (pair 125)
> 3. Month mismatch (#209): PARTLY fixed. The start card says "Next up · August 2026"; after Pull, the builder now says "MBR builder · August 2026" and the saved draft is August — but the in-between data-pull step still says "Pulling data · September 2026". (pair 126)
> 4. Preview eye icon (#210): the builder's Preview button now shows the eye icon (pair 123). No separate code change was needed — the button-sizing fix made the existing icon visible.
> 
> Accepting marks all four logged bugs Done and pushes these fixes onto the mission's open pull request (it does NOT merge or approve the pull request). Not accepting leaves the gate open; the one remaining difference can be logged as a new bug against the mission. Sending the mission back re-opens its whole spec (Align).
> 
> Decide: ACCEPT, or DO NOT ACCEPT YET (and say what you would log), or SEND BACK. One line starting with your decision, then 1–3 sentences why.

**Copilot's answer (verbatim):**

> DO NOT ACCEPT YET — three of the four fixes are clean, but bug #209 is still visibly wrong: the collect step reads "Pulling data · September 2026" while the start card and builder both say August, so the month is inconsistent within one flow. I'd log a new bug: "Data-pull/collect step shows September 2026; must read August 2026 to match the start card and builder." Fix that one spot and I'll accept.

**Rests on:** what the after-shots show (pair 126: collect step still September). **Acted on:** the gate was left OPEN
(not accepted) and the stand-in's new bug was logged against the mission.

### Phase D, turn D3 (06:37) — the re-verify gate, again

Same shape as D2 (Phase A context + laws prepended; `prompts/turn-D3.prompt.txt`; pairs 139, 138, 121–125 attached).

**Question (verbatim):**

> (This is not the Align interviewer — the build is at review. LCARS is asking you, the product owner, to answer the re-verify gate again.)
> 
> After your "DO NOT ACCEPT YET", your new bug was logged (#211 "Data-pull (collect) step still shows September 2026 after pulling the August review") and fixed on the mission's branch. LCARS now asks:
> 
> "5 logged bugs resolved on lcars-20260911-001-8cb0 (MBR View Builder)'s branch — ready for your single re-verify. Re-inspect the fixes (they ride this Mission's PR — no per-bug PR), then ANSWER this gate to accept them (each logged bug is folded to Done) or send the Mission back."
> 
> Attached: pair 139 — the collect step BEFORE ("Pulling data · September 2026") and AFTER ("Pulling data · August 2026"); 138 — the builder after that pull ("MBR builder · August 2026"); and your earlier pairs 121–125 (buttons, Preview eye icon, "Last edited just now"), which are unchanged by this last fix.
> 
> Accepting marks all five logged bugs Done and pushes the fixes onto the mission's open pull request (it does NOT merge or approve the pull request). Decide: ACCEPT, DO NOT ACCEPT YET (say what), or SEND BACK. One line starting with your decision, then 1–2 sentences why.

**Copilot's answer (verbatim, as sent to the gate):**

> ACCEPT — pair 139 now shows the collect step as "Pulling data · August 2026" matching the "Next up · August 2026" start card and the builder header (138 "MBR builder · August 2026"), so the month is consistent across start → collect → builder, and pairs 121–125 confirm the earlier fixes are unchanged.

**Acted on:** answered through the product — `lcars answer respond --mission lcars-20260911-001-8cb0 --answer "<the answer above>"`.
