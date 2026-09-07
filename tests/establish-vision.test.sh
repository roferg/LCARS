#!/usr/bin/env bash
#
# S184 — ESTABLISH VISION: the day-zero front door and the initialization
# mission it files.
#
# Three things are under test, and they are deliberately separate:
#
#   1. THE FACTS. `establish-vision.sh --facts` is the ONE detector behind the
#      `untested` screen's FOUND panel — a REAL stack and a REAL source-file
#      count, never a hardcoded string. Same repo, same numbers, whichever
#      front door asks.
#
#   2. THE SCOPE FENCE. The session's real risk is a vision that specifies
#      twelve features. The fence is stated in the GRILL'S OWN WORDS
#      (`--brief`), baked into the PRD the harness assembles (`--prd`, so it
#      cannot be talked out of it by a model), and the captain's features are
#      DEFERRED into the vision doc — never into the initialization mission.
#
#   3. THE MISSION TYPE + THE OVERRIDE. The filed mission is marked
#      `missionType: "initialization"` (S185 consumes it), it gets past the
#      S183 gate that refuses every NORMAL mission on this repo, and the stack
#      that lands in the PRD is the one the captain ACCEPTED — a recommendation
#      he cannot refuse is a decision.
#
# ZERO worker spend: every drive runs under the S182 rig's PATH shim with
# COUNTING fake `claude`/`copilot` binaries and its SPEND FUSE armed.
#
# Usage: bash tests/establish-vision.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV="$REPO_ROOT/skills/lcars-init/establish-vision.sh"
GATE="$REPO_ROOT/skills/lcars-init/foundation-gate.sh"
FILE_SH="$REPO_ROOT/skills/lcars-file/file.sh"
LCARS_SH="$REPO_ROOT/skills/lcars/lcars.sh"

LCARS_SRC="$REPO_ROOT"
# shellcheck source=drives/s182/rig.sh
. "$REPO_ROOT/tests/drives/s182/rig.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
SHIM=""
cleanup() { rm -rf "$TMPROOT"; [ -n "$SHIM" ] && rm -rf "$SHIM"; }
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

CALLS="$TMPROOT/worker-calls.log"; : >"$CALLS"
SHIM="$(make_shim "$CALLS")"
fuse "$SHIM" || { echo "SPEND FUSE TRIPPED — refusing to run"; exit 1; }
spawns() { awk '$1=="SPAWN"' "$CALLS" 2>/dev/null | wc -l | tr -d ' '; }

export PATH="$SHIM:$PATH"
export LCARS_GH_BIN="$SHIM/gh-missing"   # no GitHub in these drives

new_repo() { # [name] → an initialized-but-empty git repo (NO lcars config)
  local repo; repo="$(mktemp -d "$TMPROOT/${1:-repo}.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  echo "$repo"
}

jget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = (d or {}).get(k)
print("" if d is None else (d if isinstance(d,str) else json.dumps(d)))' "$1"; }

echo "── S184 · G1 · THE FACTS (real detection, never a hardcoded string) ──"

BLANK="$(new_repo blank)"
FACTS_BLANK="$( cd "$BLANK" && bash "$EV" --facts )"
check "G1a blank repo reports foundation=greenfield" \
  "[ \"\$(printf '%s' \"\$FACTS_BLANK\" | jget foundation)\" = greenfield ]"
check "G1b blank repo reports ZERO source files" \
  "[ \"\$(printf '%s' \"\$FACTS_BLANK\" | jget sourceFiles)\" = 0 ]"
check "G1c blank repo reports NO test runner" \
  "[ -z \"\$(printf '%s' \"\$FACTS_BLANK\" | jget testRunner)\" ]"

# a REAL react-shaped repo with code and no test system.
REACT="$(new_repo react)"
mkdir -p "$REACT/src/components"
cat >"$REACT/package.json" <<'JSON'
{ "name": "app", "version": "0.0.0",
  "scripts": { "dev": "vite", "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0" } }
JSON
printf 'export default function App(){return null}\n' >"$REACT/src/App.jsx"
printf 'export const x = 1\n' >"$REACT/src/main.jsx"
printf '.a{color:red}\n' >"$REACT/src/index.css"
printf 'export const Btn = 1\n' >"$REACT/src/components/Btn.jsx"

