# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.8.2 — 2026-08-03

**"View on GitHub" now opens the forge the repo is actually on.** Captain-
reported: earlier work taught the harness to talk to GitHub Enterprise, so stage
comments and mission-log issues land correctly on a `*.ghe.com` host — but the
viewscreen's links still string-concatenated `https://github.com/`, so every
click landed on the wrong forge and had to be hand-edited.

- The two link sites (`board.js`, the card's linked-ref badge and the mission
  detail's View-on-GitHub) now build their URL through one helper fed by the
  repo's real forge host. The host comes from the SINGLE existing
  implementation — `host-adapter.sh`'s `gh_hostname`, exposed as a new `gh-host`
  op — rather than a second copy in Python. That was deliberate: this release
  also ships alongside a ledgered bug caused by exactly that pattern (the
  zero-collect phrase list is duplicated between `lcars-init` and `run.sh` and
  has since drifted, leaving one surface honest and the other blind).
- **Resolved ONCE per daemon lifetime**, warmed at startup and memoized —
  including the empty answer, or every github.com daemon would shell out
  forever. Measured from outside with a logging `git` shim: a board left open
  60s makes exactly **1** `git remote get-url` call on the branch vs 0 on main,
  with the pre-existing per-tick repo-name lookup unchanged at 17 either way.
- **github.com users pay nothing.** The board payload is byte-identical to the
  previous release — verified by running identical fixtures through both
  daemons and comparing bytes (4683 for a github.com repo, 4682 for a repo with
  no remote), with `meta` carrying no new key at all.
- Generic host resolution, not a `.ghe.com` special case: a self-hosted GHES on
  `github.internal.acme.com` works, as do scp-style `git@host:owner/repo`,
  `ssh://` with a port, `git://`, uppercase hosts, and trailing slashes. A repo
  with no origin — or no git at all — still renders today's links rather than a
  broken one.
- Fixed alongside, because it made the first link unmeasurable: the logged-bug
  badge rendered as a dead `<span>` on FIRST paint and only became a link if a
  later re-render happened along, because the repo identity was captured at the
  END of `render()`, after the cards were built.

Proven in real headed Chrome against a real daemon reading a real git remote,
reading the anchor's RESOLVED href — plus four red controls, including one that
silences the daemon while leaving the front end perfect, which is the failure no
Node DOM harness can see. Rig committed at `tests/drives/browser/ghe-links.sh`.

**Known and NOT fixed in this release** (found by the session's own tester,
shipped knowingly):

- **The GitHub adapter still links to github.com.** The fix landed on the local
  adapter only; `--adapter github` / `LCARS_SERVE_ADAPTER=github` — the
  view-only mode the viewscreen SKILL.md advertises as the hosted board — never
  gained the host. Not the default path, but it is exactly where an enterprise
  user would point a shared board.
- **A stale host survives `git remote set-url` on a running daemon.** The repo
  name is re-read every poll while the host is cached for the daemon's life, so
  changing the remote under an open board yields a HYBRID url — new repo, old
  host — pointing at neither. Restarting the daemon clears it. Fix is to cache
  both or neither.

## 2026.8.1 — 2026-08-02

The **quality-of-life round** (sessions 158–167): base freshness, backgroundable
bug filing from the board, and a capstone that drove the whole round for real.
Ten sessions on one branch, closed by a live drive on a real private GitHub repo
with live workers — which is how most of what follows was found rather than
assumed.

- **A Mission filed from a stale checkout now reasons about the fresh tree.**
  `ensure_base_current()` brings the Mission's base branch up to date before
  filing and records an honest freshness verdict; a re-check runs again at drive
  time. It NEVER blocks filing, never touches a dirty tree, and never resets,
  force-updates, stashes or checks out anything — a mission branch is left
  exactly as it is (`⊘ base … is a Mission branch`). Proven on a fixture whose
  local `main` was one commit behind the commit that added the file the Mission
  targeted: the reflog shows one ref move and the mission branch parented on the
  fresh tip.

- **The freshness verdict reached the surface Missions are actually filed from.**
  The guard printed to stdout, which a captain filing from the board never sees.
  A card badge, a detail line and a File-console pre-flight now carry it, backed
  by a read-only `GET /api/base-freshness` that measures without moving a ref.
  Gated on the record's CARRIED `loud` flag, never on a verdict allowlist —
  `unknown` is both the silent no-remote case and the loud unreachable one, so an
  allowlist provably cannot tell them apart. **Capstone amendment:** a base that
  is behind but fast-forwards cleanly is no longer silent — `loud` now picks the
  TREATMENT rather than deciding whether to speak, so that case gets one calm,
  muted line ("1 commit behind … filing brings it up to date first") while the
  loud cases keep their warning treatment byte-identically.

- **The front-half Stages read the Mission's code structurally, not by request.**
  Research, Validate, Plan and Plan Review resolved paths against the captain's
  ambient checkout; the "read the Mission's branch" pin was a sentence in a
  prompt, and a live worker was MEASURED ignoring it. Each now runs in a DETACHED
  worktree at the Mission's branch sha. **A prose pin is not a mechanism.**

- **Filing bugs from the board no longer dies with the dialog.** The Mission Log
  console's File & Cost is backgroundable: the daemon owns the filing session, the
  parent card carries a ◐ FILING & COSTING band, and closing the window mid-flight
  leaves the work running. A "Fix Filed Bugs" control then opens the review and
  dispatches the SAME endpoint the Go button always did — no second filing path,
  and BUG-059's hold stands (filing never auto-proceeds into running).

- **A folded bug's GitHub issue now CLOSES.** Previously a folded child was
  relabelled `lcars:done` and left open — the shape seen on DX-Scorecard PR #77,
  where seven children stayed open. The cure keys off the fold's EXIT STATUS, not
  the refusal wording. Verified on real GitHub issues, on the harder REFUSAL path
  (a bug correctly found not to reproduce still closes out).

- **A deploy is no longer blind to its own writes.** Every `lcars launch` checkout
  was cut inside the repo's `.git/`, which Vite's default `server.watch.ignored`
  (`**/.git/**`) makes chokidar ignore wholesale: the dev server booted, served
  pages, and never saw another change. The checkout now lands beside the repo,
  keyed by canonical path; mission state stays under `.git/lcars`. Judged on the
  RUNNING SERVER, never the path — outside `.git/` the served glob went 2→3 in
  45ms; under it, still 2 at 60s.

- **The Research column is no longer always empty.** `lcars:research` was applied
  in exactly ONE place — inside the >20-question escalation branch — so a Mission
  actually running Research still read `lcars:align`. The cause is structural:
  `research` is the only `lcars:*` stage label with no `set_stage`, so the pointer
  stays `align` for the whole Stage. Fixed label-only; grounding-mode Research on
  logged bugs gets it too.

- **`lcars init` no longer certifies a zero-test repo as online.** `node --test`
  with no test files exits 0 printing `tests 0`, and init reported "TEST SYSTEMS
  ONLINE — verified by a live run". The zero-collect guard knew six runners'
  phrasings but not Node's own. The new pattern is anchored at both ends so a
  healthy run's `tests 12`, `fail 0` and `suites 0` cannot match it.

- **The "Child bug mission" legend swatch paints.** `docs/lcars.css` never defined
  `--lcars-pink`, and this was the one use site without the `#ff66aa` fallback, so
  the declaration was invalid at computed-value time — alpha 0 on a perfect 12×12
  box with element, class, style attribute, CSS rule and layout all present.

Rigs committed rather than discarded, under `tests/drives/`: a real-Chrome board
smoke, the base-freshness quiet-line check, the legend-swatch check (each with red
controls that genuinely fail when the feature is removed), and a deploy-watcher
drive that keeps a deliberate under-`.git/` RED CONTROL.

## 2026.7.20 — 2026-07-29

Three defects found on ONE real mission — `lcars-20260729-001`, a 12-ticket
DX-Scorecard feature that ran 2h14m unattended and shipped with 4 logged bug
fixes. Each defect sat at a different seam, and each was invisible: none produced
an error, and two were actively reassuring while broken.

- **The Align console blanked mid-interview.** The captain answered question one
  and the grill repainted its "What would you like to refine?" fallback over an
  empty PRD panel, with no error and no way back in. The worker was fine — both
  turns emitted well-formed JSON. The daemon misread the second one. The grill's
  tools-denied posture (`--available-tools=`) no longer holds on a copilot
  continuation turn: the opening turn made 0 tool calls and parsed cleanly, the
  turn after the answer made 10 builtin `view` calls, so its stdout carried tool
  activity ahead of the real turn. `_extract_json` took the FIRST balanced `{...}`
  that parsed — a tool ARGUMENT object, `{"path":"…"}`, perfectly valid JSON —
  producing a turn with no question and no PRD. It now collects every parseable
  top-level object and returns the LAST one carrying turn keys: the turn is the
  worker's final message, and tool noise is never turn-shaped. `_align_turn`
  additionally refuses to ship a question it cannot render, raising 502 BEFORE
  mutating the session so the console shows an error with Submit re-armed and the
  previous question, transcript and PRD all survive.

- **Approving a parent stranded its logged bug children.** A logged bug folds its
  fix onto the parent's branch and gets NO PR of its own, so the only thing that
  can mark it Done is the fold — reachable from exactly one place: accepting the
  parent's consolidated re-verify gate. Merging the parent destroyed that route.
  approve's merge-success block deletes `awaitingHuman`/`pendingQuestion` (the
  gate), then `set_stage done` puts the parent outside resolve-logs' reach
  entirely (its `active_table` skips done missions), while approve refuses a child
  directly for having no PR. Review the PR, merge it, and four bug cards are
  orphaned at verify with their fixes already in `main` — with no way back. approve
  now folds them as part of the merge, before the parent goes done, dispatching per
  child to `resolve-logs complete --bug` so the fold keeps one home. Best-effort
  and never fatal (the merge has landed; a refusal must not fail a shipped parent),
  and a still-mid-flight child is named too — merging the parent leaves its fix out
  of the PR.

