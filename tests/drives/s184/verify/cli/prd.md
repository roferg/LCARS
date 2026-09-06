# Mission: Establish the foundation — Vite + React + Vitest

**Type:** feature

**Goal:** Establish the FOUNDATION of this project on Vite + React + Vitest — a running
skeleton, a working test system, and one thin vertical slice that proves the two
are genuinely connected. This mission does NOT build the product; it builds the
ground every later mission stands on, so that from here on every ticket can be
proven by running its tests.

**Acceptance Criteria:**
- The project SKELETON runs: a single documented command starts it and it shows
  something real.
- A TEST SYSTEM is installed and wired for Vite + React + Vitest: a single documented command
  runs the suite, and a human watching it can see it run.
- ONE THIN VERTICAL SLICE exists end to end — importing a CSV row and showing it — and it is covered by at
  least one REAL test that fails if the behaviour is removed.
- The test command is recorded so LCARS can run it (`lcars update --test-command
  '<command>'`), and `lcars status` reports the repo as ready.
- No feature from the project vision is implemented by this mission.

**Out of Scope:** EVERY product feature. This is the initialization mission and
its fence is deliberate: the features the captain described are recorded in the
project vision (`.git/lcars/vision.md`) and each becomes its own normal LCARS
mission once this foundation lands. Also out of scope: CI/CD pipelines,
deployment, authentication, persistence beyond what the one slice needs, and any
screen or data model that is not the slice above.

**Constraints:**
- The stack is the captain's accepted choice: **Vite + React + Vitest**. Do not substitute it.
- The test system must be a REAL runner that a human can watch execute — the
  captain is at Verify precisely to see the suite run.
- Existing code in this repo is not rewritten; the foundation is added alongside it.

## Context

The project's vision — what this is eventually FOR, and every feature the
captain named — is recorded at `.git/lcars/vision.md`. It is BACKGROUND ONLY.
Nothing in it is in scope for this mission, and it is deliberately not restated
here: a feature list quoted into an initialization mission is a feature list a
planner will try to satisfy. Read it for taste (naming, tone, rough shape); take
the scope from the sections above and nowhere else.