FACTS_REACT="$( cd "$REACT" && bash "$EV" --facts )"
check "G1d code-without-tests reports foundation=untested" \
  "[ \"\$(printf '%s' \"\$FACTS_REACT\" | jget foundation)\" = untested ]"
check "G1e the REAL stack is named (js), not guessed" \
  "[ \"\$(printf '%s' \"\$FACTS_REACT\" | jget stack)\" = js ]"
# FIX ROUND 1 / D4: the label is FRAMEWORK-level, not the classifier key and
# not the coarse ecosystem name. This fixture declares react and no bundler.
check "G1f the stack gets a HUMAN, framework-level label — not the classifier key" \
  "[ \"\$(printf '%s' \"\$FACTS_REACT\" | jget stackLabel)\" = React ]"
check "G1g the REAL source-file count is counted (4 sources here)" \
  "[ \"\$(printf '%s' \"\$FACTS_REACT\" | jget sourceFiles)\" -ge 4 ]"
check "G1h the count EXCLUDES node_modules" \
  "mkdir -p '$REACT/node_modules/junk' && for i in 1 2 3 4 5 6 7 8 9; do printf 'x\n' >'$REACT/node_modules/junk/j'\$i'.js'; done; \
   [ \"\$( cd '$REACT' && bash '$EV' --facts | jget sourceFiles )\" -lt 9 ]"
check "G1i a repo WITH a foundation is not front-door material" \
  "printf '{\"name\":\"a\",\"scripts\":{\"test\":\"vitest run\"},\"devDependencies\":{\"vitest\":\"^1\"}}\n' >'$REACT/package.json'; \
   cd '$REACT' && bash '$EV' --facts | jget frontDoor | grep -q false"
# restore the untested shape for later gates
printf '{ "name": "app", "scripts": { "dev": "vite" }, "dependencies": { "react": "^18.2.0" } }\n' >"$REACT/package.json"

echo "── S184 · G2 · THE SCOPE FENCE, in the grill's own words ──"

BRIEF="$( cd "$BLANK" && bash "$EV" --brief )"
check "G2a the brief NAMES the foundation as the whole scope" \
  "printf '%s' \"\$BRIEF\" | grep -qi 'foundation'"
check "G2b the brief FORBIDS building the product's features" \
  "printf '%s' \"\$BRIEF\" | grep -qi 'not build\|never build\|do not build\|must not'"
check "G2c the brief names the three deliverables (skeleton, test system, one slice)" \
  "printf '%s' \"\$BRIEF\" | grep -qi skeleton && printf '%s' \"\$BRIEF\" | grep -qi 'test system' && printf '%s' \"\$BRIEF\" | grep -qi 'slice'"
check "G2d the brief says DEFERRED features go to the vision doc, not the mission" \
  "printf '%s' \"\$BRIEF\" | grep -qi 'defer'"
check "G2e the brief tells the grill to RECOMMEND, and that the captain may refuse" \
  "printf '%s' \"\$BRIEF\" | grep -qi 'recommend' && printf '%s' \"\$BRIEF\" | grep -qi 'override\|refuse\|theirs\|their choice'"
check "G2f the untested brief does NOT re-ask what they are building" \
  "cd '$REACT' && bash '$EV' --brief | grep -qi 'already has code\|can see the code\|do not ask what'"

echo "── S184 · G3 · THE PRD IS FOUNDATION-SCOPED, DETERMINISTICALLY ──"

IDEA="$TMPROOT/idea.md"
cat >"$IDEA" <<'TXT'
A website that does personal finance stuff. I want budgets, a spending
dashboard, bank sync via Plaid, shared household accounts, CSV import,
recurring bill reminders, savings goals, net-worth charts, tax export,
multi-currency, a mobile app and dark mode.
TXT
REASONS="$TMPROOT/reasons.txt"
cat >"$REASONS" <<'TXT'
Your dashboard and charts are a browser UI, so a component framework earns its keep.
"Bank sync" means async data you will want to fake in a test, and Vitest mocks modules natively.
TXT
DEFERRED="$TMPROOT/deferred.txt"
printf 'budgets\nspending dashboard\nPlaid bank sync\nshared household accounts\nCSV import\n' >"$DEFERRED"

