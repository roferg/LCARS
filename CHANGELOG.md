# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.7.5 — 2026-07-08

Docs catch-up for 2026.7.4: `lcars launch` (the deploy/run-app feature) and the
S111 test-setup robustness round are now documented in README.md and vision.md
— the launch command + Verify RUN/STOP flow, the runner preflight, the
evidence-gated declared test setup with probe-verified installs, the test
landscape, root-tree sovereignty, and the objective-residue testing rule — with
both rendered docs/ mirrors updated and their source-hash breadcrumbs
refreshed (docs-sync guard green).

## 2026.7.4 — 2026-07-08

The run-app + test-setup robustness round. Two features, one hardening sweep —
proven live by driving three groutwork missions Align→Verify (two fully
hands-off, including a runner-less package) plus four mission-log bugs across
both engines.

**`lcars launch` — deploy/run a mission's app for Verify.** A `launch`-role
cold worker DISCOVERS how to start the app in a disposable detached worktree
(dep provisioning included); the skill starts it detached, owns the process
group, and records launch.json for both the CLI and the viewscreen. RUN/STOP
land on the board's Verify dialogs (daemon-owned launches, per-mission
instances, target pinning, card badge). The discovery worker writes a PRIVATE
launch-discovery.json and launch.json is written only atomically — the mid-
launch RUN-button flash is gone.

**Test-setup robustness (S111).** The Test Writer can now survive contact with
any package's test reality:
- The red gate triages an un-launchable runner BEFORE the ignored-var verdict
  (rc-3 "cannot run tests here" escalates instead of burning retries), and a
  RUNNER PREFLIGHT probes the ticket's package before any worker spawn.
- EVIDENCE-GATED DECLARED SETUP: when the preflight proves a package cannot
  run tests while the repo tests elsewhere (sibling runner declarations count),
  the Test Writer is invited to declare the missing infra (ADD-only whitelist,
  package-manager installs only); the harness applies it PROBE-VERIFIED —
  exit codes are never trusted, pnpm's symlink/virtual-store no-ops are healed
  by a forced relink cycle at every gate door — and a verified green records
  the facts to `.git/lcars/test-landscape/`.
- ROOT-TREE SOVEREIGNTY: missions never touch the captain's checkout again —
  commits land via an ephemeral landing worktree under the replay mutex, the
  self-heal and reconcile no longer check out or detach the root, and PR-open
  pushes by ref. Switching branches mid-drive is safe by construction.
- Fail-loud isolation: no silent in-tree fallback when a worktree cut fails
  (stale registrations self-heal via prune+retry), and the post-commit gate
  names WHERE stray code landed (the wrong-tree suspect note).
- Worker comprehension: the resolution-failure hint now states a per-specifier
  VERDICT (module exists at <path> → fix the import / no match → must stub),
  greenfield tests place INSIDE the target package, and the Test Writer/Planner
  carry the objective-residue rule — never invent numeric proxies for taste;
  subjective qualities are the captain's Verify judgment.
- worktreeSetupCommand's node_modules find prunes .git (launch worktrees carry
  node_modules there), and the npx no-binary phrasing joined the env signatures.

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
