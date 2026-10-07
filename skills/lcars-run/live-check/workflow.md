# Live check — a CI workflow

Run every item from the **detached** worktree with the **throwaway HOME** that
`autopilot.sh live-check <mission> --type workflow` prints.

A workflow is the one surface where a suite's green is almost meaningless: the
tests import the function, CI runs the command. On the modelled weekend three of
six live breaks were only ever visible to the real runner, and one of them was a
module invoked as a file.

The runner for these items is **`autopilot.sh workflow-run <mission>
<workflow.yml>`** — a minimal step runner that executes each step the way the
workflow does: same cwd (honouring `working-directory`), the step's own command,
and the env Actions always sets. It is deliberately not `act`: a third-party
runner is one more thing to be wrong, and it hides the step boundary this check
is about.

---

### 1. Inventory every workflow, job and step the milestone adds or touches

List the workflow files, and for each one its jobs, triggers and the **exact
command** of every `run:` step, plus any `working-directory` and `env`.

**Evidence:** `live-check/01-workflows.txt` — file by file: triggers, jobs, and
each step's name, cwd and command verbatim.

**DEFECT:** a step whose command cannot run in a clean checkout (a path that
only exists on your box, a tool nobody installs); a trigger the spec did not
ask for; a workflow with no trigger that can ever fire; two triggers that both
fire on one event (an issue opened *with* a label fires `opened` **and**
`labeled`, and the modelled weekend ran every request twice because of it).

```read:
{
  "path": "<repo>/.github/workflows/",
  "evidence": "live-check/01-workflows.txt",
  "expect": {
    "everyStepCommandRecordedVerbatim": true,
    "everyWorkingDirectoryRecorded": true,
    "noDoubleFiringTriggerPair": "e.g. opened + labeled on the same issue event"
  }
}
```

---

### 2. Run the workflow **exactly as CI does**, locally

Run `autopilot.sh workflow-run <mission> <workflow.yml>`. It executes the job's
steps in order, each from the cwd the workflow declares, with
`GITHUB_SERVER_URL`, `GITHUB_REPOSITORY_OWNER`, `GITHUB_REPOSITORY` and
`GITHUB_EVENT_PATH` set, and stops at the first failing step and names it.

**Evidence:** `live-check/02-workflow-run.txt` — the full step-by-step output,
including the `FIRST FAILING STEP:` line if there is one.

**DEFECT:** any step that fails. A step that "works when I run it by hand" and
fails here is a real defect: the hand run had your shell, your cwd and your
environment, and CI has none of them. Treat a *skipped* `uses:` action as
unproven rather than passed — if it does the real work, item 6 is what proves
it.

```workflow:
{
  "file": "<repo>/.github/workflows/<workflow>.yml",
  "evidence": "live-check/02-workflow-run.txt",
  "expect": {
    "everyRunStepExits": 0,
    "firstFailingStepNamed": "when one fails, by its workflow step name",
    "note": "a step that passes by hand and fails here is a DEFECT, not a false alarm"
  }
}
```

---

### 3. The env Actions always sets is present, and the workflow uses it

Confirm each step that needs them sees `GITHUB_SERVER_URL`,
`GITHUB_REPOSITORY_OWNER`, `GITHUB_REPOSITORY` and `GITHUB_EVENT_PATH` — and
that the code reads them rather than assuming a value. Run `workflow-run` once
with a **non-default** `GITHUB_SERVER_URL` (an enterprise host) and read what
the steps did with it.

**Evidence:** `live-check/03-actions-env.txt` — the env the runner set, and
every line of step output that shows a server, owner, repo or event path.

**DEFECT:** a step that derives the owner from the token's user instead of
`GITHUB_REPOSITORY_OWNER`; a step that ignores `GITHUB_SERVER_URL` and talks to
`github.com`; a step that reads an event field without `GITHUB_EVENT_PATH`; an
`env:` the workflow declares but no step reads.

```workflow:
{
  "file": "<repo>/.github/workflows/<workflow>.yml",
  "evidence": "live-check/03-actions-env.txt",
  "expect": {
    "env": {
      "GITHUB_SERVER_URL": "<a-non-default-enterprise-server-url>",
      "GITHUB_REPOSITORY_OWNER": "<an-owner-that-is-not-your-login>",
      "GITHUB_REPOSITORY": "<owner/repo>",
      "GITHUB_EVENT_PATH": "<the event json the runner writes>"
    },
    "stepsHonourThem": "no step falls back to github.com or to the token's user"
  }
}
```

---