PRD="$( cd "$BLANK" && bash "$EV" --prd --idea "$IDEA" --stack 'Vite + React + Vitest' \
          --reasons "$REASONS" --deferred "$DEFERRED" --slice 'the app boots and renders its shell' )"
check "G3a the PRD is a valid LCARS PRD (all six required sections)" \
  "for s in '# Mission' '**Type:**' '**Goal:**' '**Acceptance Criteria:**' '**Out of Scope:**' '**Constraints:**'; do printf '%s' \"\$PRD\" | grep -qF \"\$s\" || exit 1; done"
check "G3b the ACCEPTED stack is what lands in the PRD" \
  "printf '%s' \"\$PRD\" | grep -qF 'Vite + React + Vitest'"
check "G3c the PRD's scope is the foundation (skeleton + test system + one slice)" \
  "printf '%s' \"\$PRD\" | grep -qi skeleton && printf '%s' \"\$PRD\" | grep -qi 'test system'"
check "G3d NONE of the captain's deferred features reach the PRD" \
  "! printf '%s' \"\$PRD\" | grep -qi 'plaid' && ! printf '%s' \"\$PRD\" | grep -qi 'net-worth' && ! printf '%s' \"\$PRD\" | grep -qi 'multi-currency'"
check "G3e Out of Scope says the features are deferred, by name of the mechanism" \
  "printf '%s' \"\$PRD\" | sed -n '/Out of Scope/,/Constraints/p' | grep -qi 'feature'"

echo "── S184 · G4 · THE VISION DOC IS WHERE THE FEATURES GO ──"

( cd "$BLANK" && bash "$EV" --write-vision --idea "$IDEA" --stack 'Vite + React + Vitest' \
    --reasons "$REASONS" --deferred "$DEFERRED" --slice 'the app boots' >/dev/null )
VISION="$BLANK/.git/lcars/vision.md"
check "G4a the vision doc is written somewhere durable under .git/lcars/" \
  "[ -f '$VISION' ]"
check "G4b it carries the captain's idea VERBATIM" \
  "grep -qi 'personal finance stuff' '$VISION'"
check "G4c it records the chosen stack and the reasons" \
  "grep -qF 'Vite + React + Vitest' '$VISION' && grep -qi 'Vitest mocks modules' '$VISION'"
check "G4d the DEFERRED features live here — every one of them" \
  "for f in budgets Plaid 'CSV import'; do grep -qi \"\$f\" '$VISION' || exit 1; done"
check "G4e it is inside .git/ so the target repo's working tree stays clean" \
  "[ -z \"\$( cd '$BLANK' && git status --porcelain )\" ]"

# S184 fix round 2, D8 — THE `untested` DOOR NEVER ASKS FOR AN IDEA. It can see
# the code, so screen 2 REPORTS instead of asking, and `--idea` arrives EMPTY.
# The doc still printed the heading `## What the captain asked for` with nothing
# under it — a durable record with a blank in it, which reads as "he said
# nothing" when the truth is "he was never asked".
UNT="$(new_repo untested-vision)"
: > "$UNT/empty-idea.txt"
( cd "$UNT" && bash "$EV" --write-vision --idea "$UNT/empty-idea.txt" \
    --stack 'Vitest' --slice 'the app boots' >/dev/null )
UVISION="$UNT/.git/lcars/vision.md"
check "G4f an EMPTY idea never leaves the section blank" \
  "sed -n '/## What the captain asked for/,/^## /p' '$UVISION' | sed '1d;/^## /d' | grep -q '[^[:space:]]'"
check "G4g …it SAYS the project was read from the code instead" \
  "sed -n '/## What the captain asked for/,/^## /p' '$UVISION' | grep -qi 'read from the code'"
check "G4h a REAL idea is still carried verbatim" \
  "grep -qi 'personal finance stuff' '$VISION'"

echo "── S184 · G5 · THE INITIALIZATION MISSION (and the gate it must pass) ──"

before="$(spawns)"
OUT="$( cd "$BLANK" && LCARS_GH_BIN="$SHIM/nope" bash "$EV" --file --idea "$IDEA" \
          --stack 'Vite + React + Vitest' --reasons "$REASONS" --deferred "$DEFERRED" \
          --slice 'the app boots and renders its shell' 2>&1 )"
