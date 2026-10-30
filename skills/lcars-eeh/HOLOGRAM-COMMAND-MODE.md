# HOLOGRAM-COMMAND-MODE.md — how to run LCARS *for* the captain

This is the playbook for `lcars eeh`'s second half: the captain says
**"run it for me &lt;spec&gt;"**, answers **one** round of questions, and walks
away. From then on you are the orchestrator of his build.

It is modelled on a real run: over 26–29 Sep 2026 a session drove LCARS on
Copilot workers to ship 7 features and ~40 bug fixes — 34 missions in about 36
hours — while the captain was with family or asleep. Everything below either
worked on that run or is a guard against something that cost him attention.

**One principle: you steer and verify; you never build.** Your tokens go to
reading the spec, one alignment round, briefs, answering grills, judging live
checks, writing bug PRDs and the merge call. Everything sequenceable is
`lcars-ech`, which spends nothing.

> This is **not** a fix loop. The ECH never edits the LCARS source. If it
> hits an LCARS bug it works around it with another verb and ledgers it, or it
> stops and asks. Fixing LCARS is `lcars eeh` § 2, under `ORCHESTRATION.md`.

## Unattended Copilot setup: no blanket trust is required

**An unattended EEH or ECH run does not require `COPILOT_ALLOW_ALL=true`, and
nothing here asks you — or the run — to arrange blanket trust.** Preflight
reports whatever the environment happens to carry and proceeds either way. If
your environment already carries the variable it is honoured; if it does not,
start the run anyway.

**Measured 2026-10-16:** a seat running the real pipeline stripped the variable
from every child call it made (`env -u COPILOT_ALLOW_ALL`, 21 times) and the
build still completed and merged. Blanket trust is not load-bearing for the
work. Requiring it, by contrast, broke three seat models before they began: one
refused on policy rather than rely on it, and another was blocked by its own
safety classifier for being instructed to self-grant that authority and to
launch a fully-trusted agent. A prerequisite that stops the engines meant to
satisfy it is the fault, not the fix.

**What the variable actually does, for the record.** `--allow-all-tools`
auto-approves tools; it does not trust the working directory.
`COPILOT_ALLOW_ALL=true` additionally trusts that directory, and only that exact
string does — `1`, `yes`, `on` and `y` auto-approve tools like the flag.
**Trust is executable configuration, not just permission to read files:**
trusting a directory also loads its skills, plugins, MCP servers and hooks,
**including hooks that run shell commands.** That is a decision for the person
who owns the environment to make, in a repository whose provenance they control,
before any run starts — never something a run grants itself, and never
appropriate in a repository of unknown provenance.

**Measured 2026-10-13, and still true:** with `--allow-all-tools` set and the
directory untrusted, one EEH round was refused on every command, including
read-only commands, with
`Permission denied because no interactive user response was available.` Four
rounds had worked before the fifth failed without warning, and from outside a
blocked run and a healthy idle run look identical. So if commands start coming
back refused, that is the shape of it — stop and say so rather than retrying;
it is not something the run can fix from the inside.

**What to launch the seat with, then.** The capability `COPILOT_ALLOW_ALL=true`
would hand over in one switch, named directory by named directory instead, and
arriving from outside **before the seat starts** — so the run is never asked to
grant itself anything:

```bash
# `lcars launch` deploys to a SIBLING of the repo, so that one directory has to
# be named too. It may not exist at launch time — a grant for a directory that
# does not exist is not a grant — so create it first, exactly as the Holodeck
# sidecar's own grant does.
LAUNCH_ROOT="$(dirname "$(git rev-parse --show-toplevel)")/.lcars-launch"
mkdir -p "$LAUNCH_ROOT"
# `install.sh` puts the `lcars-ech` / `lcars-eeh` launchers on PATH in its bin
# destination, and the seat runs them constantly — so name that directory too.
# Resolved from install.sh's own variable, never a hardcoded /Users/<name>.
LAUNCHER_DIR="${LCARS_BIN_DEST:-$HOME/.local/bin}"
# § 6.1 requires driving a REAL headless browser, and this grant named none —
# so the seat asked for one, was refused, and then WORKED DOWN A LIST, asking
# again for the next name (measured 2026-10-19: Google Chrome refused, then
# Chromium). Resolve exactly ONE, BY A CHECK rather than a hardcoded path — a
# stranger's machine may not have the browser this one has — and grant the
# directory it was found in. Google Chrome first; the first match wins and no
# second browser is ever tried. The two `command -v` probes deliberately do NOT
# discard to `/dev/null` — a discard inside a `$(...)` is the stall § 6's rule
# forbids, and this file does not model what it forbids. `command -v` is silent
# when it finds nothing, so there is nothing to discard.
CHROME_BIN=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         "$(command -v google-chrome)" \
         "$(command -v chromium)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CHROME_BIN="$c"; break; }
done
BROWSER_DIR="${CHROME_BIN%/*}"
# Nothing found: § 6.1 cannot drive a browser on this machine. Say so, and fall
# back to a directory that is granted below anyway, so the launch line stays
# valid instead of failing on an empty --add-dir.
[ -n "$CHROME_BIN" ] || { echo "WARNING: no Chrome-family browser found; § 6.1 cannot drive one" >&2; BROWSER_DIR=/tmp; }
# `/dev` — the device directory, and `/dev/null` in particular, which
# essentially every shell redirect touches. It was NOT granted, so a seat that
# composed its own discard to `/dev/null` inside a `$(...)` froze on
# `Allow path access` for the path `/dev/null)` — closing parenthesis included,
# because the permission layer's path extractor took the `)` as part of the
# path — and the run was over, twenty minutes and a whole PR in (measured
# 2026-10-19). It is granted on exactly the reasoning the toolchain entries
# above already rely on: root-owned and system-managed, nothing a seat can
# meaningfully change.
# TRADE-OFF, deliberate, and the reason the cure has TWO halves: if the
# extractor compares the malformed string `/dev/null)` against this grant, a
# `/dev` grant may not match it, so this half alone may not hold. The other
# half is the prompt rule in § 6's doctrine — never discard output to
# `/dev/null` in a command you compose yourself; redirect it to a file under
# `.git/lcars/tmp/` instead — which avoids the construct entirely and does not
# depend on the extractor being right. Two changes, so the next run can tell
# the two explanations apart.
# copilot — the working directory is NOT trusted by the flag, so name the repo
copilot --model <model> --allow-all-tools \
        --add-dir <product-repo> \
        --add-dir <holodeck-sidecar> \
        --add-dir "$LAUNCH_ROOT" \
        --add-dir "$LAUNCHER_DIR" \
        --add-dir "$BROWSER_DIR" \
        --add-dir /tmp \
        --add-dir /usr/bin \
        --add-dir /bin \
        --add-dir /usr/sbin \
        --add-dir /dev
# claude — its cwd IS the repo already, so only the others need naming
claude --add-dir <holodeck-sidecar> \
       --add-dir "$LAUNCH_ROOT" \
       --add-dir "$LAUNCHER_DIR" \
       --add-dir "$BROWSER_DIR" \
       --add-dir /tmp \
       --add-dir /usr/bin \
       --add-dir /bin \
       --add-dir /usr/sbin \
       --add-dir /dev
```

Grant whichever directory your seat's `mktemp` and `>` targets really land in —
`/tmp` on macOS and Linux, `$TMPDIR` where the platform puts it elsewhere.

**And drive the browser the block resolved, by name.** `$CHROME_BIN` is
**Google Chrome** wherever it exists, and that is the one § 6.1's live check
uses — not "a Chrome-family browser", not whichever one comes to mind. The
stall this closes was not the refusal itself: it was the seat being refused one
browser and then WORKING DOWN A LIST, raising a fresh dialog for the next name.
One browser is resolved, once, before the seat starts; the seat asks for no
other.

**Why the temp directory is in there**, when § 6.1 tells the seat to keep every
throwaway HOME, scratch file and redirect target inside the repo under
`.git/lcars/tmp/` and never `/tmp`: because § 6.1 is an *instruction*, and an
instruction is model-bound. Measured 2026-10-18, back to back,
**same code, same hour**: a seat on `claude-opus-5.5` took **one** permission
stall (the unavoidable folder-trust prompt at startup); a seat on `gpt-6.1-sol`
— Copilot's **default**, and what a stranger gets — took **six**. Every one of
the six was the seat writing its own scratch to `/tmp` (`/tmp/lcars-suite-r2.txt`,
`/tmp/lcars-cli-r2.txt`, both real files on disk, both outside the grant), and
every one froze the run on a dialog nobody was awake to answer. § 6.1 existed on
that run: the strong model obeyed it, the default model did not. That gap will
exist for every rule we write by instruction. A launch-time grant does not have
it.

**The trade, named rather than sold.** `/tmp` is world-writable, so this is
genuinely wider than granting the repo alone, and it is not free. It is also
**one more named directory** — nothing like `--allow-all-paths`, and nothing
like `COPILOT_ALLOW_ALL`, which trusts a directory and therefore loads its
skills, hooks and MCP servers too. Decide it for your own environment; drop it
and expect a weaker seat to stall on its own scratch instead.

