# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.7.3 — 2026-07-06

Drift detection no longer false-positives after a merged PR. The `drift` verdict
("main moved without a version bump") now counts only real content commits since
the last `VERSION` touch (`git rev-list --count --no-merges`), so the PR **merge
commit** — which always trails the bump under a merge-commit workflow and never
touches `VERSION` — no longer trips drift after every merge. A genuine
unversioned content commit on `main` still drifts. No other behaviour changes.

## 2026.7.2 — 2026-07-06

Viewscreen update-banner UX polish. The version banner now drops clear of the
LCARS frame — a gap below the solid yellow top band — and its left edge lines up
with the board columns (the ALIGN column) instead of floating in from them. The
repo-stale copy names LCARS explicitly and shows both the current and target
version — *UPDATE LCARS IN THIS REPO — &lt;from&gt; → &lt;to&gt;* rather than the
ambiguous "REPO NEEDS UPDATE" (which read as the repo's own code being stale); an
unstamped repo that predates versioning says so instead of a from-version. The
board's `meta.version` block now carries the viewed repo's stamped version to
feed that from→to. The banner is now shown **only for actionable states** (source-behind or
repo-stale/predates, each with an update button); a drift-only state ("main
moved without a bump") is a maintainer signal surfaced in the CLI, not a
persistent board banner — so a successful update, which leaves at most drift,
clears the banner instead of stranding a confusing red bar. Pressing **ENGAGE
UPDATE** now gives
visible feedback: the band turns LCARS blue ("UPDATING LCARS…") while pull →
install → `lcars update` runs, then teal ("UPDATE COMPLETE") on success, before
the live SSE tick clears it — instead of only changing a small message string,
which read as "still running." No behavioural change to the check, the update
action, or `lcars release`.

## 2026.7.1 — 2026-07-05

Genesis release: the LCARS harness through the image-paste round. LCARS is a
reusable AI harness that drives a human idea all the way to a merged PR through
the full pipeline — Align → Research → Validate → Plan → Plan Review → Schedule
→ Implement → Verify — with each headless stage spawned as a cold, isolated
worker. It runs on either supported CLI (dual-CLI: `claude` and `copilot`),
surfaces every active Mission on the viewscreen Kanban board, lets the captain
log bugs against an in-flight Mission and drive them through mission-log
grounding (a read-only worker anchors each symptom to the parent Mission's
existing code before a fix is planned), and accepts pasted images as Mission
input threaded through the cold stages. Full history prior to 2026.7.1 lives in
git — see `git log`.