- **The fold's premise check was inverted — and had never run.** 2026.7.18 taught
  `fold_one_child` to verify a bug's fix is actually on the parent branch before
  calling it Done, closing the class where cards read Done while the code had
  vanished. `child_fix_on_branch` piped `git log` into `grep -q`; the script runs
  under `set -o pipefail`, and `grep -q` exits the instant it matches, so git dies
  of SIGPIPE and pipefail returns 141. The result was inverted on the ONE case that
  matters: a fix that IS on the branch reported "not on branch", so every
  legitimate fold was REFUSED with a false alarm about missing code. It shipped
  undetected because nothing in the suite ever planted a `.commit-sha` —
  `child_recorded_a_commit` was always false, the check never ran, and every
  existing fold test passed it vacuously. Now capture-then-match with a
  here-string: no pipe, no SIGPIPE, same subjects-only fixed-string semantics.
  Behaviour 14 gives it its first real coverage, in both directions.

- **Both fold directions are now proven together.** The two fold defects are exact
  inverses — 2026-07-28 was green cards with no code, 2026-07-29 was merged code
  with stranded cards — so they are tested as a pair and driven as a pair: a
  stand-in-captain proof drive runs a real mission and a real logged bug end to
  end on real workers, with a local bare `origin` whose `pr-merge` genuinely
  fast-forwards `main`, then asserts BOTH that the bug's commit is on merged main
  AND that its card reads done.