**Why the system toolchain is in there.** Measured 2026-10-18: a live seat on
`gpt-6-luna` stalled asking permission to use `/usr/bin/time` — a standard
system binary — because the grant named the repo, the sidecar, the LCARS source
and `/tmp`, but not the directories ordinary system commands live in. That is an
unattended run frozen on a dialog nobody is awake to answer, over `time`. The
reasons this is a narrow grant, each one checked on the host it was written on:

- `/usr/bin`, `/bin` and `/usr/sbin` are `root:wheel`, mode `drwxr-xr-x`, and
  **not writable** by the user a seat runs as; `[ -w /usr/bin ]` is false.
- **System Integrity Protection is enabled** (`csrutil status`), which forbids
  writes there even to root. Two independent levels, so **for writes the grant
  is close to a no-op.**
- It **adds no capability.** The seat already executes all 932 of `/usr/bin`'s
  tools through the shell; granting the directory removes a *prompt*, not a
  barrier.
- The danger named above is that trust "also loads its skills, plugins, MCP
  servers and hooks, **including hooks that run shell commands**" — executable
  configuration. A directory of root-owned system binaries carries none of that
  to load.
- It is a **launch flag**: scoped to that run, persists nothing, and leaves no
  trusted-directory record behind.

**The line this does NOT cross: `$HOME` stays ungranted, deliberately.** The
system toolchain and the home directory are **different kinds of grant** and
must not be weighed the same way. `$HOME` is **user-writable**; it holds
**credentials**, keys and every other project on the machine; and it *does*
carry loadable configuration (`~/.claude/`, `~/.copilot/`, their hooks and MCP
servers) — so every argument above fails for it, one by one. If you take one
thing from this passage, take that distinction.

**§ 6.1 stays either way — belt and braces.** In-repo scratch is still the
better hygiene: it keeps the product tree clean and leaves the evidence beside
the mission. The grant is only the backstop for the run where a model ignores
the rule.

**Why the launch checkout's directory is in there.** Measured live,
2026-10-18: a seat on `gpt-6-luna` stalled **five times in twenty-one minutes**,
and **four of the five were this one cause** — the seat was blocked **reading its
own deployed code**, the dialog naming
`.lcars-launch/<repo>/<mission>/jot/cli.py`, `store.py` and `README.md`.
`lcars launch` puts the deploy checkout **beside** the repo, at
`<repo-parent>/.lcars-launch/<repo-name>/`, and that sibling was not in the grant
above. Every one of those stalls froze an unattended run.

**Grant the one named directory — `<repo-parent>/.lcars-launch` — and nothing
else.** It is **one named directory, not the parent**: naming the parent would
hand the seat **every sibling repository on the machine**, by far the widest
thing in that list and the one grant nobody could check the way `/usr/bin` was
checked. Naming `.lcars-launch` exposes **zero** sibling repositories. And the
checkout **stays outside the repo**, which is what `lcars launch` designed for:
a second copy of the repo *inside* it gets swept up by the parent's own test
globs and watchers, and `.git/info/exclude` does not stop a glob — so moving the
checkout in-repo would trade a permission stall for a dirty **product tree**
(nothing gitignores `.lcars-launch` at a repo root, so a bulk `git add` could
commit it). Keep the files where they are and name the directory. No change to
`lcars launch`, and `$LCARS_LAUNCH_ROOT` stays unset.

**It may not exist yet, so create it before you grant it** — `mkdir -p` in the
block above. The directory appears on the first `lcars launch`, which is *after*
the seat starts, and a grant for a directory that does not exist is not a grant.
This is the same step the Holodeck sidecar's grant already takes.

**This is the third instance of one pattern.** LCARS deliberately places things
*beside* the repo to keep the product tree clean — the Holodeck sidecar, the
seat's scratch (§ 6.1 above, and the `/tmp` grant that backs it), and now the
launch checkout — and a scoped grant does not reach any of them. All three are
cured the same way: name that one directory, create it first, change nothing
about where the files go. When a seat stalls on a path it created itself, check
that list first.

**Why the launcher directory is in there.** `install.sh` puts the `lcars-ech`
and `lcars-eeh` launchers on PATH in its bin destination — `$LCARS_BIN_DEST`,
default `~/.local/bin` — and a seat drives a whole round through them. Measured
across **eight** runs that cost exactly **one stall**, and that one was a seat
*listing* the directory (`~/.local/bin/lcars*`, a glob) to see what was
installed — a browse, not blocked work. *Invoking* the launchers through PATH
never prompted at all, 27–103 invocations a seat. So it was deliberately left
out of the grant.

**2026-10-19 reversed that.** On a clean `gpt-6-luna` seat the "Allow path
access" dialog named **the launcher file itself** — `~/.local/bin/lcars-ech`,
no glob, the command the seat runs — and it **froze the run** until somebody
answered. A grant that saves a *browse* is optional; one that unblocks the
command a seat reaches for every few minutes is not.

**It is the directory `install.sh` itself writes to**, so a reader who installed
LCARS the normal way already has it, and nothing new has to be created in order
to grant it. If your launchers live somewhere else, grant that directory
instead — `command -v lcars-ech` says which one it is.

**The honest trade, and it is weaker than the toolchain's.** Do not borrow the
`/usr/bin` argument above: every limb of it fails here. This directory **is
user-writable** by the seat; there is no `root:wheel` ownership and no System
Integrity Protection over it, and anything written there lands on `$PATH`. What
is true instead is smaller, and worth stating plainly rather than dressing up:
it is the reader's **own** directory, holding software they installed
**deliberately**, and it is a **launch flag** — scoped to that run, it
**persists nothing** and leaves no trusted-directory record. That is the whole
case for it. It is still **one named directory**, never `--allow-all-paths` and
never `COPILOT_ALLOW_ALL`.

**`$HOME` is still refused**, and granting a directory *inside* it changes
nothing about that. `~/.local/bin` holds launchers; `$HOME` holds credentials,
keys, every other project on the machine, and the loadable configuration under
`~/.claude/` and `~/.copilot/`. One named child is **not its parent**.

## Unattended Copilot commands: start at the repository root and write downward

**Run commands from the repository root and write DOWNWARD** into its
descendants. Never redirect through parent path components (`..`), even when
the resolved destination would remain inside the repository.

This command route is refused even with `COPILOT_ALLOW_ALL=true`: the problem
is the upward traversal, not the destination, .git, Python, or the test runner.
In unattended mode no interactive approval is possible, so a permission
refusal ends the run; do not retry the refused route.

**REFUSED — documentation only; do not execute or copy as a suggested command:**

```text
cd .git/lcars/tmp/<wt> && python3 -m unittest ... > ../../autopilot/x.txt ;
```

**Working shape — stay at the repository root and write downward.** Replace
`<wt>` with the worktree name before running:

```bash
mkdir -p .git/lcars/autopilot
python3 -m unittest discover -s .git/lcars/tmp/<wt>/tests -v > .git/lcars/autopilot/x.txt
```

## How to read this file

Ask the driver what to do next, then read that section:

```bash
lcars-ech next
```

`install.sh` generates that command for both CLIs, and **every command in this
file is written out in full** — there is no shorthand to expand, because a
reader who jumps straight to § 9 never sees the top of the file.

**If it says "command not found"**, `install.sh`'s launcher dir (`~/.local/bin`)
is missing from your PATH; `install.sh` prints the line to add. Until you add
it, `bash <your-lcars-clone>/skills/lcars-eeh/ech.sh` is the same
driver and takes exactly the arguments shown below.

It prints one action and the **exact heading in this file** that covers it:

```
NEXT: verify-gate lcars-20260930-001
WHY: M0 reached the Verify gate — read Number One, then run the live check
PLAYBOOK: ## 6. The Verify gate — Number One, then the live check
```

`lcars-ech playbook` prints the whole action→heading table, and the test
suite asserts every heading in it exists here — so this file and the script
cannot drift apart.

## Durable state: `.git/lcars/autopilot.json`

**Record, don't infer.** Every fact this mode needs later is written to
`.git/lcars/autopilot.json` *at the moment it is decided* — never left in the
chat. Scope, latitude, the captain's answers, the captain-only steps, driver
pids, and **every** open question.

**Questions are a ledger, not a slot.** `questions` holds every question ever
raised — answered or not — and `pending` is a derived *mirror* of the oldest
open one, there because the model-facing surface reads a single question.
Writing a question **appends**; nothing already recorded is destroyed, so a
second question can never delete the first. **Raising the same question twice
is a no-op.** A question already *open* on the same (mission, question) pair is
not re-recorded and does not ping him again, so re-running a blocked step is
safe; two *different* questions on one mission stay two questions, and a
problem that recurs **after** he answered it raises a real new one. Close one
with its id (which `lcars-ech status` prints) and the mirror moves on:

```bash
lcars-ech status                          # [q1] lcars-…: <the question>
lcars-ech ask "<what you need>" --mission <id> --why "<why>"   # raise one (§ 9)
lcars-ech answered q1 "yes, go ahead"     # records the answer BESIDE the question
```

Raise every question with `ask` (§ 9) and never write `pending` yourself: it is
derived, and the driver overwrites it on the next write.

`answered` never deletes: the question stays on the record with his answer next
to it, and it clears that mission's failed-drive counter (§ 5), because his
answer is what unblocks it.

Write with the driver, not by hand:

```bash
lcars-ech record liveTargets.host enterprise.example.com
lcars-ech record missions.M0.id lcars-20260930-001
lcars-ech record missions.M0.verified true
lcars-ech record preauthorised.liveTestWrites true
```