rc=$?
MID="$(printf '%s' "$OUT" | sed -n 's/.*MISSION_ID=\([A-Za-z0-9_-]*\).*/\1/p' | head -1)"
STATE="$BLANK/.git/lcars/missions/$MID/state.json"
check "G5a the filing SUCCEEDS on a repo the S183 gate refuses normal missions on" \
  "[ $rc -eq 0 ] && [ -n '$MID' ] && [ -f \"\$STATE\" ]"
check "G5b it is marked missionType=initialization (S185 consumes this)" \
  "grep -q '\"missionType\"[[:space:]]*:[[:space:]]*\"initialization\"' \"\$STATE\""
check "G5c a NORMAL filing on the same repo is still REFUSED with exit 4" \
  "( cd '$BLANK' && bash '$FILE_SH' --park 'just a normal idea' >/dev/null 2>&1 ); [ \$? -eq 4 ]"
check "G5d the mission's prd.md is the foundation-scoped one" \
  "grep -qi skeleton \"$BLANK/.git/lcars/missions/\$MID/prd.md\" && ! grep -qi plaid \"$BLANK/.git/lcars/missions/\$MID/prd.md\""
# The FRONT DOOR itself is free — facts, the brief, the PRD and the vision doc
# are pure harness work and hire nobody. Filing then runs the SAME end-of-Align
# cost estimator every `lcars file` runs (it is not new spend, and it is what
# puts a cost pill on the captain's card), so the assertion is: nothing beyond
# that ONE estimator call, and every call went to a COUNTING FAKE (the fuse).
check "G5e the front door itself hires NOBODY (facts/brief/prd/vision)" \
  "b=\$(spawns); ( cd '$BLANK' && bash '$EV' --facts >/dev/null && bash '$EV' --brief >/dev/null \
     && bash '$EV' --prd --idea '$IDEA' --stack x >/dev/null ); [ \"\$(spawns)\" -eq \"\$b\" ]"
# `--file` runs AFTER the grill, so it must not hire an interviewer of its own:
# the only workers it may cause are the ones EVERY `lcars file` causes (the
# context-pack generator and the cost estimator). Measured by argv, not by count
# — a count would silently absorb a new hire the day the estimator stops retrying.
check "G5f filing hires NO second interviewer (no grill worker in the argv)" \
  "! grep -q 'FOUNDATION BRIEF' '$CALLS.argv' 2>/dev/null"
check "G5g every worker call went to a COUNTING FAKE (the spend fuse held)" \
  "fuse '$SHIM'"

echo "── S184 · G6 · THE OVERRIDE IS WHAT LANDS (a recommendation, not a decision) ──"

OVR="$(new_repo ovr)"
( cd "$OVR" && bash "$EV" --file --idea "$IDEA" --stack 'SvelteKit + Playwright' \
    --reasons "$REASONS" --deferred "$DEFERRED" --slice 'boots' >/dev/null 2>&1 )
OMID="$(ls "$OVR/.git/lcars/missions" 2>/dev/null | head -1)"
check "G6a the captain's OVERRIDE stack is in the filed PRD" \
  "grep -qF 'SvelteKit + Playwright' \"$OVR/.git/lcars/missions/\$OMID/prd.md\""
check "G6b and in the vision doc" \
  "grep -qF 'SvelteKit + Playwright' '$OVR/.git/lcars/vision.md'"

echo "── S184 · G7 · THE CLI FRONT DOOR — `lcars` STARTS THE CONVERSATION ──"

FD="$(new_repo cli)"
CLI_OUT="$( cd "$FD" && LCARS_VERSION_CHECK=0 bash "$LCARS_SH" 2>&1 )"
check "G7a `lcars` on a foundationless repo routes to the VISION flow" \
  "printf '%s' \"\$CLI_OUT\" | grep -q 'ROUTE: vision'"
check "G7b it ASKS rather than refusing — the screen-1 question is on screen" \
  "printf '%s' \"\$CLI_OUT\" | grep -qi 'what are we building'"
check "G7c it does NOT print the S183 refusal wording" \
  "! printf '%s' \"\$CLI_OUT\" | grep -q 'NO TEST FOUNDATION'"
check "G7d it carries the SAME brief the viewscreen grill runs under" \
  "printf '%s' \"\$CLI_OUT\" | grep -qi 'foundation' && printf '%s' \"\$CLI_OUT\" | grep -qi 'slice'"

