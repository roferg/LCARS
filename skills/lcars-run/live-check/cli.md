# Live check — a CLI surface

Run every item from the **detached** worktree with the **throwaway HOME** that
`autopilot.sh live-check <mission> --type cli` prints. Never from the checked-out
branch, and never with your own `HOME`: a config you wrote earlier makes a
product that cannot be configured look configured.

Each item is an action, the evidence to capture, and what counts as a defect.
Both forms are binding — see [`README.md`](README.md).

---

### 1. Run `--help` and compare it against the subcommands that exist

Run the CLI with `--help` (and with no arguments at all). Then list the
subcommands the code actually dispatches, and compare the two lists by eye.

**Evidence:** `live-check/01-help.txt` — the command, its exact output, and
underneath it the list of subcommands you found in the source.

**DEFECT:** any subcommand that works but is missing from `--help`; any
subcommand listed in `--help` that does not exist; a non-zero exit from
`--help`; a `--help` that is accepted as *data* (a note title, a filename)
instead of as a flag.

```run:
{
  "argv": ["<cli>", "--help"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/01-help.txt",
  "expect": {
    "exit": 0,
    "helpForm": "--help, or this product's own form for it (`help`, `-h`) — substitute it if the product has no flags",
    "stdoutListsEverySubcommand": "<every subcommand the CLI dispatches>",
    "note": "a subcommand that works but is absent from --help is a DEFECT"
  }
}
```

---

### 2. Give it bad input, and no input

Run each subcommand with bad input: an empty string, a missing required
argument, a flag where a value belongs, a path that does not exist, a value of
the wrong type.

**Evidence:** `live-check/02-bad-input.txt` — one block per case: the command,
the exit code, stdout and stderr.

**DEFECT:** a crash with a raw traceback instead of a message; a non-zero exit
with no explanation on stderr; **a zero exit on input it did not accept**; bad
input stored as if it were good (an empty record, a flag saved as a title).

```run:
{
  "argv": ["<cli>", "<subcommand>", ""],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/02-bad-input.txt",
  "expect": {
    "exitNonZero": true,
    "stderrExplains": "why the input was refused",
    "note": "a traceback, or exit 0 on refused input, is a DEFECT"
  }
}
```

---

### 3. Do the thing the product is for, from a clean HOME

Run the real happy path end to end, with nothing seeded: create, then list, then
whatever the milestone's PRD says the user does next. Read every line it prints.

**Evidence:** `live-check/03-happy-path.txt` — every command and its exact
output, in the order you ran them.

**DEFECT:** a first run that fails because nothing is seeded (no config, no
directory, no file — the product must create what it needs); output that names a
path, id or host that is not the one it actually used; a success message for
work that did not happen.

```run:
{
  "argv": ["<cli>", "<the-main-verb>", "<realistic-value>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"},
  "evidence": "live-check/03-happy-path.txt",
  "expect": {
    "exit": 0,
    "createsWhatItNeeds": "no manual seeding before the first run",
    "outputMatchesReality": "every id, path and host it prints is the one it used"
  }
}
```

---

### 4. Two actors — two HOMEs, two laptops

Repeat the happy path as a **second** actor with its own throwaway `HOME`, then
have the two interact: the same name from both, a replace/overwrite from one
while the other holds an older version, a read by one of what the other wrote.

**Evidence:** `live-check/04-two-actors.txt` — both transcripts, labelled
`ACTOR A (HOME=…)` and `ACTOR B (HOME=…)`, and the interaction at the end.

**DEFECT:** either actor seeing the other's state through a shared cache or a
hardcoded path; a collision that silently overwrites instead of refusing or
versioning; an identity read from the machine rather than from the actor's HOME.

```run:
{
  "argv": ["<cli>", "<the-main-verb>", "<the-same-value-actor-A-used>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<second-throwaway-home>"},
  "evidence": "live-check/04-two-actors.txt",
  "expect": {
    "noCrossContamination": "actor B sees none of actor A's state",
    "collisionHandled": "refused or versioned, never a silent overwrite"
  }
}
```

---

### 5. Make the identities that usually coincide differ, on purpose

On a dev box the repo **owner** equals your **login**, and a draft's **name**
equals its **title**. Choose values where they differ — owner `acme`, login
`roferg`; name `q3-notes`, title `Q3 notes` — and run the happy path again.

**Evidence:** `live-check/05-identities-differ.txt` — the values you chose, the
commands, and every place the output or the stored record shows one standing in
for the other.

**DEFECT:** the owner rendered where the login belongs (or the reverse); a slug
used as a display title; a record keyed by the wrong one of the pair; a lookup
that works only because the two happened to be equal.

The owner and the title are **placeholders, not flags**: substitute whatever
shape this product takes them in — two positionals, `--owner`/`--title`, an
env var, a prompt. A product with no flags at all must be able to run this item.