**The memory rule.** Your context *will* compact on a run this long. After any
compaction — or at the start of any session where the captain says "continue" —
your **first** action is to re-read `autopilot.json` and run `lcars-ech
status`. Do not re-ask anything that is already recorded there. State that
lived only in the transcript is state that is gone.

Ledgers live beside it, also inside `.git/` so the product's working tree stays
clean:

| File | What goes in it |
|---|---|
| `.git/lcars/lcars-feedback.jsonl` | LCARS bugs, gaps, friction, wins, your own mistakes |
| `.git/lcars/autopilot-overrides.jsonl` | every Number One verdict you overrode, with the live evidence |
| `.git/lcars/decisions.jsonl` | product calls, scope changes, merges |

```bash
lcars-ech ledger feedback  '{"kind":"lcars-bug","detail":"fold drift blocked a merge"}'
lcars-ech ledger overrides '{"mission":"lcars-…","verdict":"low","reason":"infra only","evidence":"…"}'
lcars-ech ledger decisions '{"what":"added M6","who":"captain"}'
```

---

## 1. The alignment round — one batch of questions, then walk away

**Before you ask anything**, do the reading, so no question is wasted:

1. Run `lcars eeh` (§ 1 of SKILL.md) and read the brief — where LCARS lives,
   whether the install is in sync, what is already in this repo.
2. **Repeat the ask back** in plain terms and get it confirmed.
3. Read the spec. Then check what the harness can actually do (engine flags,
   Number One, the holodeck) *before* asking.

Then **one** batch of 3–5 questions, each with a **recommended option** so the
captain can answer in a word:

1. **Scope** — which milestones, in what order. (Recommend the spec's own.)
2. **Live targets** — the host and the owners you may create or touch things
   under.
3. **Where it deploys**, and what "live" means for this product. Record it —
   there is a key for it: `lcars-ech record deploy '{"where":"…","liveMeans":"…"}'`.
4. **What to do if LCARS itself breaks** — the default is *stop and report*.
5. **The pre-authorisations** (§ 7): may `land` give the specific
   `--reapprove` sign-off after LCARS reconciles green? Record an actual grant
   with `lcars-ech grant reapprove`; never infer one from general encouragement.
   May live checks write to the product repo? Both default to **no**.

Then write it all down and start:

```bash
lcars-ech init --spec <path-or-url> --scope M0,M1,M2 --engine copilot \
                  --deadline 2026-10-01T07:00:00-07:00
lcars-ech record latitude.allowed '[ … ]'     # his words, not the defaults
lcars-ech record liveTargets '{"host":"…","owners":["…"]}'
lcars-ech heartbeat install
```

`init` finishes by running `lcars-ech preflight`, and that is on purpose:
it is the one moment a human is reliably in the room. **Do not walk away before
that round has printed `proceeding`.** It settles six things the run cannot
settle for itself later:

| # | what it settles | with nobody there |
|---|-----------------|-------------------|
| 1 | where the launch copies go | PROCEEDS on a stated default (and refuses an answer that is not a writable absolute path) |
| 2 | the test command the push gate runs | PROCEEDS: `next` already names the `foundation` step for a repo with no suite |
| 3 | somewhere to push — and whether that remote **answers**, probed with a bounded `git ls-remote` | STOPS |
| 4 | the forge login a pull request needs (`gh auth status`) | STOPS |
| 5 | the engine's unattended permission — whatever `COPILOT_ALLOW_ALL` the environment carries, on a copilot run | PROCEEDS: reported, never required (see the setup section above) |
| 6 | Number One: RECOMMENDED **ON**, using the run's engine | PROCEEDS on the recommended default, ON; runs `xo on --engine <run-engine> --sweep` once and records the choice |

1, 2 and 6 carry a RECOMMENDED default, so `yes` answers the block. Re-run
`lcars-ech preflight` any time; a prerequisite already recorded is not
asked about again.

Number One is asked for **once, at preflight**, never later at a merge gate.
No tty means proceed on ON without waiting for input; an explicit OFF is
preserved too. The decision and its engine live in `autopilot.json.numberOne`;
the real `xo` verb applies it. A refused verb is reported, not called success.
This is a run choice, **not** a change to `lcars init`: its
`numberOne.enabled` default stays **false**.

3 is a **reachability** check, not a name check: a deleted repo, a typo'd host
and revoked auth all leave `origin` in the config and die at the pull-request
gate at 03:00. 5 is **reported, not required**: it used to STOP, which cost
three seat models before they began, and S303 measured that the work ships
without the variable anyway. Preflight names the value it found and moves on.

**A deadline is not a refusal.** If the probe runs out its bound (`rc 124`) the
stop says the remote *may simply be slow* and blames nothing: a cold VPN
handshake, a monorepo with a huge ref advertisement and a loaded forge all read
exactly like a dead host, and all three are healthy. It is also the one stop
that **cannot retire itself** — a slow remote stays slow — so it offers the two
real ways out: `lcars-ech answered <id> "it's just slow"` clears it for
good, and `LCARS_ECH_PROBE_TIMEOUT=60 lcars-ech preflight` widens
the bound. A remote that genuinely *refuses* keeps the old wording, which does
name the URL and the auth.

**A local-only run costs ONE command, not two.** "No push" settles 3 and 4
together: answer the push question in your own words (`answered <id> "ship
local-only, no push"`) and the forge-login check is **not run at all**, with the
reason printed — there is no pull request for a login to be needed for.
`lcars-ech record localOnly true` is the same decision stated up front; it
writes `push.mode = local-only`, which is the key preflight reads, and an
`origin` that happens to exist is then neither used nor probed. Undo it with
`record push.mode origin`. (It is a *preflight* decision: it stops the setup
asking about pushing. It does not yet gate `push-gated`.)

**Two ssh cases preflight can still false-stop on**, both settleable with one
`answered … "push anyway"`:

* The probe runs `ssh -oBatchMode=yes`, which **fails any key that needs a
  human** — a hardware token (FIDO2, `sk-ssh-ed25519`) waiting for a touch, or
  a passphrase key with no agent loaded. That is deliberate (an unattended run
  cannot answer a prompt, and a probe that hangs is worse than none), but it
  means a touch-key captain sees a stop on a remote that works fine for him
  interactively.
* The probe **sets** `GIT_SSH_COMMAND` rather than extending it, so a
  proxy-jump or custom identity exported in the environment is dropped for the
  probe only. The same settings in `~/.ssh/config` are read as normal and are
  unaffected.

If it prints `STOPPING`, the question is already in `.questions` with the one
command that fixes it. **Do not drive a milestone past a preflight stop.** You
have exactly two ways out, and both work:

* **Fix the cause** and re-run. A prerequisite that is satisfied now
  **withdraws its own question** — he never has to answer something that is no
  longer true to unstick a run that is already unstuck.
* **`lcars-ech answered <id> "<what you decided>"`.** That answer is READ
  on the next run, so the same question is never raised twice, and where it
  names a decision (`local-only`) it is acted on. His inbox is never filled with
  clones of one question.

Three overnight runs on 2026-10-14/15 died at verification on a permission
nobody was awake to give, and a fourth could not open a pull request because
there was no remote, which LCARS had already written into the Mission's own
`state.json` as `githubIssue: null`. A blocked run and a healthy idle one look
identical from outside and nothing inside the run can recover from either, so
the whole cost lands on the night.

**Launch it in the foreground, or expect the defaults.** A detached launch —
`… &`, `nohup`, a detached tmux pane — cannot read the terminal, so preflight
detects that it is not the terminal's foreground process group and takes the
defaults (or stops) instead of asking. It never waits on a terminal it cannot
read: that is the hang this step exists to abolish.

**This is the whole interrupt budget for the setup.** A second question round
is a defect in how you ran this step, not a fact about the spec.

An empty scope is unfinished alignment: set it with `init --scope` or
`lcars-ech record scope '["M0","M1"]'` before building or claiming completion.

`lcars-ech init` configures the run, not the repository. If preflight's
Number One step says the LCARS config is missing, invoke the `lcars init`
skill, then run `lcars-ech preflight`. The refusal also gives the bundled
`init.sh` command for a terminal-only recovery. The requested choice remains recorded,
but Number One is not engaged until that retry succeeds.

---

## 2. Captain-only steps, collected up front

Some things only he can do: a token, a repo secret, SSO authorisation, an org
setting, a repo rename. On the modelled run a hub token surfaced at 10:40am and
SSO at 1pm — both on the critical path, both avoidable. **Enumerate them in the
alignment round**, with a *needed by* time, and record them:

```bash
lcars-ech record captainOnlySteps '[
  {"what":"HUB_TOKEN secret on the product repo",
   "instructions":"! pbpaste | gh secret set HUB_TOKEN -R <host>/<owner>/<repo> --app actions",
   "neededBy":"before M2 drives","done":false}
]'
```

`neededBy` is checked when recorded. Omit it for an immediate step.
`before M2 drives` (or `before M2`) is collected up front, before any drive;
`after M2 merges` is deferred until M2's Mission records Stage `done`.
Name a milestone in this run's scope. Other timing prose is refused with a
copyable record command, not stored as a promise the driver cannot keep.
`status` lists due and deferred steps; `next` only stops for due ones.

**Secret values never appear in the transcript.** Always give him the
`! pbpaste | gh secret set NAME -R <host>/<owner>/<repo> --app actions` shape —
he copies the value to the clipboard and the command reads it from there. (On
the modelled run he pasted a token into the chat on the first try and had to
rotate it.)

**Verify each one the moment he says it is done** — list the secret names, check
the first workflow run gets past checkout — then
`lcars-ech record captainOnlySteps '[…"done":true…]'`, and say plainly what
is still missing.

**If he DECLINES one, record the decline — never `done: true`, never delete it.**
A declined step is an outcome, with a third state of its own:

```bash
lcars-ech record captainOnlySteps '[
  {"what":"a Pages deploy token", "instructions":"…", "neededBy":"before M2",
   "done":false, "declined":true,
   "declinedReason":"no deploy token, no Pages tonight"}
]'
```

`next` never asks for a declined step again, `status` still lists it as declined,
and the ledger keeps the fact that it was asked. Writing `done: true` would be a
lie in the ledger and deleting the step loses the ask; neither is the answer.

---

## 3. Foundation — establish the vision, then re-check the test command

A repo with no test foundation refuses a normal mission. The foundation is its
own initialization mission; the ECH `init` and every `next` check the repo with
the same readiness signal as `lcars init`, so no `foundation.required` or
`foundation.done` flag is needed. LCARS already has the verb for it:

```bash
lcars-ech exec lcars-init/establish-vision.sh --file \
     --stack "<the stack>" --slice "<a thin end-to-end slice>" --engine copilot
```

Supplying both `--stack` and `--slice` records them as the project idea;
`--idea <file>` is optional and takes precedence when supplied.

Do **not** write your own scaffold. Drive the initialization mission, do its
Verify gate and land it before filing the first product milestone; `next`
finds it by LCARS's existing `missionType: initialization`, not an ECH flag.

**Immediately after it is approved, check `testCommand`.** `approve` has
promoted an uninstalled runner over a captain-set stdlib command before. `land`
re-asserts it automatically from `autopilot.json`; this is the one place where
the recorded value is first set, so make sure it is the command the captain
actually wants.

---

## 4. File a milestone through the front door

**`file.sh` requires six sections** and refuses the PRD without any one of them.
Write all six before you call it — they are, exactly: **Mission title**, **Type**,
**Goal**, **Acceptance Criteria**, **Out of Scope**, **Constraints**. **Mission**
is also accepted in place of **Mission title**. Either
shape is accepted per section — a bold inline label (`**Goal:** …`) or the label
owning its own line as a heading (`## Goal`). (A complex mission filed with
`--adr` needs each ADR to carry **Context**, **Decision**, **Alternatives
considered** and **Consequences** too.)

**The mission title is a plain sentence — never a markdown heading, and never
the field label.** Write the outcome the way you would say it: `Add a jot CLI
that publishes a shareable web page`. The `##`, the `**`, and the words
"Mission title" belong to the PRD's LABEL and never travel into the VALUE.
Measured 2026-10-19: one seat filed a mission whose title was literally the
string `## Mission title` — on disk and, because filing opens an issue, as the
public GitHub issue title everybody can see. Six of seven seats got this right;
it is a one-in-seven leak with a public consequence, which is why it is written
down here.

For each unfiled milestone, `next` prints mutually exclusive branches: judge
**its own spec/brief**. If it **has screens**, take `holodeck` before filing;
otherwise go straight to `file`. This is model judgement, not a recorded flag.

**Holodeck means the real surface**: open a named Program with
`holodeck_start`, author there through `holodeck_say`, read the concept's open
questions, `derive`, then hand it to a Mission through Align and record its id.
`holodeck_end` closes the worker; its own rooms and Programs survive in the
sidecar. A hand-authored `mockup.html` attached at CLI filing is an
**attachment-only** path: it never passes through the surface, so the Holodeck
stays empty. **State which path you took.**

**Hand the design over with `promote` — the hand-off is what gives the Mission
its own copy of the design.** `POST /api/holodeck/<sessionId>/promote` (step 5
below) drafts the brief; filing the mission AS that hand-off — the same
`sessionId` threaded into the filing call, `POST /api/mission` with
`{"idea": "<the brief>", "holodeck": "<sessionId>"}` — **copies** the room's
`mockup.html` and `concept.md` into the Mission's own `attachments/` dir and
lists them in its `prd.md`, which is the GitHub issue body. The Mission OWNS
the design: delete the sidecar and the build still has its drawing. The record
rides along for free — the `Sent to Align:` line, the room marked handed over
and read-only, the link the viewscreen draws back to the Program.

Writing the brief yourself is **not equivalent**, however faithful it reads,
because it copies nothing. The Mission is left BORROWING a file that lives
outside the product tree, by absolute path: end the room, move or clean the
sidecar, or hand that path to a worker that cannot read it, and the build
silently loses its design with every stage still green. The record goes missing
too, which makes a real hand-off indistinguishable from no hand-off at all.

**Measured: three seats in a row read the first wording of this rule and
hand-wrote the brief anyway** — two built the right thing with no record, one
abandoned its design and never filed at all — because the only cost it named
was bookkeeping. The cost is the copy. A fourth seat, the same model behind a
different CLI, called `promote` twice: this is a choice, not a limit.

**HOW TO CALL IT: the Holodeck is HTTP on the viewscreen daemon.**
`holodeck_start` / `holodeck_say` / `holodeck_end` are **not shell verbs** —
they are routes on the board's own daemon, and this is the one thing this file
used to leave out. Measured: the strongest seat reverse-engineered them on its
own; the weaker seats never found them and never reached the Holodeck at all.
Start the daemon **headless** (no `--open`, so nothing steals the captain's
screen), then POST to it:

```bash
# 1. the daemon, headless, in the background. It prints the URL it bound.
#    `LCARS_VIEWSCREEN_ALLOW_AI=1` IS REQUIRED HERE AND IT IS NOT A PERMISSIONS
#    HACK: the viewscreen has a headless gate of its own that refuses to start
#    inside an AI session, because from in here it cannot reach the macOS
#    desktop and DEPLOY MAIN / `lcars launch` would be dead buttons. The
#    Holodeck needs neither of those, so the gate's own documented bypass is
#    how automation says so. WITHOUT the variable the line below EXITS, BINDS
#    NOTHING, and logs "LCARS viewscreen — NOT started".
LCARS_VIEWSCREEN_ALLOW_AI=1 lcars-viewscreen --port 8765 >/tmp/lcars-viewscreen.log 2>&1 &

# 2. POST /api/holodeck/start — open a named Program. `mode` is `grounding`
#    (recommended: the opening pass reads the project's own language) or
#    `design`. THE REPLY CARRIES `sessionId` — record it, every later call
#    needs it — but it is NESTED: every holodeck POST answers
#    {"ok": true, "state": {"sessionId": ..., ...}}, so read `.state.sessionId`
#    and not a top-level key. `repo` is the ABSOLUTE path of the product repo.
curl -s -X POST http://127.0.0.1:8765/api/holodeck/start \
  -H 'Content-Type: application/json' \
  -d '{"repo":"/abs/path/to/product-repo","program":"M0 screens","mode":"grounding","engine":"copilot"}'

# 3. POST /api/holodeck/<sessionId>/say — ONE authoring turn. `intent` is
#    "build" or "ask"; omitted it means "build".
curl -s -X POST http://127.0.0.1:8765/api/holodeck/<sessionId>/say \
  -H 'Content-Type: application/json' \
  -d '{"text":"<what to build or change>","intent":"build"}'

# 4. POST /api/holodeck/<sessionId>/derive — the change list, which is the gate
#    before the hand-off. IT IS ASYNCHRONOUS. It returns AT ONCE with
#    {"derive": {"state": "running"}} and the pass behind it takes MINUTES
#    (measured at 154–220s; the daemon allows it up to 420s). Do NOT put
#    /promote on the next line — that was this file's own mistake.
curl -s -X POST http://127.0.0.1:8765/api/holodeck/<sessionId>/derive \
  -H 'Content-Type: application/json' -d '{}'

# 4a. WAIT FOR IT, ON A BOUND. The same `derive` block rides on the GET below:
#     {"state": "running"} while the pass is in flight, then
#     {"state": "done", "ok": true, "changes": [...]} when it lands — or
#     {"state": "done", "ok": false, "why": ...}, which means the pass DID NOT
#     ANSWER and not "the mockup changes nothing". A seat that waits for ever
#     is indistinguishable from a dead one, so this loop gives up and says so.
#
#     READ THE REPLY DEFENSIVELY. Two answers on this GET are NOT "still
#     working" and the parser must not fall over them: the daemon can die
#     mid-wait (curl prints NOTHING and a naive json.load then prints a Python
#     traceback every 5s for the whole 7.5 minutes — measured, ~90 of them),
#     and an ENDED session answers HTTP 404 {"error": "no such holodeck
#     program: ..."}, which parses fine but carries no derive block. Both mean
#     NOTHING IS COMING, so this loop calls them `no-answer`, stops at once,
#     and says which it was. A seat that can tell a dead daemon from a slow
#     one does not have to guess. The `except` is what keeps the traceback out,
#     NOT a discard: this substitution deliberately carries no `/dev/null`
#     redirect, because one inside a `$(...)` is read as the path `/dev/null)`
#     and stalls an unattended seat (§ 6's rule; measured 2026-10-19). Do not
#     add one back.
for i in $(seq 1 90); do
  st="$(curl -s http://127.0.0.1:8765/api/holodeck/<sessionId> \
        | python3 -c 'import json, sys
try:
    reply = json.load(sys.stdin)   # nothing, or not JSON, lands in the except
except Exception:
    print("no-answer"); raise SystemExit
print((reply.get("derive") or {}).get("state", "")
      or ("no-answer" if reply.get("error") else "running"))')"
  [ "$st" = "done" ] && break
  [ "$st" = "no-answer" ] && break
  sleep 5
done
case "$st" in
  done) : ;;   # the `changes` list is on that same GET. Go to step 5.
  no-answer)
    echo "the holodeck daemon STOPPED ANSWERING (it died, or this session was ended — after /end that GET 404s for ever). This is NOT 'still working': nothing is coming, so do not keep polling. Read /tmp/lcars-viewscreen.log, restart the daemon, and get back in by ROOM name (step 7)." ;;
  *)
    echo "derive gave up after 90 tries of 5s (~7.5 min); state=$st. The daemon is alive and still working — it just outran the bound. Promote anyway — a brief with no derived section is still a brief he can send — or re-run derive with force true." ;;
esac

# 5. POST /api/holodeck/<sessionId>/promote — SEND TO ALIGN. `scope` is the
#    BUILD SCOPE, never the milestone label: {"scope":"M0"} is REFUSED with
#    HTTP 400 "unknown build scope". There are exactly two legal values:
#      "look+behaviour" — build it for real: backend, state, persistence, the
#                         lot. The mockup says how it LOOKS; the brief says
#                         what it must DO. This is also the default if `scope`
#                         is omitted.
#      "look-only"      — a reskin: match the mockup visually and make NO
#                         functional change. Same data, same actions.
#    The reply carries the whole Align brief.
curl -s -X POST http://127.0.0.1:8765/api/holodeck/<sessionId>/promote \
  -H 'Content-Type: application/json' -d '{"scope":"look+behaviour"}'

# 6. POST /api/holodeck/<sessionId>/end — closes the worker. The room and the
#    Program survive in the sidecar.
curl -s -X POST http://127.0.0.1:8765/api/holodeck/<sessionId>/end \
  -H 'Content-Type: application/json' -d '{}'

# 7. GETTING BACK IN AFTER `end`. `end` IS FINAL FOR THAT sessionId: from then
#    on GET /api/holodeck/<sessionId> answers HTTP 404, for ever. What survives
#    is the ROOM — mockup.html, concept.md, transcript.md — and the Program
#    list still shows it, with "sessionId": null and its `room` name. Starting
#    the same Program name again can be refused with "switch to it in the
#    program list", which is a GUI a headless seat does not have. THIS is the
#    headless road back in: POST /api/holodeck/open with the ROOM name (not a
#    session id). It WARM-RESTARTS the program — a FRESH sessionId, the whole
#    transcript replayed in as context, the mockup exactly as it was left.
curl -s -X POST http://127.0.0.1:8765/api/holodeck/open \
  -H 'Content-Type: application/json' -d '{"room":"m0-screens","engine":"copilot"}'

curl -s -X POST http://127.0.0.1:8765/api/holodeck/duplicate \
  -H 'Content-Type: application/json' -d '{"room":"m0-screens","program":"M1 screens","engine":"copilot"}'

# READS are GETs. /api/holodeck is the Program list — every program in this
# repo's sidecar, live or on disk, each with its `room`. /api/holodeck/<sessionId>
# is one LIVE Program plus its transcript, and it is live ONLY while that
# program is open: after `end` it is 404 and the list route is the only place
# that program can still be read. No holodeck WRITE is reachable over GET, by
# design.
```

