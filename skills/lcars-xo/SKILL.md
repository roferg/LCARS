---
name: lcars-xo
description: Engage, stand down, and inspect Number One — the AI first officer that holds a Mission on the captain's behalf. `lcars xo on [--engine copilot|claude] [--model M]` turns Number One ON for this repo, recording the choice in `.git/lcars/config.json` as a one-line `numberOne` block; with no `--engine` and a terminal it opens a picker naming the engines installed on this machine, and with no terminal it refuses loudly rather than choosing in silence. `lcars xo off` stands the repo down and hands the conn back on every engaged Mission; `lcars xo off <mission>` opts one Mission out and stands just that one down (signalling its recorded worker pid, recording `stood-down` and a note); `lcars xo on <mission>` clears that per-mission opt-out. Bare `lcars xo` prints the status table — every Mission with its stage, Number One's RECORDED status (engaged / finished / escalated / answered / stood-down / opted-out) and its note. While a Mission is engaged the write verbs (approve, feedback, respond, log, pause, resume, resolve-logs) and the viewscreen's matching endpoints refuse with ONE sentence, because Number One is already acting through them on the captain's behalf. Use when the captain runs `lcars xo`, says "engage Number One", "turn the first officer on/off", "stand Number One down", "who has the conn", or asks what Number One is doing.
---

# lcars xo — Number One

**Number One is the AI first officer.** With it engaged, LCARS does not just stop
at a gate and wait: it takes the conn on the captain's behalf, works the gate
through the ordinary verbs, and hands the conn back with a report.

`xo.sh` does all of the mechanical work. It asks no model anything — **the
worker reasons, the skill executes** (captain ruling, 2026-09-11). You (Claude)
run it and read out what it printed.

## The verbs

```bash
bash skills/lcars-xo/xo.sh                          # the status table
bash skills/lcars-xo/xo.sh on --engine copilot      # engage for this repo
bash skills/lcars-xo/xo.sh on                       # …with the picker
bash skills/lcars-xo/xo.sh off                      # stand the repo down
bash skills/lcars-xo/xo.sh off <mission>            # opt ONE mission out
bash skills/lcars-xo/xo.sh on  <mission>            # clear that opt-out
```

The front door routes `lcars xo …` here through an explicit delegator in
`skills/lcars/lcars.sh` — **not** through smart-default routing, because a bare
`lcars xo` is a READ and the router would otherwise take `xo` for a Mission
selector and try to drive something.

## The engine picker

It **names engines and nothing else**: `copilot` and `claude`, each *installed*
or *not installed*, detected through the one shared probe
(`lcars_engine_available`, `skills/lcars-init/lcars-common.sh`).

**There are no pricing words in this product — not "free", not "billed", not
"costs"** (captain ruling, 2026-09-11). Not everyone's situation is the
captain's, and a product that prices a choice for you is making the choice for
you. Do not add them to any surface, ever.

**No terminal and no `--engine` is a loud refusal**, the `lcars adopt`
precedent. Choosing an engine in silence *is* the defect; failing loudly is the
cure.

## The two records

Everything downstream reads these, and nothing infers them from prose — the
producer records, the surface displays.

**`.git/lcars/config.json` — the repo switch, ON ONE LINE:**

```json
  "numberOne": {"enabled": true, "engine": "copilot"}
```

One line is load-bearing twice over. `lcars_config_merge` preserves an existing
raw value only when it sits on a single line, and it **deletes** any top-level
key missing from `DESIRED_CONFIG` — so `numberOne` is listed in both
`lcars-update/update.sh` and `lcars-init/init.sh`. That second rule is the exact
failure S196 paid for with `cloneId`.

**`state.json` — the per-mission record, AT THE TOP OF THE FILE:**

```json
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "…", "note": "…"}
```

`status` is one of `engaged`, `finished`, `escalated`, `answered`,
`stood-down`. `optOut: true` means "never engage here". The key goes at the top
because a last-key corruption bug is latent in the state writers (the S189
rule) — keeping new keys off the end keeps it latent.

## The engaged lock

While `status` is `engaged`, these refuse with **one sentence**:

```
Number One is engaged on this mission on your behalf — stand it down (lcars xo off <id>) to act yourself
```

`lcars approve`, `lcars feedback`, `lcars respond answer`, `lcars log`,
`lcars pause`, `lcars resume`, `lcars resolve-logs` — and the viewscreen's
matching endpoints, with a 403 carrying the same bytes.

`lcars run` and `lcars xo` are **exempt**: Number One's own actions go through
them, so locking them would lock Number One out of itself. `start` is likewise
absent from the daemon's set — an engaged mission is already being driven.

It is a **second reason on the existing owner-lock seam**
(`skills/lcars-run/ownership.sh`), not a new mechanism, and it keeps that seam's
posture exactly: every uncertain case proceeds (no state file, no key, an
unreadable value), one sentence pinned byte-identical everywhere, and
`LCARS_XO_ENFORCE=0` bypasses it for harness debugging.

## Standing down

`lcars xo off <mission>` **signals first, then records**: it TERMs the pid in
the mission's `xo.pid` (best effort — a stale pid file is not a reason to refuse
to hand the conn back, and nothing is ever KILLed, so a worker gets to finish
its own cleanup), then writes `stood-down` plus the note
`Number One stood down <time> · you have the conn`, and the lock lifts.

A repo-level `lcars xo off` does that for every engaged mission and flips
`enabled` to `false` — **keeping the recorded engine**, because the captain
turned Number One off, he did not un-choose his engine.

## Related

- `skills/lcars-run/ownership.sh` — `lcars_xo_lock_reason`, `xo-lock-reason`
- `skills/lcars-init/lcars-common.sh` — `lcars_engine_available`,
  `lcars_xo_default_engine`, `lcars_config_set_or_add_raw`, `lcars_config_get_raw`
- `tests/lcars-xo.test.sh`, `tests/ownership.test.sh`,
  `tests/lcars-update.test.sh`, `web/tests/test_xo_lock_endpoints.py`