- **Known, unfixed:** copilot's grill no longer honours `--available-tools=`
  (builtin tools execute; custom MCP servers boot every turn, ~13s each), and the
  cost estimator undercalled a 12-ticket mission ~6× ($4.86–$25.47 estimated vs
  $150.07 actual). An automated drive against a fresh repo also blocks on the
  interactive `RUN lcars update? [y/N]` prompt until its config carries an
  `lcarsVersion` stamp.

## 2026.7.19 — 2026-07-29

Wave isolation and provable repairs (S156–S157). Two defects from one dead
mission: `lcars-20260727-001` landed all 12 tickets, then burned 8 worker
sessions, 2 self-heal rounds, 3 flip-flop rejections and 8 gate bounces on ONE
ticket and never reached Verify. It was ended by hand.

### Infrastructure tickets get their own wave (S156)

Wave 1 held both the Vite/React/TS scaffold and a docs ticket. Siblings in a
wave build against the same frozen base, blind to each other, so the docs test
resolved the repo root with `fileURLToPath(new URL('..', import.meta.url))` —
correct against a repo with no Vite config. The scaffold then landed
`vite.config.ts`, Vite rewrote `import.meta.url` to a served URL, and the file
threw at import. Its 13 tests never ran again, and nothing noticed for eleven
more tickets.

A ticket that establishes shared infrastructure now schedules into its own wave.
Classification is **declared**, not guessed: a per-ticket
`establishesSharedInfrastructure` flag that Plan sets and Plan Review audits both
ways. The text heuristic that preceded it was demoted to a narrow backstop after
the tester reworded its own corpus preserving meaning and recall fell 14/14 to
5/14 — proof it was matching sentences, not concepts. Undeclared, a plan is still
a coin flip on phrasing, so Plan Review is load-bearing here; that limit is
recorded as a test pair rather than hidden.

