# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.7.8 — 2026-07-11

The Actual-Cost & Honest-Progress round (S111–115) — replace two guesses with
truth: measured per-mission cost, and a real activity signal in place of the
fake pulse. Everything is additive and display-only; no gate changes, and the
no-usage path stays byte-for-byte as before.

- **Per-engine usage-capture spike (S111).** Both engines expose what one cold
  `-p` worker actually spent via a minted `--session-id` + the CLI's own on-disk
  session artifact (claude transcript / copilot session-state `events.jsonl`),
  parsed after exit — stdout format untouched, so no `.worker.out` consumer
  breaks. Recorded in `skills/lcars-run/USAGE-CAPTURE-SPIKE.md` with fixtures.
- **Actual usage capture (S112).** Every cold-worker spawn appends its real
  usage to the mission's `usage.json` and emits a `worker_usage` event, cost
  computed by code from `pricing.json`. A missing artifact degrades to a
  recorded `"unavailable"` entry and never fails a stage; capture-off argv is
  byte-identical. New `run.sh usage <mission>` sums per-stage + total.
- **ACTUAL cost pill (S113).** At Verify/Done, mission and mission-log cards show
  an ACTUAL pill beside the estimate — same billing-unit rules — plus an
  "EST → ACTUAL" line in the detail modal, Verify dialog, and CLI verify
  summary. Absent/partial usage renders honestly; per-mission only (no roll-up).
- **Honest liveness (S114).** The make-believe CSS pulse becomes a real signal
  derived from the hang-guard's existing output watch — THINKING / WRITING
  OUTPUT / SUBSPACE QUIET Ns (+ hang-guard-watching) on the board and
  `lcars status --watch`. Removed on worker exit; the CLI tail is gated on a live
  driver lock so a crashed driver can't show a false "producing".
- **Collapsible activity sections (S115).** A big mission's detail feed groups
  into collapsible per-wave/per-stage bands — completed waves fold to one LCARS
  summary band with graphic stat chips (tickets / attempts / duration), a
  wave-health micro-bar, and a flagged badge; the active section stays open,
  everything expandable, nothing lost. Mission-log parents get the same idiom.
  Motion honors `prefers-reduced-motion`; cards and board shape untouched.
- **Docs.** First screenshots in the repo (viewscreen board, Mission Log,
  Re-Verify gate) added to the README and vision guides.

## 2026.7.7 — 2026-07-09

The Multi-Stack Breadth round (S104–106) — LCARS goes from JS/TS-and-Python to
*recognizing and running* compiled/managed toolchains. Every change generalizes
the harness and never loosens a gate: a new stack makes rejection MORE precise.

- **Per-stack classifier arms (S104).** The S96 table-driven red-gate classifier
  (`rg_signature`) gains Rust / Go / .NET / JVM arms. A `cargo` compile error,
  a Go "cannot find package", a C# `error CS####`, or a javac "cannot find
  symbol" is now named as the compile/resolution failure it is — while a genuine
  cargo/go assertion failure stays a valid red. Each signature is anchored to the
  way each toolchain prints its own diagnostic, so an assertion diff that merely
  quotes a compile phrase can't false-match. Every JS/Python arm is byte-identical.
- **Stack detection + per-stack defaults (S105).** `lcars init` (and `lcars
  update`) detect the repo's stack from its markers — Rust, Go, Python, JS/TS,
  .NET, JVM; several markers → `ambiguous(list)`; none → `unknown` — via a shared
  `detect_stack()`. They seed a MISSING-only `stack` key and a per-stack test
  command, warning (never guessing) on ambiguity. Customized values survive both
  re-init and update untouched.
- **Per-stack test isolation (S106).** The Implement red gate now isolates a
  ticket's fail-first tests for compiled runners whose tests live *inside* the
  crate/package and can't be pointed at an external dir. Keyed by the `stack`
  key: Rust stages an integration test scoped by `cargo test --test`; Go stages
  an in-package `_test.go` scoped by `go test -run` (leading-letter name — a
  spike-caught Go `_`-prefix file-invisibility false-green is avoided); JS/Python
  keep their `$LCARS_TESTS_DIR` path byte-for-byte. A file-absence probe enforces
  scope-was-honored per stack — green-on-nothing or unprovable scope BLOCKS loud,
  never a silent green. Immutability, ride-along-into-the-PR (at each stack's own
  convention), and staging cleanup on every exit are preserved.

Proven by a live dual-CLI capstone: two real fixture repos driven Align→Verify
hands-off with zero interventions — a Rust crate on Claude and a Go module on
Copilot — each reaching Verify on the first attempt with its fail-first test
riding into a real PR via the native isolation gate.

## 2026.7.6 — 2026-07-09

The declared-test-setup ↔ placement contract round (S131) — a one-off harness
fix from the 2026-07-09 groutwork demo failure, where a test-writer's declared
vitest config (`include: tests/**`) disagreed with the harness's S101 placement
(co-located under `src/`), collecting zero tests through three blind retries
and a terminal `over-broad-slice` misclassification.

- **The invitation states the placement contract.** The declared-setup block
  now names the DETECTED test convention (co-located / `__tests__` / `tests`)
  with a concrete example placed path — computed by the same
  `detect_test_convention`/`test_path_for` calls placement itself uses — and
  instructs that any authored runner config must collect that location (safest:
  don't narrow `include` at all).
- **Setup-aware zero-collect diagnostics.** When the self-smoke collects zero
  tests and a declared setup was applied this mission, the bounce quotes the
  runner's own `include:`/`filter:` lines and the placed in-tree test path and
  says they must agree — no more blind retries.
- **Honest terminal category.** That exhaustion signature now reads
  `test-infra-mismatch` (naming the package), not `over-broad-slice`, which
  remains for genuine no-coherent-red cases.

Red-gate semantics, S101 placement, and the evidence gate are untouched
(verified zero-diff). Proven by re-driving the failed demo mission hands-off
Align→Verify on BOTH engines (copilot + claude): setup invited/applied/
probe-verified, co-located placement collected, one attempt per role, zero
infra stalls (groutwork PRs #203/#205, torn down after the pass).

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
