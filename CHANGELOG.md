# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.7.12 — 2026-07-27

The Stack Readiness round (S145–147) — **Ruby becomes a first-class stack, the
"no test command" state becomes legible and fixable in one click, and dotnet's
gate legs stop being able to green on nothing.** Two live missions were then
driven end to end on real repos to prove it, which surfaced a further set of
fixes carried in the same PR.

- **The Ruby arm (S145).** Ruby is a supported stack across four seams:
  `detect_stack` markers (Gemfile / *.gemspec / Rakefile / config.ru),
  bundler-aware rspec-vs-minitest seeding, anchored Ruby classifier phrasings,
  and native rspec isolation with ruby as its OWN case (`rust|go` was never
  widened). Ruby joins the zero-collected guard family on day one: a greenfield
  `LoadError` (`0 examples, 0 failures, 1 error occurred outside of examples`,
  exit 1) stays a REAL red rather than being swallowed as zero-collect, and the
  `10 examples` / `0 examples` substring hazard is word-boundary anchored.
- **A legible, one-click-fixable test story (S146).** One shared 4-state verdict
  (`readiness.sh --json|--line`, consumed by both CLI and daemon) surfaces on
  `init` / `update` / `status`, on a board banner, and in the File console as
  **⚡ FIX TEST SYSTEMS** — suggest-or-discover → set → probe in a single action,
  with typing a command as the manual override, never the primary path. CLI
  parity via `lcars update --fix-tests` / `--test-command` / `--probe-tests`.
  A greenfield repo gets a calm bootstrap voice; a broken one gets a repair
  voice; the two never blur. Filing is never blocked — readiness warns and
  offers the fix, because the gates are the enforcement point.
- **dotnet gate-leg hardening (S147).** C# repos now seed `dotnet test <proj>`
  (including the canonical layout where the test project sits below the repo
  root), stage specs INSIDE the discovered test project, and scope each leg by
  declared-class FQN. Observed on a real SDK, not assumed: a `--filter` matching
  nothing, an empty test project, and an all-skipped run **all exit 0** — three
  silent-green paths, all now INCONCLUSIVE. VSTest filters on class FQN, never
  filename, so filter terms are namespace-qualified and dot-terminated (`~` is a
  substring match). Sub-top-level markers count only when they are real test
  systems, so a vendored `.csproj` cannot hijack a js/python/rust repo.
- **Two structural guards, because the source scan was wrong four times.** The
  round found four generations of the same silent green — BOM-stripped
  namespaces, two classes on one line, multi-line strings desyncing brace depth,
  and `#if`-guarded types. Rather than patch a fifth, the design stopped
  trusting the scan: **GUARD 1 refuses to name what it cannot name** (an
  unqualified, generic, or nested type parks the staged set) and **GUARD 2**
  requires the tip leg to collect at least `count([Fact]) + count([Theory])`.
  GUARD 2's real bound is stated in-code: its floor shares a scanner with the
  filter it checks, which is precisely why known-unnameable shapes are refused
  outright instead of left to a count.
- **Proven live, on real repos.** Two missions were driven Align→Verify
  hands-off with live workers — a C# mission and a Ruby mission — each landing a
  correct PR on the first attempt with zero human gates. What they found is
  fixed here: `lcars file --engine` was **silently ignored** on the grill-first
  and `--complete` lanes (a mission pinned to copilot ran on billed claude);
  `flip-flop.json` recorded no leg **command**, so a captain could not tell from
  the artifact whether scoping was ever applied; the copilot model readout said
  Sonnet while every tier resolves to Opus — and priced it at Sonnet rates, so
  the copilot cost band moves up; and the gate-timeout message could tell a
  captain "the tests themselves are not implicated" about a genuinely hung suite.
- **Repos with a space in their path no longer fail their own gate.** The seeded
  test commands interpolated `${LCARS_TESTS_DIR}` unquoted, so a checkout at
  `~/My Projects/thing` word-split the scope and false-FAILED honest work —
  bouncing it to a fresh worker and then parking it. Quoted at the seeder, with
  a migration for already-initialised repos that rewrites only the exact shapes
  LCARS itself seeded (never a hand-written command).