### An honest test repair can finally be certified (S157)

Every worker must prove its work: its test is run against the code as it was
before, and must fail there. Correct for a NEW test — and wrong for REPAIRING a
pre-existing broken one, because the harness ran the worker's *fixed* file
against parent code, where it passed. Red-on-parent was unprovable by
construction, so a correct fix was rejected forever. That is what killed the
mission above: the reconcile worker diagnosed the bug accurately, fixed it
minimally, declared the edit honestly, and was rejected three times.

A test file that already existed at the parent is now judged against the
**parent's own committed copy**. Red-on-parent then means the file was genuinely
broken before. New files keep byte-identical staged behaviour; any non-test path
in the diff routes the ticket to the normal gate and names the paths that did it,
so a worker is never told its broken test "passes on the parent" with no
explanation. The acceptance bar is unmoved: weakening a test that PASSED on the
parent still yields no red and still fails.

### Self-heal names the ticket that authored the failing suite

It named the last ticket to land. In the live incident that was t-011, for a
break whose test file t-012 wrote — so a worker was handed a brief for a ticket
unrelated to the failure. It now names the **authoring** ticket, re-picked each
self-heal round from that round's failing set, and says plainly when ownership
cannot be resolved instead of guessing. The old copy asserting "a LATER ticket's
produced code REGRESSED its locked contract" is gone: the gate never established
that, and the confident wrong premise cost real sessions.

### The anti-gutting guard was retired, deliberately

Allowing a worker to edit an already-broken test opens a door: delete the failing
test instead of fixing it, and the evidence looks identical. Four successive
guards were built to close it — file existence, line counts, regex name sets, a
character-level lexer — and five adversarial review rounds beat each one at a new
token: `test.skip`, commented-out padding, apostrophes truncating names, names
read out of string literals, `describe.skip`, multi-line templates, ruby
`=begin`, a regex literal containing `/*`, `it.each` tables. Round five then
caught the guard **false-failing an honest repair** that dropped a dead
`require` — re-creating the very loop this work exists to end.

So the ~1,000 lines of source parsing were deleted for one source-blind check —
the runner may not execute fewer tests than before — and repairs are made
**visible** instead: Verify lists every repaired file for human review, and the
declared-edits contract already forces a reason for each. The remaining check is
called a screen, not a proof, everywhere it is described, and its blind spots are
stated plainly: when the parent's copy is dead at import it executes nothing, so
the comparison proves nothing there. Five residuals are each pinned as a live
assertion, so closing one is a deliberate visible change.

### The defect no scoped test could find

Verification by live drive, with real workers, found what five rounds of fixtures
could not. `lcars init` seeds a `worktreeSetupCommand` that SYMLINKS
`node_modules` into each ticket worktree — and `node_modules/`, the near-universal
gitignore pattern, is directory-only, so it does not match a symlink:

```sh
printf 'node_modules/\n' > .gitignore; ln -s /tmp node_modules
git ls-files --others --exclude-standard   # -> node_modules
```

The gate counted the harness's own provisioning artifacts as worker-authored
non-test paths, declared the diff mixed, and refused the repair path — on a ticket
whose real diff was one line in one test file. The repair path was effectively
unreachable on any standard JS repo. In the drive it only recovered because the
worker diagnosed the harness bug and hand-edited `.git/info/exclude`. An untracked
symlink is now recognised as provisioning, not authorship, at the point
eligibility is decided; the declared-edits guard and quality floor still see the
raw diff, so a worker that genuinely commits a dependency tree stays visible.

### Never self-heal an environment fault

Merging `main` mid-round (2026.7.16–2026.7.18) put this work in the same function
as the new stale-dependency classifier. Resolved by ordering — the environment
diagnosis returns before attribution, so a toolchain fault names no ticket — and
pinning that seam then exposed a further gap: self-heal still fell back to the
last-built ticket and spent worker sessions trying to edit code for a broken
toolchain. It now skips entirely on an environment fault and parks the human with
an actionable diagnosis naming `lcars update`. The board grew matching copy: a
stale toolchain is not a decision the operator is being asked to make.

### Proven live

Three drives with real workers, on top of the scoped suites: an honest repair of
a collection-red pre-existing test certified on the **first attempt**; a genuine
cross-ticket break attributed to the **authoring** ticket while the reconcile
worker kept the innocent change intact; and an ordinary feature mission running
Align to Verify hands-off, three tickets, each green on its first session.