File through the real verb, with a real PRD on disk:

```bash
lcars-ech exec lcars-file/file.sh --prd <path/to/prd.md> --engine copilot
lcars-ech record missions.M0.id <the-mission-id-it-prints>
```

**The brief pattern that worked** (200–400 words): the product context and
what is already built; the exact experience in numbered steps; files and paths;
the test seams; out of scope; and, for screens, "mock up: &lt;the screens and
states&gt;".

**The Align-answer pattern:** accept or correct the recommendation in one
sentence, then **pre-settle everything else**, marking each item "RESOLVED with
the captain". Answer *every* design-session item in your first reply — it roughly
halves the grill.

**Two injections into every PRD** until the harness does them for you:

- **The seam constraint.** For every producer/consumer pair the milestone
  creates, demand a round-trip test that uses **both real halves** with no
  hand-written fixture between them. For every CI workflow, demand a test that
  runs the **real entrypoint exactly as the workflow does** (same cwd, same
  command, the env Actions always sets). A test that stubs the seam it claims to
  prove is not proof.
- **The anchor rule**, verbatim with the anchor list, on any PRD with a mockup —
  it turns a 6-attempt Plan flip-flop into a first-try pass.

---

## 4a. Drive through the HUMAN interfaces — never hand-step the stage machine

**The captain's rule, 2026-10-13, after watching an EEH hand-walk a run:**

> *"The EEH in the ECH should run this like a human. I'd click run from after the
> align and let it go and click pause when needed. But the harness should drive
> the states."*
> *"We don't want it not to solve stuff, just do it through the human interfaces."*

Both halves of that matter, and they are easy to get wrong in opposite
directions.

**DO — these ARE the human interfaces, and using them is the job. Never defer
them, never wait for a human, there is nobody there:**

- **Start a mission and let the harness drive it.** `lcars run <id>` WITHOUT
  `--step` is a token-free bash driver that sequences Research → Validate → Plan
  → Plan Review → Schedule → Implement by itself and stops only at a real gate.
- **Answer every human gate, immediately** (`lcars respond`, or the board's
  ANSWER control). A gate with nobody to answer it is a stopped run.
- **Pause when something genuinely needs stopping, and resume.**
- **Accept or send back at Verify, and merge through `lcars approve`.**

**DO NOT — this is reaching behind the interface:**

- Walking a mission forward one verb per Stage, re-issuing `xo off` / `pause` /
  `resume` / `--step` to advance it yourself.
- Writing mission state the harness owns while a worker is running.

**WHY, measured on 2026-10-13 (S291).** Hand-stepping writes mission control
state into `state.json` *while a cold worker is mid-Stage*. The worker fence sees
that file change under a running worker and blames the WORKER, stopping the Stage
and painting a red card:

```
WORKER FENCE BREACH — the repo-read cold worker for this Stage changed
things it is never allowed to write. MISSION STATE: state.json
```

**Nothing is wrong with the build when this fires.** It fired five times in one
run across BOTH engines — Copilot at Plan and at Validate, Claude three times at
Research — every one of them triggered by the EEH following the product's own
prescribed sequence (`pause` refuses while Number One is engaged and names
`xo off` as the cure; both write `state.json`). After the same run switched to
starting missions and letting the harness drive, the count held flat for the rest
of the day while missions continued to complete.

**And the failure mode of over-applying this is just as bad.** Told only "stop
touching control state", an EEH went timid for a whole turn: no merge, no
resume, no gate answered, and it recorded *"leave control state untouched"* while
a mission sat parked at a gate nobody could answer. **A rule that only says what
not to touch produces an agent that solves nothing.** The test is not "did I
touch state" — it is **"would the captain have done this by clicking
something?"** If yes, do it.

> **Note for whoever fixes the underlying defect:** the real cure is in LCARS,
> not here — the fence should distinguish the OPERATOR's sanctioned control
> writes from a worker writing outside its lane. This section reduces how often
> the trap is stepped on; only that change removes it.

## 5. Drive it — backgrounded, with a waiter that watches the process

```bash
lcars-ech drive <mission-id>
```

That calls `run.sh drive --mission <id>` with the recorded `gateTimeout`, in the
background, and records the owning pid in `autopilot.json`. **Do not re-sequence
stages yourself** — the driver owns the order.

**The waiter watches the PROCESS, never a clock.** It is the driver's parent and
simply blocks on it, so it cannot overrun and cannot cut LCARS off. On the
modelled run a hand-rolled `alarm` wrapper killed an `approve` mid-retest and
left a reconcile worktree holding the branch. Never wrap an LCARS verb in a
timeout, and never poll a log in a sleep loop: ask `lcars-ech next`.

**A failing drive is counted and capped.** The waiter records the exit against
`drivers.<id>.failures`; **three failures in a row and the mode stops retrying**
and writes you a question instead (§ 9) — repeating a failure that never changes
is an LCARS bug with no verb-level workaround, not something to sit on until
morning. A clean drive clears the counter, so one flake costs nothing.
`lcars-ech answered <id>` clears it too, once the cause is fixed.

**A routine stage stop pings nobody.** The waiter records the exit and
`lcars-ech next` has the next step; the captain hears about a drive only when
it has hit the cap. Spending his interrupt budget (§ 9) on "a stage stopped" is
the inversion of what he asked for.

While a drive is in flight, use the time for live-check prep, the report, or
the *other* slot (§ 8) — not for watching.

---

## 6. The Verify gate — Number One, then the live check