# the untested variant must NOT ask what we are building — it can see.
CLI_UNT="$( cd "$REACT" && LCARS_VERSION_CHECK=0 bash "$LCARS_SH" 2>&1 )"
check "G7e on `untested` it REPORTS what it found instead of asking" \
  "printf '%s' \"\$CLI_UNT\" | grep -qi 'no test system' && ! printf '%s' \"\$CLI_UNT\" | grep -qi 'what are we building'"
check "G7f and it promises the captain's code is not touched" \
  "printf '%s' \"\$CLI_UNT\" | grep -qi 'not touched\|is not touched\|untouched'"

echo "── S184 · G8 · THE NARROW RULE — a foundationless repo WITH missions ──"
# Flappy-Bird, measured on the captain's machine: an INITIALIZED repo,
# foundation=untested, TWO real missions on its board. The front door replaces
# the board only when there is NOTHING TO PUT ON IT.

WITHM="$(new_repo withm)"
mkdir -p "$WITHM/src" && printf 'const a=1\n' >"$WITHM/src/a.js"
printf '{"name":"g","scripts":{"dev":"x"}}\n' >"$WITHM/package.json"
mkdir -p "$WITHM/.git/lcars/missions/m-0001"
printf '{"id":"m-0001","stage":"plan","title":"a real mission"}\n' \
  >"$WITHM/.git/lcars/missions/m-0001/state.json"
CLI_WM="$( cd "$WITHM" && LCARS_VERSION_CHECK=0 bash "$LCARS_SH" 2>&1 )"
check "G8a `lcars` does its NORMAL thing — it does not restart the vision flow" \
  "! printf '%s' \"\$CLI_WM\" | grep -q 'ROUTE: vision'"
check "G8b the facts payload says frontDoor=false when missions exist" \
  "cd '$WITHM' && bash '$EV' --facts | jget frontDoor | grep -q false"
check "G8c but the foundation VERDICT is unchanged — S183's lock still applies" \
  "cd '$WITHM' && bash '$EV' --facts | jget foundation | grep -q untested"

echo "── S184 · G9 · FIX ROUND 1 · D4 — the FOUND panel names the FRAMEWORK ──"
# `detect_stack` answers `js`, which is true and uselessly coarse on the one
# panel whose whole job is to prove LCARS looked at the captain's code. The
# classifier is NOT touched; the LABEL reads the manifest it already found.

mk_js() { # name  package.json-body  [tsconfig]
  local r; r="$(new_repo "$1")"
  printf '%s\n' "$2" >"$r/package.json"
  [ -n "${3:-}" ] && printf '{}\n' >"$r/tsconfig.json"
  mkdir -p "$r/src" && printf 'export const a=1\n' >"$r/src/a.js"
  echo "$r"
}
label() { ( cd "$1" && bash "$EV" --facts ) | jget stackLabel; }

RVT="$(mk_js rvt '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"vite":"^5","typescript":"^5"}}' ts)"
check "G9a the captain's measured case reads React + Vite · TypeScript" \
  "[ \"\$(label '$RVT')\" = 'React + Vite · TypeScript' ]"

RONLY="$(mk_js ronly '{"name":"a","dependencies":{"react":"^18"}}')"
check "G9b react with no bundler reads React" \
  "[ \"\$(label '$RONLY')\" = 'React' ]"

VW="$(mk_js vw '{"name":"a","dependencies":{"vue":"^3"},"devDependencies":{"webpack":"^5"}}')"
check "G9c vue + webpack is named too (not a react-only special case)" \
  "[ \"\$(label '$VW')\" = 'Vue + Webpack' ]"

NX="$(mk_js nx '{"name":"a","dependencies":{"next":"^14","react":"^18"}}')"
check "G9d next beats the react it is built on (most specific wins)" \
  "[ \"\$(label '$NX')\" = 'Next.js' ]"

PLAIN="$(mk_js plain '{"name":"a","dependencies":{"express":"^4"}}')"
check "G9e nothing specific found ⇒ the honest coarse fallback, never a guess" \
  "[ \"\$(label '$PLAIN')\" = 'JavaScript / Node' ]"

TSONLY="$(mk_js tsonly '{"name":"a","dependencies":{"express":"^4"}}' ts)"
check "G9f typescript alone is still worth saying" \
  "[ \"\$(label '$TSONLY')\" = 'Node · TypeScript' ]"