```run:
{
  "argv": ["<cli>", "<the-main-verb>", "<the-owner-value-in-THIS-product's-own-argument-shape: a positional, a flag pair, or omitted when it comes from the env>", "<the-title-value-in-THIS-product's-own-argument-shape>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>", "<LOGIN_ENV_VAR>": "<login>", "<OWNER_ENV_VAR-if-that-is-how-this-product-takes-it>": "<owner-not-equal-to-login>"},
  "evidence": "live-check/05-identities-differ.txt",
  "expect": {
    "ownerNotEqualToLogin": "<owner-not-equal-to-login> vs <login>",
    "titleNotEqualToName": "<title-not-equal-to-name>",
    "ownerAndLoginNeverSwapped": true,
    "nameAndTitleNeverSwapped": true,
    "argvIsTHISProduct's": "every entry above is a placeholder — fill it with the product's own form (positional, flag, or env var). No template here bakes in a flag the product may not have.",
    "note": "two bugs on the modelled weekend were exactly this"
  }
}
```

---

### 6. Follow one record **end to end**, through every real half

Take a single record you just created and follow it through every stage it
passes: the CLI's stored file → whatever transforms it → the artifact → the
rendered surface. At each hop, print the record **as that stage sees it** and
compare the field names and values with the previous hop.

This is the item that catches a producer writing `origin` while the consumer
reads `host` with a default — two halves that each pass their own tests and
disagree only in production. **Both halves must be real.** A hand-written
fixture between them is the bug's hiding place.

**Evidence:** `live-check/06-end-to-end.txt` — the record at every hop, in
order, with the hop named.

**DEFECT:** any field renamed, dropped or defaulted between hops; a consumer
falling back to a default where the producer did supply a value; a value that
changes shape (string vs list, id vs slug) without a conversion anyone declared.

```run:
{
  "argv": ["<cli>", "<the-main-verb>", "<a-value-you-will-recognise>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>", "<HOST_ENV_VAR>": "<a-host-that-is-not-the-default>"},
  "evidence": "live-check/06-end-to-end.txt",
  "expect": {
    "followEveryHop": "stored record -> transform -> artifact -> rendered surface",
    "bothHalvesReal": "no hand-written fixture between producer and consumer",
    "sameFieldNames": "no field renamed, dropped or silently defaulted"
  }
}
```

---

### 7. Check the host of every outbound call

Grep the milestone's diff for every URL, host and API base it builds, then run
the commands that make those calls with the host **configured to something that
is not the default** and read the host each one actually used.

Three separate hardcoded-`github.com` bugs got past a green suite on the
modelled weekend; one of them printed the *configured* host beside the *wrong*
URL, which is what makes it easy to skim past.

**Evidence:** `live-check/07-outbound-hosts.txt` — the grep output (every
literal host in the diff), then each command and the host it used.

**DEFECT:** any literal forge/API host in the source; a call that reaches the
default host while a non-default one is configured; a line that *reports* the
configured host next to a URL built from a different one.

```run:
{
  "argv": ["<cli>", "<a-subcommand-that-makes-an-outbound-call>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>", "<HOST_ENV_VAR>": "<a-host-that-is-not-the-default>"},
  "evidence": "live-check/07-outbound-hosts.txt",
  "expect": {
    "noLiteralHostInSource": true,
    "everyCallUsesTheConfiguredHost": "<a-host-that-is-not-the-default>",
    "note": "reporting the right host beside a wrong URL is still a DEFECT"
  }
}
```

---

### 8. Re-verify after every fix round, with **different data**

After each fix round, run items 1–7 again on the fixed tree with **deliberately
different data** from the first pass: different titles, a different owner, a
different host, a different order of operations. Re-running the first pass's
exact inputs proves only that one input was patched.

**Evidence:** `live-check/08-reverify-cli-r2.txt` (then `-r3`, `-r4` … one file per round) — the round number, the new
values, and the re-run of every item that had failed **plus** every item that
had passed (a fix that breaks a neighbour is the regression this catches).

**DEFECT:** a fix that holds for the original data but not the new; any item
that passed before and fails now; a fix that only moved the failure one hop
along the chain in item 6.

```run:
{
  "argv": ["<cli>", "<the-main-verb>", "<a-value-you-did-NOT-use-in-the-first-pass>"],
  "cwd": "<worktree>",
  "env": {"HOME": "<a-fresh-throwaway-home>"},
  "evidence": "live-check/08-reverify-cli-r2.txt",
  "expect": {
    "differentDataFromTheFirstPass": true,
    "everyEarlierItemReRun": "including the ones that passed",
    "note": "re-running the first pass's inputs proves only that one input was patched"
  }
}
```