**Verify is not completion.** An accurate summary saying the work is unfinished
is not permission to stop. Run `lcars-ech live-check <mission-id> --type <types>`
now, record the target and known-fail control verdicts, run
`lcars-ech policy --mission <mission-id> --live-check pass|bugs`, and take its
one action. If it permits landing, run `lcars-ech land <mission-id>`; otherwise
follow the send-back loop. Then run `lcars-ech next` again. Continue until the
scope is done or a recorded captain-only condition actually blocks the work.

For test commands and evidence capture, follow
[the repository-root/downward rule](#unattended-copilot-commands-start-at-the-repository-root-and-write-downward)
above; do not redirect upward from the live-check worktree.

When a mission reaches `verify`, read Number One's verdict
(`lcars-ech exec lcars-xo/xo.sh report`, `xo/verdict.json`) — then **do the live check yourself every
time, regardless of its verdict. This is your standing job, never a fallback.**
On the modelled run Number One filed **0 of 31** bugs and every one came from
the live check. Its misses were all *reach* errors, never judgement: no screen
to look at, nothing seeded, stubs that made the seam untestable.

### 6.1 Set it up with one command, then do the looking

1. **A green check carries a control.** ANY CHECK WHICH CAN RETURN GREEN
   WITHOUT HAVING OBSERVED THE THING must carry a control case known to fail.
   Apply the same detector to both, and report BOTH verdicts and observations
   with distinct evidence. For a web check render/open the target AND a signed-out
   login wall beside it: a produced screenshot is not a checked product page.
   A detector that calls the login wall green cannot support a green target.
   `live-check` prints a target/control pair for every checklist item and writes
   `.git/lcars/missions/<id>/live-check/checks.json`. Each control's `input`
   names a concrete known-fail artifact; render the supplied login-wall HTML
   beside the target for web checks, or use a product-specific failing input.
   Fill every row's `detector`,
   `target` and `control`: each needs a `verdict` (`pass` or `fail`), nonempty
   `evidence` file path and `observation`; the control also names its
   `knownFailure`. `live-check done --verdict pass` is REFUSED unless every
   target passes AND every known-fail control fails. Never call an unobserved
   item passed; record bugs or say **not checked**.

2. **Enumerate, don't sample.** A claim about a MISSION needs every ticket,
   not the two on screen. Enumerate the mission's complete ticket list, name
   each verdict and its evidence, and count anything unobserved as **not checked**.
   The paired checklist is a floor, not permission to omit ticket acceptance
   criteria; add their target/control cases to your evidence too.

3. **Read the board.** Use the harness-maintained mission and ticket states
   shown by the board's own API; never invent a completion metric beside one
   the harness already maintains. Read the board response, not a sampled
   screenshot or a clean log, before claiming completion.

```bash
lcars-ech live-check <mission-id> --type cli,web,workflow
```

That prepares a **detached** worktree of the mission branch and a **throwaway
HOME** (never the checked-out branch, and never your own HOME: a config you
wrote earlier makes an unconfigurable product look configured), makes the
evidence dir at `.git/lcars/missions/<id>/live-check/`, and prints the
checklist(s) for the product types the milestone touches.

**The script owns the setup, the evidence paths and the record. The looking is
yours.** It also stages the checklists **into this repository**, at
`.git/lcars/live-check/{cli,web,workflow}.md`, refreshed from the installed
LCARS on every run, and that staged copy is the one it names and the only one
you read. **Re-read the item you are on, from that file, as you do it** — the
cli list alone is 313 lines and the point of a file is that the item cannot
quietly fall out of your context. Never reach into LCARS's own installed
directory for it: you are trusted inside the repository you are building in,
and a read outside it stops an unattended run dead on a permission prompt
nothing in the run can answer (measured, 2026-10-17). The shared source home
lives under `lcars-run`, not under the EEH, because the rebuilt Number One
reads the same files — you just never have to go there. Every item is an action
plus the evidence to capture plus what counts as a defect, and carries a fenced
`run:`/`workflow:`/`read:` template beside the prose so a fenced worker with no
shell can lift it.

**Everything you make yourself goes inside the repository, under
`.git/lcars/tmp/`.** `live-check` already puts the worktree and the throwaway
HOME it hands you there. The checklists then ask you for things it cannot make
for you — a *second* throwaway HOME, an ad-hoc input file, somewhere to
redirect output — and they never say WHERE, because they cannot know your repo.
You do. You are trusted only inside the repository you are building in, and a
**write** outside it raises `Allow path access` and stops an unattended run
dead on a dialog nothing in the run can answer (measured, 2026-10-18: a seat
stalled twice, on `/tmp/home2-XXXX` and on `/tmp/good.json`). So never `/tmp`,
never a bare `mktemp -d` with no template, never a `>` target outside the repo.

**Never discard output to `/dev/null`** in a command you compose yourself —
redirect it to a file under `.git/lcars/tmp/` instead. A discard to `/dev/null`
written inside a subshell or a `$(...)` reaches the permission layer as the
path `/dev/null)`, trailing parenthesis and all, because its path extractor
takes the `)` as part of the path. That string matches no grant that could ever
be written, so no `--add-dir` can satisfy the dialog it raises, and it stopped
an unattended run dead twenty minutes in — after a mission, four closed tickets
and an open PR (measured 2026-10-19). A real file — `2>.git/lcars/tmp/<what>.log`
— raises nothing, and has the side benefit that the output still exists if
something needs diagnosing. The launch grant now names `/dev` as well, but that
is belt and braces: if the extractor compares the malformed `/dev/null)`
against it, a `/dev` grant may not match, so this rule is the half that does
not depend on it. This file obeys the rule too — no recipe in it discards to
`/dev/null`, so there is nothing here to copy.

The **second actor** (cli checklist item 4, whose `<throwaway-home-2>` has no
location in the checklist) is the one measured to bite. Give it one, from the
repository root:

```bash
mkdir -p .git/lcars/tmp
H2="$(mktemp -d "$PWD/.git/lcars/tmp/lcars-ap-home2-XXXXXX")"
HOME="$H2" <cli> <the-main-verb> <the-same-value-actor-A-used>
```

Scratch inputs go the same way — `.git/lcars/tmp/good.json`, never
`/tmp/good.json` — and so does every log you redirect, the Holodeck daemon's
included: start it with `>.git/lcars/tmp/lcars-viewscreen.log` in place of the
`/tmp` path § 5 shows, and read it back from there.

The **invalid path** is the other one measured to bite. cli checklist item 2
("Give it bad input, and no input") tells you to feed the product *a path that
does not exist*, and that path has no location in the checklist either. Give it
one INSIDE an already-approved folder, from the repository root:

```bash
<cli> <the-verb-that-takes-a-path> .git/lcars/tmp/not-a-real-path
```

A path that does not exist **outside** the repository is outside every grant
**by definition**, so no `--add-dir` can ever cover it — it is not a grant that
is missing, it is a request that **can never be granted**, which makes an
out-of-tree bad path a guaranteed stall (measured 2026-10-19: a seat stopped on
exactly this, on `/missing`). An invalid path inside an approved folder
exercises the **same error handling** and raises nothing.

Pick **every** type the milestone touches. A CLI that writes a page published by
a workflow is all three. The items that found the bugs, by name:

- run `--help`, and bad input **whose invalid path sits inside an
  already-approved folder** — `.git/lcars/tmp/not-a-real-path`, never
  `/missing`. A path that does not exist is outside every grant BY DEFINITION,
  so no `--add-dir` can ever cover it and an out-of-tree bad path is a
  GUARANTEED permission stall (measured 2026-10-19, a seat stopped on exactly
  that). An invalid path inside an approved folder exercises the same
  error-handling and raises nothing. A subcommand missing from `--help` is a defect
- **two actors**, two HOMEs
- **make the identities that usually coincide differ** — owner ≠ login, draft
  name ≠ title
- **follow one record end to end**, through every real half (no hand-written
  fixture between a producer and its consumer)
- **check the host of every outbound call**, with a non-default host configured
- real headless Chrome — specifically **Google Chrome**, the one the launch
  grant resolved into `$CHROME_BIN`. Drive that one and no other: a browser
  outside the grant raises `Allow path access`, and asking for the next name on
  a list raises it again. Plus the **400 px iframe** recipe for phone width
  (headless will not lay out below 500 px)
- **read the deployed artifact**, not "deploy succeeded"
- **re-verify after every fix round with different data**

### 6.2 Every workflow the mission adds, run exactly as CI runs it

```bash
lcars-ech workflow-run <mission-id> .github/workflows/<name>.yml
```

The job's steps, in order, each from its own `working-directory`, with the env
Actions always sets (`GITHUB_SERVER_URL`, `GITHUB_REPOSITORY_OWNER`,
`GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`), and the **first failing step named**.
This is the check a green suite cannot do: on the modelled run a workflow ran
`python3 pkg/hub_requests.py`, which dies on a relative import, while
`python3 -m pkg.hub_requests` works — and every test that imported the function
passed. Do not rewrite a step's command into the form that works; fix the step.

A `uses:` step is reported SKIPPED. That means **unproven**, not passed — prove
it by reading what it published (the web/workflow checklist's artifact item).

### 6.3 Record the verdict, then take the policy's one action

```bash
lcars-ech live-check done <mission-id> --verdict pass|bugs
lcars-ech policy --mission <mission-id> --live-check pass|bugs \
                    [--verdict high|medium|low] [--reason product|infrastructure] \
                    [--evidence <path>]
```

There is no default verdict: an unrecorded live check would read later as one
that passed. `policy` prints **ONE** action; `lcars-ech policy --table`
prints the whole table.

---

## 6a. The merge policy — one action per verdict pair

| Number One | Live check | Action |
|---|---|---|
| any | **bugs** | **send-back** |
| high | pass | **merge** |
| medium | pass | **merge+follow-ups** — merge, and file the gaps it named as their own missions |
| low, for a **product** reason | pass | **send-back** |
| low, for **infrastructure** reasons only | pass | **override** — fix the cause, verify that one point live, record the override |

**THE MERGE IS THE HOLOGRAM'S CALL.** Number One *recommends*; the hologram
running the mission decides within LCARS's gates and the captain's recorded
authority. **The hologram's own live check is REQUIRED before every merge.**
**Number One's recommendation is not a substitute for having looked.**
Read the actual live evidence, record pass or bugs, and take the table's action;
a grant never turns bugs into pass.

**A grant acts, and is ledgered.** A matching recorded grant runs the exact
LCARS-sanctioned command without a second question, as § 7 specifies.
**An ungranted refusal raises one pre-staged question and stops that milestone.**
Neither Number One's advice nor the hologram's judgement can bypass a refusal
on its merits or a permission classifier.

It scored every CLI or integration milestone `low` for reasons it could not
reach, which is why a `bugs` live check sends back even a `high`, and why a
`low` that is purely about infrastructure is an override rather than a stop. It
may run its own one fix round (`xo file-logs` → `xo recheck`); you may run
further rounds through `file-bug` beyond that one.

**Every override is recorded, with its evidence path.** `policy` writes it to
`.git/lcars/autopilot-overrides.jsonl` and **refuses** an override whose
`--evidence` path does not exist on disk — an unevidenced override is a shrug,
and this ledger is what the captain reads afterwards.

### The send-back loop, in order

```bash
lcars-ech file-bug --parent <mission> --prd <bug-prd.md>   # one PRD per bug
lcars-ech exec lcars-resolve-logs/resolve-logs.sh --parent <mission>
lcars-ech live-check <mission> --type <types>              # DIFFERENT data this round
lcars-ech exec lcars-respond/respond.sh answer --mission <mission> --answer "<the live evidence>"
lcars-ech land <mission>
```

The bug PRD template is `.git/lcars/bug-prd.md`, **inside the repository you
are building in** — `live-check` and `file-bug` both refresh it there from the
installed LCARS on every run, and `live-check`'s last line prints the path.
**Read it there, and read it while you write the PRD.** It is in-repo on
purpose: a seat is trusted only inside the product repository, and on 2026-10-17
a seat handed a path into LCARS's own tree froze on a permission dialog mid-run.
AC #1 is mandatorily
`Observed live: <the exact output>` with the real identifiers, and a bug at a
producer/consumer seam needs a **round-trip** criterion using both real halves
with no hand-written fixture between them. `file-bug` refuses a PRD without
them, and refuses to report a filing it cannot see (a `log.sh` that exits 0
without linking a child is a refusal, not a filing).

**The one style exemplar is `bug-prd.md`'s own worked example** — match that,
and nothing else. The PRDs in the weekend archive
(`canvas-weekend-2026-09-26/evidence/filed-prds/`) predate the template and
`file-bug` refuses them (no `Out of Scope`, no `**Seam:**`, an AC #1 worded
`Observed (real code, no stubs on the contract):`), so a PRD matched to one of
those cannot be filed. The validator is right; the archive is just older. The
worked example is also deliberately about a FICTIONAL product: an example drawn
from the thing you are checking hands you one of its faults for free.

**Re-verify with DIFFERENT data.** Re-running the first pass's inputs proves
only that one input was patched. Re-run the items that *passed*, too: a fix that
breaks a neighbour is what that catches.

**You do not paste the anchor rule or the seam constraint into the PRDs you file.**
Both are **harness defaults** now — the Plan prompt carries the anchor rule from
one source, and the validator enforces each ticket's declared producer/consumer
seams (S236/S237, landed 2026-10-01). Pasting either into a PRD duplicates what
the harness already does.

When the live check is clean, record that fact for the status readout:

```bash
lcars-ech record missions.M0.verified true
```

Take the policy's action directly (`land` for a merge); `next` always returns
the Verify gate while the mission is at `verify`, even with this flag set.

And keep the progress page current, because it is what the captain reads on his
phone:

```bash
lcars-ech report
```

It renders, per milestone, the stage, Number One's verdict, the live-check
verdict, the screenshots and the bugs filed/fixed — only from what was written
down, so nothing on it comes from a clock.

---


## 7. Land it — approve, then the hygiene that always follows

```bash
lcars-ech land <mission-id>
```

It pre-checks (no live driver, no open logged children), calls the real
`approve.sh --mission`, and then runs the hygiene that the modelled run had to
remember by hand every time: re-assert the captain's `testCommand`, `xo off`
every folded child (LCARS does not release them on fold), remove any stale
`reconcile.XXXXXX` worktree, pull, and write the merge to the decisions ledger.

**`approve` exiting 0 is not proof of a merge.** Its self-heal reconcile path
reconciles `main` into the branch, re-tests it green and then waits for the
captain's `--reapprove` — exit 0, nothing merged, the Mission still at `verify`.
So `land` re-reads the Mission's own `state.json` and claims it landed only when
the stage is really `done`.

**A grant acts, and is ledgered.** At `verify` with
`reconcileStatus=awaiting-reapprove`, a matching recorded `reapprove` grant
lets `land` run **only** `approve.sh --mission <id> --reapprove`, without
re-asking. The hologram must have recorded its own live-check pass with an
existing evidence path first. The attempt writes a `decisions.jsonl` line
with its grant id, mission, exact command and argv, output, exit code,
command-output evidence path and live-evidence path. It continues to hygiene
only if LCARS actually records `done`.

**An ungranted refusal raises one pre-staged question and stops that milestone.**
Without a matching grant, the existing behaviour stays: **no** hygiene,
**no** `merged` ledger line, the four-field question naming `--reapprove`,
and exit **10**. Reapprove is still the captain's sign-off; a recorded grant
is how he authorises the hologram to give that specific sign-off for him.

### Record the authority, not a promise to ask faster

Only record a grant the captain actually gave. Never mint one for yourself,
infer one from Number One's recommendation, or confuse a grant with engine
tool permissions.

```bash
lcars-ech grant reapprove --mission <mission-id> --once
lcars-ech land <mission-id>
```

`reapprove` is the named action, **not prose or an arbitrary shell command**.
`autopilot.json.grants` records its id, action, scope, mission, duration, who
granted it (`captain`, or `LCARS_ECH_GRANTED_BY`), `grantedAt` and the run's
`startedAt`. Every new seat reads that record after a restart or compaction.
`--mission <id>` limits it to that Mission; without it, the scope is this run.
`--once` (the default) permits **one attempt**, claimed durably before execution
so a crash cannot reuse it. `--run` permits reuse for this run, still within
any named mission scope. No grant carries into another run. A failed attempt
is ledgered too; it stops rather than trying another route.

**You never merge by hand.** Not with a better justification, not "just this
once", not by another route when the permission classifier blocks the first one.
**A grant never authorises a hand-rolled `gh pr merge`.**
**A grant never authorises a second route around a permission-classifier refusal.**
**A grant never authorises a merge LCARS refused on its merits.**
When LCARS refuses a merge, `land` exits **10** and writes ONE pre-staged
question to `autopilot.json.pending` with four fields — what is blocked, why it
is safe, the one command that would run, and the rollback. Surface that
question and **stop that milestone**. Other milestones carry on.

The legacy `preauthorised.manualMergeWhenApproveHitsKnownBug` boolean is
**not a scoped grant** and cannot authorise a command. Record the exact named
authority above instead. A grant authorises the LCARS sign-off, not a manual
merge around LCARS.

Pushing is also not yours to hand-roll:

```bash
lcars-ech push-gated
```

It runs the recorded suite and pushes **only on exit 0**. A hand-rolled version
of this gate once matched the word `FAILED` as success and pushed a red `main`.

---

## 8. Waiting, two missions at a time, and the crontab heartbeat

**The guard must not share a kill-space with what it guards.** Kill only by
recorded pid (or the isolated process group created for that pid), never by
broad process-name or command-line pattern. Use `lcars-ech watch stop` for the
guard; do not sweep waiters and accidentally kill the independent heartbeat.

**Two missions at a time is the ceiling**, and only when their write sets do not
overlap. Two was measured safe on a 10-core Mac; three drove load average to 170
and killed workers. `lcars-ech next` enforces it and tells you to wait;
`lcars-ech status` shows the slots in use.

### A WAIT HAS A LIMIT, A RE-CHECK, AND AN ACTION ON EXPIRY

**This step killed four seat models out of four**, across three model families.
They were told to wait, and this section did not say for how long, how to
re-check, or what to do if the wait never ended — so they sat there until they
were killed. **A seat that waits for ever is indistinguishable from a dead
one.** Never wait without all three of these.

1. **The limit is 30 minutes** (`LCARS_ECH_WAIT_LIMIT`, in seconds).
   `lcars-ech next` prints it under every `NEXT: wait`, records when the wait
   began (`waitingSince`) and tells you how far into it you are. The start is a
   **record**, not something you work out of your own transcript.

2. **Re-check by asking `lcars-ech next` again.** Never poll a log, and never
   wrap an LCARS verb in a timeout — § 5's rule stands, and the drive in flight
   already has a waiter blocked on its PROCESS. With nothing else to do, block
   on those same recorded processes:

   ```bash
   lcars-ech await               # 0 the moment a slot frees
   lcars-ech await --limit 600   # …and it CANNOT outlive its bound
   ```

   `await` exits **124** when the bound passes and names the command to run
   then. It watches processes, not a clock-wrapped verb, and it never sits for
   ever.

3. **When the limit passes, STOP WAITING** and run:

   ```bash
   lcars-ech stalled     # a driver that ended with nobody picking it up
   ```

   It decides from the **recorded pid**, not from a log. Act on what it names,
   then `lcars-ech record drivers.<id>.pickedUpAt <ts>`. If it names **nothing**
   while the slots stay full, that is an **LCARS bug with no verb-level
   workaround** — § 9's fourth category. Raise it with `lcars-ech ask` and carry
   on with the other milestone. Do not sit on it until morning.

**The heartbeat is `crontab`.** One line, minute 17:

```bash
lcars-ech heartbeat install    # … remove / status
```

It calls `lcars-ech stalled`, which reports a mission whose driver ended with
nobody picking it up — decided from the **recorded pid**, not by grepping a log.
Act on it, then `lcars-ech record drivers.<id>.pickedUpAt <ts>`.

**If `heartbeat install` refuses, fall back to the timerless watcher.** The crontab WRITE is
bounded (`LCARS_ECH_CRONTAB_TIMEOUT`, 10s): a seat reported it "produced no
output and remained running until terminated", and on macOS the table lands in
`/var/at/tabs`, which needs Full Disk Access for the writing process — without
it the permission request blocks with nobody there to answer. `install` now
says exactly that and exits **11** instead of hanging, after starting
`lcars-ech watch start`. An immediate crontab refusal also reports its error,
starts the same fallback, and exits **11**. **The heartbeat is OPTIONAL**, not the guard:
confirm `lcars-ech watch status` says running and read `.git/lcars/autopilot/watch.log`
for wake events. Do not stop the run over it and do not raise it with the captain.

**The timerless watcher is a different thing from `await --limit`.**
Run `lcars-ech watch` in the seat's background tool to receive its output, or
`lcars-ech watch start` to record its pid and write wake events to
`.git/lcars/autopilot/watch.log`. It has no deadline, never needs re-arming, and continues
after a slot frees. It wakes on failed-and-idle missions even when both slots
are occupied; act on the named mission through LCARS, never write beneath a
live worker. It exits **10** only when a recorded question genuinely needs a
human. `await --limit` remains the bounded wait INSIDE the seat's loop; the
watcher outlives that loop. At wrap-up use `lcars-ech watch stop`, which kills
only its recorded pid and confirms termination before reporting success, leaving
the heartbeat and drivers alone. If termination cannot be confirmed, it reports
the failure and retains the recorded pid.

Why a crontab line and not the host harness's own cron tool: LCARS ships to
people who are not inside Claude Code, so a harness-only tool cannot be this
mode's heartbeat — on their machine it does not exist. A crontab line is on
every POSIX box, it outlives the session, and the captain can read and delete it
himself. Remove it when the run ends.

---

## 9. The interrupt budget — what actually reaches the captain

> "I definitely don't want to match something if it means I'm going to be
> annoyed more often." — the captain, 2026-09-28

After § 1, **exactly four things** reach him:

1. A **product call** only he can make.
2. A **scope change**.
**A REFUSAL THAT NAMES ITS OWN CURE IS NOT A WALL (S260, 2026-10-08).** This
rule forbids RETRYING BY ANOTHER ROUTE — it does not forbid doing the ONE thing
the refusal explicitly told you to do. When LCARS refuses and names the
sanctioned command that clears it (`xo off <mission>` before answering a
mission Number One owns, `lcars update --test-command` for an unrecorded
runner), RUN THAT COMMAND, record that you did and why, and carry on. Measured:
a run stopped dead and waited on the captain for a documented one-line transfer
the refusal itself had spelled out. Ask only when the cure is NOT named, or when
running it would cross a `never`.

**AND IF A MISSION CANNOT BE PROOF-GATED BECAUSE OF ITS OWN EARLIER ATTEMPTS,
RETIRE AND RE-FILE IT — you already have that latitude.** A mission proves work
by its tests failing on the parent and passing on the tip; once a failed attempt
has COMMITTED its scaffold, the tests pass on the parent too and that mission
can never go green again. That is a dead mission, not a question for the
captain: archive it and re-file from a clean base (never delete), and say in
your report that you did.

3. A **standing-rule conflict** — including every permission denial, and the
   refused merge of § 7.
4. An **LCARS bug with no verb-level workaround**.

Nothing else. Routine progress goes to the report and the pictures, not to a
question. Quality decisions — live verification, bug round-trips, merge
judgement, overriding a verdict on live evidence — you make alone and **record**;
you do not ask for them.

**A denial is a question with the evidence ready, never a retry by another
route.** What is blocked, why it is safe, the one command that will run, the
rollback. `lcars-ech land` writes exactly that shape for a refused merge.

**For everything else, raise it with `lcars-ech ask` — never by editing
`autopilot.json`.** One question per call, in the same four fields:

```bash
lcars-ech ask "Ship M1 as the CLI only, or hold it for the page?" \
  --mission lcars-20260930-001 \
  --why "a product call only you can make — the page needs a deploy token" \
  --command "-" \
  --rollback "nothing to undo — nothing was attempted."
```

It lands in the `questions` ledger **immediately**, with its own id, and pings
him **once**. Asking the same thing again while it is open is a no-op and does
not ping him twice; the same problem recurring *after* he answered is a real new
question. `--mission <id>` is required, because a question blocks *that*
milestone and no other — use `--mission -` for one that belongs to no milestone.
`ask` exits 0: a question is not a milestone stop, so keep working.

**`pending` is a read-only mirror of the oldest open question, derived on every
write — it is never storage.** Do not write it, and never read a question out of
it: `questions` is the record and `status` prints every id. A question an older
run left in `pending` is still honoured: it is adopted the moment it is seen,
exactly once, into `questions` under a real id. Use the verb and there is
nothing to adopt.

**Several questions can be open at once, and none of them parks the run.** Each
is recorded separately and `status` prints them all with their ids. A question on
one milestone blocks *that* milestone only: `lcars-ech next` still names the
runnable work on the others, and with two slots that is the point. Ask them in
one message when you can, close each with `lcars-ech answered <id> "<what he
said>"`, and keep working while you wait.

**The communication rules**, which he taught during the modelled run:

- **Answer as the final message of the turn.** A reply woven between tool calls
  never reaches his remote view — he said "you've ignored my last two messages".
- **One crisp, plain-English paragraph** on request: what is done, what is
  blocked, the next step and its owner. Say what "works" and "blocked" mean
  concretely.
- **Pictures for every milestone**, including CLI ones. Keep ONE report page and
  republish it in place; send key screenshots to his phone proactively.
- He dictates by voice: read "our cars" / "Elcar" / "El cars" as LCARS, "corks"
  as quirks, and expect "do"/"don't" to flip occasionally — confirm when it
  matters.
- **Be honest about misses, including your own**, and ledger them.

**Deadline honesty.** **Re-forecast at every stage change** from actuals, and
push the new forecast to him as soon as it crosses his target, with the options
("ship these three now and land the laggard later"). On the modelled run every
slip was reported late.

```bash
lcars-ech record lastForecast "M0–M2 by 06:10; M3 at risk (plan round 2)"
```

---

## 10. Wrap-up — lead with the time the captain got back

When everything in scope is merged and verified, `lcars-ech next` says
`done`. The final message **leads with what he got back**: hours away, questions
asked, milestones shipped. Then:

- what shipped, and what each thing does in plain English;
- pictures;
- what you decided alone, and every override, from the ledgers;
- LCARS bugs and friction you hit, from `lcars-feedback.jsonl`, with the
  work-arounds you used — these are somebody's next fix session;
- what the proof was blind to;
- worker spend (Copilot is free — say so) alongside your own host-model tokens;
- `lcars-ech heartbeat remove`, and any worktrees or throwaway HOMEs torn
  down.

---

## The shape of the whole thing, in one block

```
lcars eeh                                     # read the brief
the EEH> run it for me <spec>                     # ONE question round
  lcars-ech init --spec … --scope …       # record every answer
  lcars-ech heartbeat install
loop:
  lcars-ech next                          # the ONE next step + its heading here
    file       → lcars-ech exec lcars-file/file.sh --prd --engine  → record missions.<M>.id
    drive      → lcars-ech drive <id>        (backgrounded; waiter on the process)
    verify-gate→ xo report + your live check    → policy → land or the send-back loop
    land       → lcars-ech land <id>         (approve + hygiene; exit 10 = ask)
    wait       → two at a time is the ceiling. 30-MIN LIMIT, then `stalled`.
                 `lcars-ech await` blocks on the PROCESS and exits 124 at the bound.
  lcars-ech status                        # the one screen, any time
done:
  lcars-ech heartbeat remove; wrap up (§ 10)
```