### Also

`lcars-run.test.sh` was measured rather than assumed: it is **effectively 100%
stubbed and costs nothing to run** — 52 minutes of wall clock but ~3.5 minutes of
CPU, the rest hang-guard polling. Its 248 failures are byte-identical on this
branch and on `main`, all stale fixtures predating the S132–135 unified worker.
The BUG-029 self-heal assertions are unreachable on their own fixture, which
writes `tests.sha256` where the code reads `proof-tests.sha256`.

## 2026.7.18 — 2026-07-28

The reconcile re-entry no longer destroys committed work — **the worst defect
found so far, because it deleted verified code and reported success.**

BUG-077 made a reconcile re-entry reset the local mission branch to the remote
PR head before re-merging, so a killed/retried reconcile could not leave the tip
diverged and jam the push:

```sh
git branch -f "$BRANCH" "origin/$BRANCH"
```

Right when the local-only commits are a dead attempt's merge commit. Catastrophic
when they are real work — and **mission-log bug fixes are exactly that work.** A
logged bug never opens its own PR: its fix is cherry-picked onto the *parent's*
branch and rides the parent's PR, so until the parent next pushes it exists only
locally.

Observed live (DX-Scorecard, 2026-07-28). Three gate-verified bug fixes were
cherry-picked onto the parent branch; 109 seconds after the last one, the parent
re-entered reconcile because main had moved 8 commits ahead:

```
b75400b (bug 005)   1785267868
a2509a8 (bug 006)   1785268473
cddf9b4 (bug 007)   1785269867
RESET -> 091fbb7    1785269976
```

The reset moved the branch back to the remote head — precisely the chain's base.
All three commits became unreachable in one command. The reconcile then re-tested
the *parent's* ticket, went green (the bug fixes' own tests had been discarded
along with their code, so nothing was left to fail), and the PR merged carrying
none of it. No error was raised anywhere; the loss was found days later, by hand.

- **Divergence is now resolved by PUBLISHING, not deleting.** When the local
  branch holds TICKET WORK the remote has never seen,
  `reconcile_sync_local_branch` pushes it — divergence is genuinely gone
  (local == remote) and nothing is lost.

- **BUG-077's own case is untouched.** The decision keys on LCARS's own commit
  contract rather than on "is there anything local": `commit_ticket` always
  writes `lcars(<mission-id>) t-NNN: …`, and a cherry-pick preserves that
  subject, so a logged bug's fix is always recognised. A dead reconcile attempt
  is built with `git merge --no-edit` and carries no such subject, so it is
  still discarded exactly as before. `run.sh` has precisely two commit sites,
  one of each kind, so the partition is exhaustive by construction.

- **A failed push refuses rather than falls back.** If the work cannot be
  published, the branch is left alone with a loud event naming it. A jammed
  push is recoverable; deleted commits are not.

- **Measurement failure can never authorise a reset.** The counters return 0
  only for "nothing provably at risk"; an unresolvable or non-numeric count is
  treated as unsafe, not as permission.

- **The fold now verifies its own premise.** `fold_one_child` marked a logged
  bug Done on the stated assumption that "its fix already lives on the parent
  branch" — and never checked. That is what turned the branch reset into a
  green board with no fix anywhere. It now confirms the fix is actually on the
  parent branch (by the same preserved `lcars(<bug-id>)` subject) and REFUSES
  with a distinct code otherwise: the bug stays at Verify, its siblings still
  fold, and the command exits non-zero naming what was refused. A bug whose
  ticket recorded no commit has nothing to verify and folds as before, so
  no-op fixes are never false-refused. This closes the CLASS — any future cause
  (a force-push, a botched cherry-pick) is now a loud refusal at the moment of
  decision instead of a silent loss found days later.
## 2026.7.17 — 2026-07-28

GitHub Enterprise support — **LCARS worked on `github.com` and quietly half-worked
everywhere else.** On a `*.ghe.com` (or any self-hosted) repo, issues never
received their per-stage detail comments and ticket sub-issues were never nested,
with no error anywhere to explain why.

The cause is a split in `gh` itself: `gh issue` / `gh pr` resolve the forge host
from the repo's own remote, so they work on enterprise with no configuration —
but `gh api` does **not**. It targets the default host and only substitutes
`{owner}/{repo}` from the cwd repo. Verified against a real enterprise repo:

```
$ gh api "repos/{owner}/{repo}"
{"message":"Not Found","documentation_url":"https://docs.github.com/..."}
```