- **A silent green closed, found while fixing the above.** Since Node ≥22,
  `node --test` re-interprets its positional as a GLOB rather than a path. When
  a glob metacharacter sits in the scope path, the leg collects SIBLING test
  files the ticket never touched — on BOTH legs — so a ticket whose staged test
  is a pure cheat, or which declares no tests at all, could be certified PROVEN
  on red supplied by a file outside its own `testFiles`. Reproduced end to end
  for `*`, `?` and a closed `[…]` class. The scope is now refused outright when
  it carries a glob metacharacter (`*` `?` `[` `{` `\`), rendering INCONCLUSIVE
  with the real cause named — the same refuse-what-you-cannot-scope principle as
  GUARD 1. Runner-specific (pytest, rspec and mocha take the path literally);
  jest's regex positional is ledgered as an unexplored neighbour.

## 2026.7.11 — 2026-07-26

The Deploy Main round (S138–139) — deploy **what's already merged**. Until now
the only way to run a repo's app from LCARS was per-mission (`lcars launch
<mission>`); reviewing "current" meant leaving LCARS to start the app by hand.
Now a **DEPLOY MAIN** control runs the local `main` HEAD — no fetch, no pull,
whatever is committed on the machine — through the exact same launch pipeline,
from both the CLI and a top-band button on the viewscreen.

- **`lcars launch --main [hint]` / `--main --stop` (S138).** A target-resolution
  seam on the existing launch pipeline (≈90% reuse): the local default branch
  (config `mainBranch` → `main` → `master`) is resolved by a **local**
  `rev-parse` (never a network fetch), checked out DETACHED into a disposable
  `.git/lcars/launch/@main` worktree, discovered + launched detached with a
  group-killable pgid — exactly as a mission launch. State lives under
  `.git/lcars/main/`; the record adds `branch` + a short `sha` on the main path
  only (the per-mission `launch.json` is byte-identical). `--main` is mutually
  exclusive with a mission id, and `@main` is reserved.
- **DEPLOY MAIN band control + daemon endpoints (S139).** A `▸ Deploy Main`
  button in the yellow band opens a small console (optional instructions) and
  deploys via the daemon; the band flips to `● MAIN LIVE` — short sha, clickable
  URL, and an integrated `■ STOP` — synced to every browser over SSE. New
  `POST /api/deploy/main` + `/stop` (read-only builds 403 both); an additive
  `meta.mainLaunch` payload rides the board only when a deploy exists (absent ⇒
  byte-identical). The deploy's pgid joins the daemon's shutdown group-kill.
- **Redeploy no longer orphans (both paths).** A relaunch while an app was still
  running used to spawn a new process and leak the old one (a pre-existing bug on
  the mission path too); the stop kill sequence is now applied before every
  relaunch, so the prior process is reaped first.
- **AI-session guard on the viewscreen.** Starting the board from inside a
  sandboxed Claude Code / Copilot session gives a half-working board (DEPLOY
  MAIN / launch can't reach the desktop). `viewscreen.sh` now refuses and prints
  a copy-paste `cd <repo> && lcars-viewscreen --open` to run in a real terminal
  (bypass with `LCARS_VIEWSCREEN_ALLOW_AI=1`).
- **Docs.** README quick-start now `cd`s into *your* project first (everything
  acts on the repo you're in — not the LCARS repo); the SSE fingerprint watches
  the main-deploy record so a deploy/stop pushes live to passive browsers.

## 2026.7.10 — 2026-07-25

The Park & Align round (S136–137) — a backlog-fast capture lane for `lcars
file`. An idea can now be **parked** with just an engine and the raw text: the
Mission and its GitHub issue are created instantly in a new pre-PRD **standby
state**, dropped in the Align column *awaiting alignment*, and the Align grill
runs later, on demand — from the CLI or one click on the board. Backlog fast;
grill when ready.

- **The parked state + verbs (S136).** `lcars file --park "<idea>" [--engine
  claude|copilot]` mints the mission dir + issue with `prdPending: true` (no
  grill, no PRD, no type, no estimate; labels `lcars:mission`+`lcars:align`
  only). `lcars file <id>` resumes: it runs the warm grill seeded from the
  captured `idea.md`, then `lcars file --complete <id> --prd <path>` validates
  the PRD, writes it, derives type/title, retitles + re-bodies the issue **in
  place** with a type label added, runs the estimator, and clears `prdPending`
  **last** (a failed issue update leaves the Mission parked and exits non-zero so
  a re-run retries — nothing partial). The result is byte-equivalent to a
  grill-first filing, `idea.md` the only extra artifact. Every "align ⇒ PRD
  exists" consumer is guarded: the driver/Research refuse a parked Mission with
  an actionable align hint (never a stack trace), the bare-`lcars` resolver
  offers parked Missions as a distinct *awaiting alignment* group but never
  auto-drives them, `lcars status` shows a ◇ standby row, and the comment-mirror
  does not drift. Grill-first `lcars file` is byte-identical.
- **Viewscreen quick-park (S137).** A **Park** affordance in the File console
  (engine + idea + optional pasted images) files instantly via `POST /api/park`;
  parked Missions render in the Align column with a themed *◇ STANDBY — AWAITING
  ALIGNMENT* badge and a **START ALIGNMENT** action (never a runnable Start). It
  opens the existing warm grill seeded from the parked idea, completing via
  `file.sh --complete <id>` so the card swaps standby → aligned in place on the
  SSE push (estimate pills appearing as usual). The board payload is additive
  (`prdPending` only when parked — old cards byte-identical); read-only builds
  403 the park + parked-align-start endpoints and hide the affordances. Full CLI
  parity — every button maps to a `lcars file` capability.
- **Viewscreen alignment UX (S137 follow-ups, from live captain testing).** The
  detail modal mirrors the card for a parked Mission (▹ START ALIGNMENT, never a
  runnable Start) and shows an *◇ STANDBY — AWAITING ALIGNMENT* panel instead of
  a placeholder PRD; **Mission Log is Verify-only** (it belongs at the demo-day
  checkpoint). START ALIGNMENT gains a persistent animated **scanning band** +
  a click-guard (no duplicate grill sessions), and closing an unrelated overlay
  mid-scan no longer aborts it. In the File console **Park is the default
  primary** (`◇ File to Backlog`), with *File & Begin Alignment* secondary.
- **Resume mid-grill + backgroundable finalize (in-session).** Closing the Align
  console mid-grill now **preserves** the warm session: the card + detail flip to
  **▹ RESUME ALIGN** (surfaced on both `/api/board` and `/api/mission/<id>` via an
  additive `alignResume` overlay, so it survives a page reload) and a new `GET
  /api/align/<sid>` reopens the interview at its current question. Closing during
  the closing-turn estimate shows a **◐ FINALIZING & COSTING…** band and the card
  swaps to aligned on its own when `file.sh --complete` finishes. In-memory only
  (a daemon restart drops an in-progress grill; the Mission simply stays parked).

## 2026.7.9 — 2026-07-24

The Unified TDD Implementer round (S132–135) — retire the adversarial Test
Writer / Implementer standoff for ONE cold TDD worker per ticket, with
correctness enforced by three deterministic, post-hoc proof-of-work gates
instead of a second agent's judgment. A gate rejection bounces to a fresh worker
(≤3 sessions) then parks awaiting-human — no worker can fail terminally on
quality grounds. Full replacement, no fallback flag; the standoff code is retired
to git history (`run.sh` −1,335 LOC).

- **Proof-of-work gates, standalone (S132).** `flip_flop_gate` (a ticket's
  new/changed tests must FAIL on the parent commit and PASS on the tip;
  zero-collected = inconclusive, never a pass), `declared_edits_guard`
  (undeclared edits to existing tests BLOCK; declared `{path,reason}` ride to
  Verify), a `result.json` v2 contract, and a quality floor — built and
  fixture-proven while the live path still ran the old standoff.
- **The path flip (S133).** `cmd_implement_ticket` drives ONE `implement-tdd`
  worker → the S132 gates → bounce-3-then-park. The Test Writer, red-gate
  choreography, `tests.sha256` lifecycle, and `reconcile_tests` are deleted; the
  `ticket_test_writer_failed → die` class no longer exists. Env-truth machinery
  (preflight/self-heal, declared-setup invitation, worktree isolation,
  full-suite gate, empty-worker budgets) is byte-preserved.
- **Surfaces + doctrine (S134).** Verify shows a per-ticket flip-flop verdict
  chip (PROVEN / N-A) + a "CONTRACT AMENDMENTS" block (declared edits verbatim)
  on both the CLI and the board from one shared shape; single-ticket missions
  surface their proof via a mission-level fallback. Board activity renders the
  gate events in LCARS voice with a worker-session marker on bounce and no role
  chip. `vision.md` / `CONTEXT.md` / `CLAUDE.md` / `README.md` + the rendered
  `docs/` HTML tell the unified doctrine. Display-only; pre-S133 missions render
  byte-identically.
- **Dual-CLI cutover capstone (S135).** Two real missions driven Align→Verify
  hands-off, one per engine (claude + copilot), through the unified path — every
  ticket flip-flop-proven, zero test-writer events, zero stage-stop dies. First
  real missions through S112 usage capture; validate + implement are the cost
  peaks.

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