NOPKG="$(new_repo nopkg)"
check "G9g a repo with no package.json never crashes the panel" \
  "( cd '$NOPKG' && bash '$EV' --facts >/dev/null )"

check "G9h the CLASSIFIER is untouched — the stack key is still js" \
  "[ \"\$( cd '$RVT' && bash '$EV' --facts | jget stack )\" = js ]"

echo "── S184 · G10 · FIX ROUND 1 · D3 — the slice is a NOUN PHRASE ──"
# A live model's output shape is a lottery (S175): it hands back a whole
# sentence restating the label about as often as the phrase the template needs.
# Measured on the drive: "One thin vertical slice that proves both: A running
# app, … and one thin slice that proves both — importing a CSV row and showing
# it.." — the label twice and a doubled full stop.

PROSE='A running app, a working test system, and one thin slice that proves both — importing a CSV row and showing it.'
SP="$( cd "$BLANK" && bash "$EV" --prd --idea "$IDEA" --stack 'X + Y' --slice "$PROSE" )"
check "G10a a PROSE slice does not restate the label in the PRD" \
  "[ \"\$(printf '%s' \"\$SP\" | grep -ci 'thin vertical slice')\" -le 2 ] \
   && printf '%s' \"\$SP\" | grep -q 'importing a CSV row and showing it'"
check "G10b …and never doubles a full stop" \
  "! printf '%s' \"\$SP\" | grep -q '\.\.'"
check "G10c the BRIEF tells the grill that slice is a noun phrase, not a sentence" \
  "( cd '$BLANK' && bash '$EV' --brief ) | grep -qi 'NOUN PHRASE'"
check "G10d a clean noun phrase is passed through unharmed" \
  "( cd '$BLANK' && bash '$EV' --prd --idea '$IDEA' --stack 'X + Y' \
       --slice 'importing a CSV row and showing it' ) \
     | grep -q 'importing a CSV row and showing it'"
check "G10e an EMPTY slice still yields a readable sentence" \
  "( cd '$BLANK' && bash '$EV' --prd --idea '$IDEA' --stack 'X + Y' --slice '' ) \
     | grep -qi 'the skeleton renders'"

echo "── S192 · G11 · ELECTRON COMPOSES WITH THE RENDERER (captain ruling 2026-09-06) ──"
# This doc's opening problem statement names the failing case as "a real
# React/ELECTRON codebase with no test setup", and the FOUND panel — the one
# panel whose whole job is to prove LCARS looked at the captain's code — was
# silent about the one fact an Electron captain checks for first. Electron is a
# DEPENDENCY that WRAPS a renderer framework, so it COMPOSES with it rather
# than replacing it. Shape: "Electron + <renderer> + <bundler> · TypeScript",
# joined with the SAME grammar the panel already used.

ELR="$(mk_js elr '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"electron":"^30"}}')"
check "G11a electron + react composes — the renderer is NOT lost" \
  "[ \"\$(label '$ELR')\" = 'Electron + React' ]"

ELV="$(mk_js elv '{"name":"a","dependencies":{"vue":"^3"},"devDependencies":{"electron":"^30"}}')"
check "G11b electron + vue composes too (not a react-only special case)" \
  "[ \"\$(label '$ELV')\" = 'Electron + Vue' ]"

ELO="$(mk_js elo '{"name":"a","devDependencies":{"electron":"^30"}}')"
check "G11c electron with no renderer framework reads Electron" \
  "[ \"\$(label '$ELO')\" = 'Electron' ]"

# `electron` normally lives in devDependencies, never dependencies. If the
# detector only saw `dependencies` it would miss almost every real app.
ELDEV="$(mk_js eldev '{"name":"a","dependencies":{},"devDependencies":{"electron":"^30","vite":"^5"}}')"
check "G11d electron is seen in devDependencies — where it actually lives" \
  "printf '%s' \"\$(label '$ELDEV')\" | grep -q '^Electron'"

# The exact-quoted grep is load-bearing: electron-builder / electron-vite /
# electron-updater are BUILD TOOLING, and a repo that has them without electron
# itself is not an Electron app. Positive evidence only.
EBLD="$(mk_js ebld '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"electron-builder":"^24"}}')"
check "G11e electron-builder WITHOUT electron is NOT labelled Electron" \
  "[ \"\$(label '$EBLD')\" = 'React' ]"