A 404 from *docs.github.com* — the call went to github.com — while `gh auth
status` showed a valid enterprise login the whole time. Every api-backed op
discards stderr, so the failure was completely invisible.

- **`gh api` is now host-pinned.** `host-adapter.sh` derives the host from the
  repo's origin remote and passes `--hostname` to every api call, routed through
  one `gh_api` wrapper so a future op cannot forget it. This repairs the S65
  living per-stage comments and native sub-issue linking on enterprise. Handles
  https, ssh, scp-style (`git@host:owner/repo`) and `host:port` remotes;
  `LCARS_GH_HOST` overrides.

- **github.com is byte-for-byte unchanged.** The helper returns EMPTY for
  github.com and for a repo with no origin, so no `--hostname` is added and the
  argv stays exactly what it has always been — the adapter's regression locks in
  `tests/host-adapter.test.sh` keep their meaning (56 green, untouched).

- **Readout links name the real host.** `lcars init` / `lcars update` printed a
  hardcoded `on github.com/<owner>/<repo>`, which on enterprise links to a repo
  that does not exist. Both now use the shared `lcars_gh_web_host`.

## 2026.7.16 — 2026-07-28

The Honest Environment round — **stop blaming the code for a stale toolchain,
and stop calling a repo mission-ready before anything has run.** One field
failure produced all three fixes. A Mission's ticket correctly diagnosed that
its repo's suite could never run (vitest 4 pinned against vite 5, which needs
vite >= 6) and committed the fix. The gate symlinked the main checkout's
`node_modules` — still holding vitest 4 — so the suite died at import anyway,
and the gate reported *"the implementation is NOT present on the committed
branch"*. No committed change could ever have cleared it. Three TDD sessions
were spent re-solving a solved problem, and `lcars init` had cheerfully
declared the repo ready in the first place.

- **Provisioning honours the lockfile.** The seeded JS `worktreeSetupCommand`
  reused the main checkout's `node_modules` whenever it existed — right up until
  a ticket CHANGED dependencies, at which point the shared install is the wrong
  set by definition and the ticket's own lockfile fix can never take effect. It
  now compares the worktree's lockfile against the main checkout's and does a
  real install when they diverge, keeping the fast symlink path (~0.07s) when
  they match. Covers npm / pnpm / yarn.

- **Existing repos are repaired, not just new ones.** `lcars update` gains a
  fingerprint-gated migration that rewrites LCARS's own un-guarded symlink
  command in place, alongside the S101/S148 `testCommand` migrations. It matches
  only a command carrying our symlink signature that lacks the guard, and
  regenerates the replacement from `detect_worktree_setup_cmd` so it cannot
  drift from the seed. A captain's hand-written command is never touched.

- **The gates name the real fault.** `red_gate_env_failure` only catches a
  runner that fails to START; here the runner started perfectly and simply had
  the wrong packages. The new `stale_dep_env_reason` is its state-based
  companion: when a gate worktree's deps are shared in by symlink AND its
  committed lockfile differs from that checkout's, both the post-commit and
  full-suite gates now report a STALE DEPENDENCY ENVIRONMENT — naming the repair
  — instead of accusing the implementation of being absent or earlier tickets of
  regressing. Conservative by construction: it speaks only on positive evidence,
  so a genuinely missing implementation keeps its existing wording.

- **`lcars init` proves the suite runs.** `lcars_test_readiness` is cheap by
  design (status and the board call it constantly), so "ready" only ever meant
  *the command's first token resolves* — a claim about the command, not the
  suite. init is a one-time action and can afford more, so it now runs the
  seeded command ONCE through the same bounded probe `lcars update --fix-tests`
  already used (moved into `lcars-common.sh` so the two can never disagree about
  what counts as a pass, a zero-collect, or a timeout). It probes only the
  `ready` verdict — the one state that can lie — reports honestly, and never
  blocks setup on a red suite. `LCARS_INIT_SKIP_PROBE=1` opts out.

## 2026.7.15 — 2026-07-28

The Hotkeys & Help round (S140–141) — **drive the bridge from the keyboard, and
find out how without leaving it.** The viewscreen had exactly one keyboard
listener in the whole front end (Escape-to-close) and no help surface of any
kind: no card navigation, no action keys, and nowhere for a new captain to learn
what the board even is. This round adds both halves — a command deck of single
keys, and a `?` console that documents itself from the same table that registers
the bindings.