### 4. Every step's command is the **real entrypoint** — module or file, not both

For each `run:` step, run its command **verbatim** from the step's own cwd and
compare it with how the code is meant to be entered. A package module invoked as
a file (`python3 pkg/render.py`) dies with
`ImportError: attempted relative import with no known parent package`, while
`python3 -m pkg.render` works — and every test that imports the function, or
runs it **as a module**, passes.

**Evidence:** `live-check/04-entrypoint.txt` — for each step: the command the
workflow runs, its exit code and output, and the invocation form the code
supports.

**DEFECT:** a step command that is not a form the code supports; a module run as
a file (or a script run as a module); a `python3 -m` form the package layout
cannot satisfy; an entrypoint that works only because your shell had the repo
root on `PYTHONPATH` or `PATH`.

```run:
{
  "argv": ["<the-step-command-verbatim>"],
  "cwd": "<the-step-working-directory>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/04-entrypoint.txt",
  "expect": {
    "exit": 0,
    "sameFormAsTheWorkflow": "do not 'helpfully' rewrite it into the form that works",
    "note": "a runner that passes a module-run-as-a-file step is itself broken"
  }
}
```

---

### 5. Check the host of every outbound call the workflow makes

List every host the workflow's steps can reach — the API bases in the code they
run, the `gh` default, any curl, any registry — and run with a non-default
server configured. Read which host each call actually used.

**Evidence:** `live-check/05-outbound-hosts.txt` — every literal host found in
the steps' code, and the host each call used at run time.

**DEFECT:** any literal forge/API host; a `gh` invocation with no `GH_HOST`
that defaults to `github.com` while the repo is enterprise-hosted; an auth check
that passes against the wrong host; a step that *prints* the configured host
beside a URL built from a different one.

```read:
{
  "path": "<the-sources-the-workflow-steps-run>",
  "evidence": "live-check/05-outbound-hosts.txt",
  "expect": {
    "noLiteralForgeHost": true,
    "everyCallDerivesFrom": "GITHUB_SERVER_URL / the configured host",
    "ghHasAnExplicitHost": "a bare gh defaults to github.com"
  }
}
```

---

### 6. Read what the workflow **published**, not "deploy succeeded"

After the workflow has run for real (locally for the steps `workflow-run` can
execute; on the forge for the ones it cannot), fetch the artifact or the served
output and read it. A green job proves the upload call returned, not that the
right bytes went up.

**Evidence:** `live-check/06-published-artifact.txt` — how you fetched it, and
the value that proves it is this build.

**DEFECT:** an artifact older than this build; an artifact missing the change;
a job green with nothing published; a publish to a path or host the spec does
not name; a `uses:` step that `workflow-run` skipped and nobody ever proved.

```read:
{
  "path": "<the-published-artifact-or-url>",
  "evidence": "live-check/06-published-artifact.txt",
  "expect": {
    "containsAValueOnlyThisBuildHas": "<a string you introduced in this build>",
    "coversEverySkippedUsesStep": "the ones workflow-run could not execute"
  }
}
```

---

### 7. Re-verify after every fix round, with **different data**

After each fix round, re-run `workflow-run` on **every** workflow the milestone
touches — not only the one that failed — with different data: a different
owner/repo, a different server URL, a different event payload, a different
record count in the inputs.

**Evidence:** `live-check/07-reverify-workflow-r2.txt` (then `-r3`, `-r4` … one file per round) — the round, the new env and
inputs, and the full step output for each workflow.

**DEFECT:** a step that passes with the first pass's env and fails with the
new; a step that passed before and fails now; a fix to one step that moved the
failure to the next; a workflow nobody re-ran because "it wasn't the one that
broke".

```workflow:
{
  "file": "<repo>/.github/workflows/<workflow>.yml",
  "evidence": "live-check/07-reverify-workflow-r2.txt",
  "expect": {
    "differentDataFromTheFirstPass": true,
    "everyWorkflowReRun": "not only the one that failed",
    "everyEarlierItemReRun": "including the ones that passed"
  }
}
```

---

### 8. Break a workflow rule with the near miss

Verify each stated rule by **breaking it**, not only by satisfying it. Send a
trigger or input that almost matches but must not fire, and record what happened
either way.

**Evidence:** `live-check/08-near-miss.txt` — the trigger or input, why it nearly
matched, and whether the workflow fired or was turned away.

**DEFECT:** a refusal that never came is a fault; a refusal you never asked for
is simply unchecked. Where the workflow has rules of its own, reach an ending
those rules call a **LOSS** or a **REFUSAL**, not only the winning one.
