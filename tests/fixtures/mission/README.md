# tests/fixtures/mission — one SYNTHETIC, realistic LCARS mission on disk

A mission directory shaped exactly like the ones `.git/lcars/missions/<id>/`
holds, so a suite can mount a *rich* mission without reaching outside the repo.
It carries the four artifacts the delegation seam reads — `state.json`,
`prd.md`, `plan.json` and a `tickets/` directory — and the PRD carries both a
literal `**Goal:**` paragraph and an explicit `**Acceptance Criteria:**` list,
which is the richest shape `delegate` has a code path for (`goalSource =
prd-acceptance`).

**Why it is committed.** `tests/delegation.test.sh`'s D1 assertions need a
mission with real artifacts in it. Building one by copying a real mission out of
`~/Projects/lcars-mission-archive/` — which is how the first rig did it — makes
the suite depend on a path outside this repo that will not exist for anybody who
clones LCARS. CLAUDE.md's golden rule is that LCARS must stay
clonable-and-testable, so the fixture ships.

**It is OBVIOUSLY SYNTHETIC and contains nobody's real work.** The ids are
`fixture-*`, the feature is invented, and no content was copied out of a real
mission. It is inert data: every file here is mode 644 and nothing in it is
executable, which is the contract `tests/fixtures/MANIFEST` enforces.

**`@MISSION_ID@` is a placeholder.** A mission's directory name *is* its id, and
a suite mounts this fixture under whatever id it is testing, so `state.json`
substitutes the id rather than hard-coding one. `tests/delegation.test.sh`'s
`new_mission_fixture` does the copy and the substitution.