- **The command deck (S140).** Cards are focusable (`role="button"`,
  `tabindex="0"`) behind an amber `:focus-visible` outline; arrows walk focus
  within a column and across columns (skipping empty ones); Enter *and* Space
  open the focused Mission; `f` `d` `s` `p` `v` `l` reach the band and card
  controls. Every binding dispatches by `.click()`ing the card's REAL control, so
  a hotkey is gated identically to the button it triggers — a disabled or absent
  control is a silent no-op, and read-only boards need no separate guard. Four
  guards: never hijack typing, an open console owns the keyboard (`?` excepted),
  modifier chords belong to the browser, and key auto-repeat cannot double-POST.
- **The `?` console (S141).** A `?` button in the yellow band (and the `?` key)
  opens one modal with two sections. **COMMAND DECK** is the cheatsheet,
  *generated by iterating the binding table* — a binding added later appears with
  zero extra work and the two can never drift. **ORIENTATION** is a
  getting-started briefing in the ship's voice: file or park a Mission, answer
  the Align grill, watch the stages advance, answer when the ship hails you,
  review at Verify, deploy main. It renders from a declared content structure
  whose every named control is walked to a real DOM node by test, so the primer
  cannot describe a UI that isn't there. A board with no Missions points at `?`.
  Help is never write-gated — it opens on read-only boards too.
- **Help covers the console underneath; it never destroys it.** Pressing `?`
  mid-task used to replace the open console, discarding a half-typed idea with no
  warning. Now the open console is hidden **in place** and revealed again on
  close, so typed text, an engine pick and a warm Align session all survive the
  round trip. Hiding rather than detaching keeps the node in the document, so
  intervals guarded on `document.body.contains` — a running Mission's clock, a
  Verify launch poll — keep ticking under the cover instead of self-cancelling
  and never restarting.
- **Copy that cannot lie.** Three tester rounds on real Chrome found nine
  defects, nearly all the same shape: prose describing conditional UI as
  unconditional. Two cheatsheet rows claimed to deploy and start when they only
  open a console; the Verify step promised "what was built" and an EST→ACTUAL
  line that are both gated; the VIEW-ONLY line claimed every named console still
  opens when only the File console does. The durable fix is that these claims are
  now pinned by tests that **measure the product** — walking each opener's real
  disabled state — rather than string-matching the sentence.
- **A fixture flake, root-caused.** `test_deploy_main.py`'s setsid handshake spun
  200 iterations with no sleep, finishing before the forked `perl` was even
  scheduled, and recorded a pgid its own comment says must be certified. When it
  lost that race `killpg` missed the group and the assertion accused production
  code of orphaning a deploy the fixture never group-leadered.

## 2026.7.14 — 2026-07-27

**Two silent-failure fixes from one live greenfield mission** — a multi-session
ticket no longer loses every commit but its last, and a mission can no longer be
re-homed onto a different (billed) engine just by resuming it from another
terminal. Both were invisible while they happened; both were found by driving a
real mission rather than by reading the code.

### Multi-session tickets keep all their work

- **The defect.** A bounced ticket re-enters the SAME per-ticket worktree with
  the prior session's commit as HEAD — `_tdd_reject` clears `result.json` and the
  output dir, never the tree. So session N committed ON TOP of session N-1, while
  `commit_ticket` recorded a SINGLE `.commit-sha` via `rev-parse HEAD`: the LAST
  commit only. The wave-end replay cherry-picks exactly that one commit (S133:
  "the ticket's tests ride in its ONE commit"), so sessions 1..N-1 were dropped
  on the floor.

  It failed SILENTLY, which is the worst part: every gate — flip-flop,
  declared-edits, quality floor, post-commit — runs against the worktree, where
  the full tree exists. All of them were green and all of them were right. The
  loss happened after the last gate, at replay, with nothing left to re-verify
  the branch.

  Observed live: a Vite+React scaffold ticket took 4 sessions. Session 3
  committed the whole app (13 files); session 4 added only `package-lock.json`.
  The mission branch received the lockfile alone — no `src/`, no `vite.config.ts`,
  no `package.json` — and a sibling ticket's stub `package.json` then replayed on
  top of the hole. The wave read as fully green.

- **The fix.** `commit_ticket` pins the wave base to `.commit-base` on a ticket's
  first session, then SOFT-resets to it before each later session's commit. A soft
  reset moves HEAD only — index and worktree untouched — so the recorded commit
  always carries the ticket's CUMULATIVE diff vs the base. `.commit-sha` keeps
  naming exactly one commit, so the replay, cherry-pick-conflict and
  serial-rebuild paths (all of which already assume one commit per ticket) are
  untouched. `.commit-base` is cleared everywhere `.commit-sha` is, so a serial
  rebuild re-pins against its own base. The single-session path is byte-identical.