EVIT="$(mk_js evit '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"electron-vite":"^2","electron-updater":"^6"}}')"
check "G11f electron-vite / electron-updater alone do not false-positive either" \
  "! printf '%s' \"\$(label '$EVIT')\" | grep -qi electron"

# The captain's own measured case, whole: an Electron app with a React
# renderer, Vite, and TypeScript.
ELFULL="$(mk_js elfull '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"electron":"^30","electron-builder":"^24","vite":"^5","typescript":"^5"}}' ts)"
check "G11g the captain's full case reads Electron + React + Vite · TypeScript" \
  "[ \"\$(label '$ELFULL')\" = 'Electron + React + Vite · TypeScript' ]"

check "G11h electron alone still composes with the bundler and TypeScript" \
  "[ \"\$(label \"\$(mk_js elbt '{\"name\":\"a\",\"devDependencies\":{\"electron\":\"^30\",\"vite\":\"^5\"}}' ts)\")\" = 'Electron + Vite · TypeScript' ]"

check "G11i the CLASSIFIER is untouched — an electron repo is still stack=js" \
  "[ \"\$( cd '$ELFULL' && bash '$EV' --facts | jget stack )\" = js ]"

echo "── S192 · G12 · REGRESSION — every pre-existing label is BYTE-IDENTICAL ──"
# Captured by running ev_js_label against these exact fixtures at HEAD BEFORE
# the Electron entry existed. A repo with no electron dependency must produce
# the same bytes it produced before, to the character.

reg() { check "G12 $1 ⇒ '$3'" "[ \"\$(label \"\$(mk_js '$1' '$2' ${4:-})\")\" = '$3' ]"; }

reg react            '{"name":"a","dependencies":{"react":"^18"}}'                                              'React'
reg react_vite_ts    '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"vite":"^5","typescript":"^5"}}' 'React + Vite · TypeScript' ts
reg next             '{"name":"a","dependencies":{"next":"^14","react":"^18"}}'                                 'Next.js'
reg nuxt             '{"name":"a","dependencies":{"nuxt":"^3","vue":"^3"}}'                                     'Nuxt'
reg remix            '{"name":"a","dependencies":{"remix":"^2","react":"^18"}}'                                 'Remix'
reg remixrun         '{"name":"a","dependencies":{"@remix-run/react":"^2","react":"^18"}}'                      'Remix'
reg angular          '{"name":"a","dependencies":{"@angular/core":"^17"}}'                                      'Angular'
reg svelte           '{"name":"a","dependencies":{"svelte":"^4"}}'                                              'Svelte'
reg vue              '{"name":"a","dependencies":{"vue":"^3"}}'                                                 'Vue'
reg vue_webpack      '{"name":"a","dependencies":{"vue":"^3"},"devDependencies":{"webpack":"^5"}}'              'Vue + Webpack'
reg svelte_vite_ts   '{"name":"a","dependencies":{"svelte":"^4"},"devDependencies":{"vite":"^5"}}'              'Svelte + Vite · TypeScript' ts
reg bundler_only     '{"name":"a","devDependencies":{"rollup":"^4"}}'                                           'Rollup'
reg parcel_only      '{"name":"a","devDependencies":{"parcel":"^2"}}'                                           'Parcel'
reg esbuild_only     '{"name":"a","devDependencies":{"esbuild":"^0.20"}}'                                       'esbuild'
reg plain            '{"name":"a","dependencies":{"express":"^4"}}'                                             'JavaScript / Node'
reg ts_only          '{"name":"a","dependencies":{"express":"^4"}}'                                             'Node · TypeScript' ts
reg react_ts_nobuild '{"name":"a","dependencies":{"react":"^18"},"devDependencies":{"typescript":"^5"}}'        'React · TypeScript'

# No package.json at all never even reaches ev_js_label — detect_stack answers
# `unknown`, so the panel says so. Pinned because it is the byte-identical
# pre-existing wording, not because it is this function's fallback.
check "G12 a repo with no package.json still reads 'not recognised'" \
  "[ \"\$(label \"\$(new_repo nopkg2)\")\" = 'not recognised' ]"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