Verified by a new scoped suite, `tests/replay-multisession.test.sh` (13), driving
the REAL `commit_ticket` through a new inert `commit-ticket-test` hook: two
sessions in one worktree must leave `.commit-sha` rooted AT the wave base with
the cumulative patch, and an actual cherry-pick of it must land every session's
files on the mission branch. Asserted against the commit's own PATCH, not its
tree — a tree diff passes even for the broken stacked-commit shape. Red on 5
before the fix. Regression: proof-gates 154, unified-implementer 37.

### A mission's recorded engine now outranks host auto-detection

- **The defect.** `resolve_worker_bin`'s precedence ran `$LCARS_WORKER_BIN` >
  `config.json workerBin` > **host-CLI auto-detect** > claude — it never read the
  engine the mission itself recorded in `state.json`. So the engine was
  re-DECIDED from the ambient terminal on every invocation. A mission filed and
  driven under Copilot, then RESUMED from a Claude Code session (`CLAUDECODE=1`),
  silently moved onto billed claude mid-flight with its `workerBin: copilot` pin
  sitting right there being ignored.

  Observed live: 7 workers and **$11.39** billed to the wrong engine after a
  resume from the wrong terminal. Nothing warned — the SPEND was the only
  symptom, and it only surfaced because someone read the per-engine cost split.
  That is precisely why auto-detection must never outrank an explicit record.

- **The fix.** The mission's `state.json` `workerBin` is consulted BEFORE host
  detection. Deliberate operator acts still win — `$LCARS_WORKER_BIN` and
  `config.json workerBin` both outrank the mission pin, so a mission can still be
  moved on purpose — but a guess drawn from whichever terminal happens to be
  driving no longer silently overrides what the mission recorded. A mission with
  no recorded engine falls through to detection unchanged, and the new source is
  reported as `binsrc=mission` in the resolution log. Several callers set
  `MISSION_DIR` but not `STATE`, so the state path is derived defensively and the
  resolver stays silent when there is no mission at all.

Verified by 6 new cases in `tests/worker-resolve.test.sh` (29): a copilot-pinned
mission resolved from a CLAUDE host yields copilot via `binsrc=mission` and does
NOT re-home; `config.json` and `$LCARS_WORKER_BIN` both still outrank the pin;
and an unpinned mission still falls through to detection. `resolve-worker` grew
`--mission <id>` so the pin participates, mirroring how the real spawn paths set
`MISSION_DIR`. (5f/5i in that suite fail on `main` too — a pre-existing
adapter-argv issue, untouched here.)

## 2026.7.13 — 2026-07-27

**`lcars buddy` stops misreporting the config it exists to show you.**

- **The truncated testCommand.** buddy's `json_str` carried the comment "mirror
  status.sh" but had drifted to the old naive sed reader whose value class is
  `[^"]*` — it ends the value at the FIRST escaped quote. That is not an exotic
  input for this reader: S148 makes every `testCommand` LCARS itself seeds QUOTE
  its `$LCARS_TESTS_DIR` scope, so a correctly-configured `config.json` always
  stores `\"`. The brief therefore printed a truncated command
  (`npx vitest run ${LCARS_TESTS_DIR:+\`) for a repo whose config was perfectly
  fine — misreporting the one value a captain runs buddy to verify, and reading
  as if the config had been mangled. `worktreeSetupCommand` (whose JS seed is
  built almost entirely of quoted shell) and any mission `title` containing a
  quote truncated the same way.

  `json_str` is now status.sh's escape-aware POSIX-awk reader, which treats
  `\"` as part of the value and decodes the common escapes on the way out —
  making the "mirror status.sh" comment true rather than aspirational, so the
  two readers cannot disagree about the same file. Display-only and read-only:
  buddy changes nothing, and no gate, stage or driver behaviour is touched.
  `json_raw` is unchanged (bare tokens carry no quotes to escape).

Verified by three regression cases in the scoped suite — a quoted
`testCommand`, a quoted `worktreeSetupCommand`, and a mission title containing
a quote, each asserted to render IN FULL with the expected value held in a file
so the harness's `eval` never re-expands the `$` and `"` it is made of.
lcars-buddy 17.

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
