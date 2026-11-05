#!/usr/bin/env bash
#
# S352 — THE FALSE "IMPLEMENTATION IS NOT PRESENT" RED (skill source:
# skills/lcars-run/run.sh — ticket_target_package, the `env` arm of
# rg_signature, and post_commit_gate's plain-red detail).
#
# WHAT WAS MEASURED (2026-11-05, a real GitHub drive against the captain's own
# game repo — tests/drives/s351). post_commit_gate returned RED in ~1.2s
# against a 37-second suite, saying "the implementation is NOT present on the
# committed branch". It never ran a test. The work WAS present and correct.
# Three fresh workers each re-did correct work trying to satisfy that verdict,
# the retry cap was exhausted, and the Mission parked with no pull request.
#
# THREE CAUSES, all three pinned here.
#
# 1. ticket_target_package COUNTED ONLY SUB-PACKAGES. It walks each path in the
#    ticket manifest's `## Relevant files` UP to the nearest ancestor holding a
#    package.json and returns the SINGLE distinct candidate, or "" for 0 or >1
#    (the documented safe repo-root no-op). But `[ -n "$cand" ] || continue`
#    silently DROPPED a path that resolves to no sub-package instead of
#    registering the repo root. In the real ticket two paths were under `tools/`
#    and TEN were not (data/, assets/, src/, tests/). The ten contributed
#    nothing, so the function saw exactly one candidate — `tools` — and declared
#    the whole ticket to belong to it. Counting the root makes that ticket span
#    2 and return "", i.e. the safe behaviour, and the gate passes.
#
#    AGGRAVATING: `tools/package.json` in that repo is a TYPE MARKER, its whole
#    contents `{"type": "commonjs"}` — no scripts, no deps, not a project at
#    all. These markers are everywhere in JS repos.
#
#    THE FEATURE IS NOT TOUCHED: a ticket genuinely confined to ONE sub-package
#    (marker or real) must still resolve to that package. That is what this
#    function exists for and it is a control here.
#
# 2. THE CLASSIFIER MISSED npm's OWN DIAGNOSTIC. Running `npm test` inside
#    `tools/` printed `npm error Missing script: "test"`. That string appeared
#    NOWHERE in run.sh, so neither the env-not-provisioned path (rc 3) nor the
#    zero-collected path (rc 6) fired and it fell through to a plain red. The
#    `env` arm already anchors npm's sibling diagnostics (`^npm (error|ERR!)
#    code ENOENT`, `^npm (error|ERR!) enoent`, `^npm (error|ERR!) could not
#    determine executable to run`) — this one joins them, LINE-START ANCHORED
#    exactly like its neighbours, so an assertion diff that merely QUOTES the
#    phrase mid-line can never match. Like every other alternative in that arm
#    it only ever REJECTS MORE reds (env failure ⇒ inconclusive, never a pass).
#
# 3. THE RUNNER OUTPUT WAS DISCARDED on that fall-through. The zero-collected
#    and env details carry an $out tail; the plain-red detail did not. So
#    nobody — not the captain, not the next worker — ever saw `npm error
#    Missing script: "test"`. The operator was told the implementation was
#    missing, which was false and unactionable.
#
# COST: fast. Sections A and C drive the REAL run.sh hooks on local git
# fixtures; section B extracts the classifier with sed. No worker, no network,
# ZERO tokens. Safe to run directly.
#
# Usage: bash tests/post-commit-false-red.test.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO/skills/lcars-run/run.sh}"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

git_q() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"; }

# =============================================================================
# SECTION A — ticket_target_package, driven through the REAL run.sh hook
# =============================================================================
# Shaped like the repo that was measured: a root package.json, a TYPE-MARKER
# `tools/package.json`, a REAL sub-package `packages/core`, a second real
# sub-package `packages/api`, and root-area code in src/ data/ tests/.
mk_game_repo() { # → echoes repo
  local r; r="$(mktemp -d "$TMPROOT/game.XXXX")"
  ( cd "$r" && git_q init -q && git_q config user.email t@t && git_q config user.name t \
      && git_q commit -q --allow-empty -m init )
  printf '{ "name": "game", "private": true, "scripts": { "test": "node --test" } }\n' >"$r/package.json"
  mkdir -p "$r/tools/spritecut" "$r/src/render" "$r/data" "$r/assets/sprites" "$r/tests"
  # THE TYPE MARKER: the entire file, exactly as measured. No scripts, no deps.
  printf '{"type": "commonjs"}\n' >"$r/tools/package.json"
  printf '// gen-art\n'   >"$r/tools/gen-art.mjs"
  printf '// build\n'     >"$r/tools/spritecut/build-characters.mjs"
  printf '// art\n'       >"$r/src/render/art.js"
  printf '{}\n'           >"$r/data/asset-manifest.json"
  printf 'png\n'          >"$r/assets/sprites/player.png"
  printf '// t\n'         >"$r/tests/sprite-sheets.test.js"
  mkdir -p "$r/packages/core/src" "$r/packages/api/src"
  printf '{ "name": "@x/core", "devDependencies": { "vitest": "^1.6.0" } }\n' >"$r/packages/core/package.json"
  printf '{ "name": "@x/api" }\n' >"$r/packages/api/package.json"
  printf 'export const y = 1\n' >"$r/packages/core/src/y.ts"
  printf 'export const z = 1\n' >"$r/packages/api/src/z.ts"
  mkdir -p "$r/.git/lcars/missions/m-001/manifests"
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement","branch":"","base":"main" }\n' \
    >"$r/.git/lcars/missions/m-001/state.json"
  echo "$r"
}

manifest() { # repo ticket  (paths on stdin)
  local m="$1/.git/lcars/missions/m-001/manifests/$2.md" p
  { printf '# %s context manifest\n\n## Relevant files\n' "$2"
    while IFS= read -r p; do [ -n "$p" ] && printf -- '- `%s` — a file\n' "$p"; done
    printf '\n## Interface signatures\n- none\n'
  } >"$m"
}

tp() { # repo ticket → ticket_target_package's answer
  ( cd "$1" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      bash "$SCRIPT" ticket-target-package-test --mission m-001 --ticket "$2" 2>/dev/null )
}

echo "A. ticket_target_package — the repo root is a candidate too"

GREPO="$(mk_game_repo)"

# A1 — THE DEFECT, the measured shape: 2 paths under the tools/ TYPE MARKER and
# 5 that are in NO sub-package. The ticket spans root + tools, so the only safe
# answer is "" (today's repo-root behaviour). Before the fix: "tools".
manifest "$GREPO" t-measured <<'EOF'
tools/gen-art.mjs
tools/spritecut/build-characters.mjs
data/asset-manifest.json
assets/sprites/player.png
src/render/art.js
tests/sprite-sheets.test.js
EOF
got="$(tp "$GREPO" t-measured)"
[ -z "$got" ] \
  && ok "A1. DEFECT: root files + a type-marker sub-package span TWO scopes → '' (safe no-op)" \
  || bad "A1. a ticket spanning the repo root and tools/ resolved to '$got' — the measured false red"

# A2 — THE FEATURE, CONTROL: a ticket entirely inside one REAL sub-package must
# still resolve to it. This is the monorepo staging ticket_target_package exists
# for and the fix must not touch it.
manifest "$GREPO" t-confined <<'EOF'
packages/core/src/y.ts
packages/core/src/z.ts
packages/core/package.json
EOF
got="$(tp "$GREPO" t-confined)"
[ "$got" = "packages/core" ] \
  && ok "A2. CONTROL: a ticket confined to ONE real sub-package still resolves to it" \
  || bad "A2. the single-sub-package feature regressed: expected packages/core, got '$got'"

# A3 — REGRESSION CONTROL with the REAL TYPE MARKER: a ticket confined to the
# marker package resolves to it, exactly as before. A type marker is still a
# package root for discovery purposes; the defect was never that `tools` is a
# bad answer, only that it was given for a ticket that SPANNED.
manifest "$GREPO" t-tools-only <<'EOF'
tools/gen-art.mjs
tools/spritecut/build-characters.mjs
EOF
got="$(tp "$GREPO" t-tools-only)"
[ "$got" = "tools" ] \
  && ok "A3. CONTROL: a ticket confined to the TYPE-MARKER package still resolves to tools" \
  || bad "A3. expected tools for a marker-confined ticket, got '$got'"

# A4 — root-only code: unchanged, "" (0 sub-packages).
manifest "$GREPO" t-root <<'EOF'
src/render/art.js
tests/sprite-sheets.test.js
README.md
EOF
got="$(tp "$GREPO" t-root)"
[ -z "$got" ] \
  && ok "A4. CONTROL: root-only code still resolves to '' (the repo-root no-op)" \
  || bad "A4. expected '' for root-only code, got '$got'"

# A5 — two REAL sub-packages: unchanged, "".
manifest "$GREPO" t-multi <<'EOF'
packages/core/src/y.ts
packages/api/src/z.ts
EOF
got="$(tp "$GREPO" t-multi)"
[ -z "$got" ] \
  && ok "A5. CONTROL: files spanning two real sub-packages still resolve to ''" \
  || bad "A5. expected '' for a two-package span, got '$got'"

# A6 — a missing manifest: unchanged, "".
got="$(tp "$GREPO" t-absent)"
[ -z "$got" ] \
  && ok "A6. CONTROL: a missing manifest still resolves to '' (safe no-op)" \
  || bad "A6. expected '' for a missing manifest, got '$got'"

# =============================================================================
# SECTION B — the `env` arm must know npm's missing-script diagnostic
# =============================================================================
echo
echo "B. rg_signature env — npm's Missing script diagnostic"

LIB="$TMPROOT/lib.sh"; : >"$LIB"
for fn in rg_signature red_gate_env_failure; do
  sed -n "/^$fn() {/,/^}/p" "$SCRIPT" >>"$LIB"
done
# shellcheck source=/dev/null
. "$LIB"
type red_gate_env_failure >/dev/null 2>&1 \
  || { echo "FATAL: could not extract red_gate_env_failure from $SCRIPT" >&2; exit 1; }
type rg_signature >/dev/null 2>&1 \
  || { echo "FATAL: could not extract rg_signature from $SCRIPT" >&2; exit 1; }

# B1 — THE DEFECT, npm 10's wording, verbatim from the measured run
# (tests/drives/s351/shots/08-false-postcommit-red.body.txt).
B1_OUT='npm error Missing script: "test"
npm error
npm error To see a list of scripts, run:
npm error   npm run'
if red_gate_env_failure "$B1_OUT"; then
  ok "B1. DEFECT: npm 10 'Missing script' is an ENV failure, not a missing implementation"
else
  bad "B1. npm's 'Missing script: \"test\"' still falls through to a plain red"
fi

# B2 — npm 9 and earlier say ERR!, so the arm must accept both prefixes.
if red_gate_env_failure 'npm ERR! Missing script: "test"'; then
  ok "B2. the older npm ERR! prefix classifies the same way"
else
  bad "B2. npm ERR! Missing script was not classified as an env failure"
fi

# B3 — ANCHORING CONTROL. The arm's neighbours are all line-start anchored so an
# assertion diff that merely QUOTES a diagnostic can never fire. If this passes
# because the pattern is unanchored, the whole arm has been loosened.
B3_OUT='  AssertionError: expected "npm error Missing script: \"test\"" to equal "ok"
    at helpText (tests/cli.test.js:14:7)
1 failed, 12 passed'
if red_gate_env_failure "$B3_OUT"; then
  bad "B3. ANCHORING: an assertion QUOTING the phrase mid-line was read as an env failure"
else
  ok "B3. CONTROL: the phrase quoted mid-line in an assertion diff does NOT match"
fi

# B4 — a genuine assertion red stays a genuine red (the arm may only reject
# MORE reds; it must never swallow the missing-implementation case).
if red_gate_env_failure '
FAIL tests/sprite-sheets.test.js > row frames
AssertionError: expected 4 to be 3
1 failed, 12 passed (13)'; then
  bad "B4. a plain assertion red was reclassified as an env failure"
else
  ok "B4. CONTROL: a genuine assertion red is untouched by the arm"
fi

# B5 — the arm's neighbours are still there (a careless edit to one long ERE
# could drop them).
sig="$(rg_signature env)"
missing=""
for neighbour in 'code ENOENT' 'enoent' 'could not determine executable to run'; do
  case "$sig" in *"$neighbour"*) : ;; *) missing="${missing:+$missing, }$neighbour" ;; esac
done
[ -z "$missing" ] \
  && ok "B5. CONTROL: npm's sibling diagnostics are all still in the arm" \
  || bad "B5. the edit dropped npm neighbour(s) from the env arm: $missing"

# =============================================================================
# SECTION C — the plain-red verdict must carry the runner's own output
# =============================================================================
echo
echo "C. post_commit_gate — the real diagnostic survives into the verdict"

# A fake runner, in the shape the measured repo's testCommand had
# (`npm test -- ${LCARS_TESTS_DIR:+...}`): it ignores the scope and speaks only
# about WHERE it was run from. No npm, no node, no network.
#   • at the repo root (a `.runner-ok` marker in $PWD): GREEN
#   • anywhere else: npm's OWN missing-script diagnostic, exactly as measured
FAKE_NPM="$TMPROOT/fake-npm.sh"
cat >"$FAKE_NPM" <<'SH'
#!/usr/bin/env bash
if [ -f "./.runner-ok" ]; then
  printf 'ok 1 - frames\n1 passed, 0 failed\n'; exit 0
fi
printf 'npm error Missing script: "test"\n' >&2
printf 'npm error\nnpm error To see a list of scripts, run:\nnpm error   npm run\n' >&2
exit 1
SH
# A fake runner that is a GENUINE red: it starts, it runs, an assertion fails.
FAKE_RED="$TMPROOT/fake-red.sh"
cat >"$FAKE_RED" <<'SH'
#!/usr/bin/env bash
printf 'FAIL tests/test_sprites > row frames\n'
printf 'RUNNER DIAGNOSTIC: expected 4 frames, received 0\n'
printf '1 failed, 12 passed (13)\n'
exit 1
SH
TCMD_TPL='bash RUNNER ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'

# A branch-mode mission shaped like the measured one: a TYPE-MARKER
# tools/package.json, two ticket paths inside it, and the rest at the repo root.
mk_marker_repo() { # runner → echoes repo
  local r; r="$(mktemp -d "$TMPROOT/meas.XXXX")"
  ( cd "$r" && git_q init -q && git_q config user.email t@t && git_q config user.name t )
  mkdir -p "$r/src/render" "$r/tools/spritecut" "$r/data" "$r/tests" \
           "$r/.git/lcars/missions/m-001/manifests" \
           "$r/.git/lcars/missions/m-001/tickets/t-001"
  printf 'ok\n'                    >"$r/.runner-ok"
  printf '{ "name": "game", "private": true }\n' >"$r/package.json"
  printf '{"type": "commonjs"}\n'  >"$r/tools/package.json"
  printf '// gen-art\n'            >"$r/tools/gen-art.mjs"
  printf '// build\n'              >"$r/tools/spritecut/build-characters.mjs"
  printf 'export const frames = 4\n' >"$r/src/render/art.js"
  printf '{}\n'                    >"$r/data/asset-manifest.json"
  printf 'it("frames", () => {})\n' >"$r/tests/sprite-sheets.test.js"
  ( cd "$r" && git_q add -A && git_q commit -qm base && git_q branch lcars/m-001 )
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement","branch":"lcars/m-001","base":"main" }\n' \
    >"$r/.git/lcars/missions/m-001/state.json"
  # THE MEASURED SHAPE: 2 paths under the tools/ type marker, 4 that are in no
  # sub-package at all.
  { printf '# t-001 context manifest\n\n## Relevant files\n'
    printf -- '- `tools/gen-art.mjs` — generator\n'
    printf -- '- `tools/spritecut/build-characters.mjs` — cutter\n'
    printf -- '- `src/render/art.js` — the renderer\n'
    printf -- '- `data/asset-manifest.json` — the manifest\n'
    printf -- '- `tests/sprite-sheets.test.js` — the ticket test\n'
  } >"$r/.git/lcars/missions/m-001/manifests/t-001.md"
  ( cd "$r" && shasum -a 256 tests/sprite-sheets.test.js ) \
    >"$r/.git/lcars/missions/m-001/tickets/t-001/proof-tests.sha256"
  echo "$r"
}

gate_pc() { # repo runner → stdout+stderr of the real gate
  ( cd "$1" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
      LCARS_GH_BIN=true LCARS_TEST_CMD="${TCMD_TPL/RUNNER/$2}" \
      bash "$SCRIPT" post-commit-gate-test --mission m-001 --ticket t-001 2>&1 )
}

# --- C0/C1/C2: a GENUINE red must carry the runner's own words --------------
RREPO="$(mk_marker_repo)"
cout="$(gate_pc "$RREPO" "$FAKE_RED")"
csig="$(cat "$RREPO/.git/lcars/missions/m-001/pc-test-signal.txt" 2>/dev/null || true)"

# C0 — the fixture must really reach the plain-red path, or C1/C2 prove nothing.
if printf '%s\n' "$cout" | grep -q '^PCRC=1$' \
   && printf '%s\n' "$cout" | grep -q 'implementation is NOT present on the committed branch'; then
  ok "C0. CONTROL: the fixture reaches the plain-red path (PCRC=1, missing-impl wording)"
else
  bad "C0. the fixture never reached the plain-red path — C1/C2 below prove nothing: $cout"
fi

# C1 — THE DEFECT: the runner's own words must be in the verdict.
if printf '%s\n' "$cout" | grep -q 'RUNNER DIAGNOSTIC: expected 4 frames, received 0'; then
  ok "C1. DEFECT: the plain-red verdict quotes the runner's own output"
else
  bad "C1. the runner output is still discarded on the plain-red path"
fi

# C2 — and in the SIGNAL file, which is what the Implement stage and the next
# worker actually read.
if printf '%s\n' "$csig" | grep -q 'RUNNER DIAGNOSTIC: expected 4 frames, received 0'; then
  ok "C2. the signal the stage reads carries the runner output too"
else
  bad "C2. the POST_COMMIT_SIGNAL still carries no runner output: $csig"
fi

# --- C3/C4: END TO END on the measured shape --------------------------------
# Correct, committed work whose ticket spans the repo root and a type-marker
# sub-package. The suite is green AT THE ROOT and `npm test` inside tools/
# prints `Missing script`. Before the fix: a ~1s plain red that never ran a
# test. After: the gate runs at the root and PASSES.
MREPO="$(mk_marker_repo)"
mout="$(gate_pc "$MREPO" "$FAKE_NPM")"
if printf '%s\n' "$mout" | grep -q '^PCRC=0$'; then
  ok "C3. END TO END: correct work spanning root + a type-marker package PASSES"
else
  bad "C3. the measured false red survives end to end: $mout"
fi

# C4 — and if the runner genuinely CANNOT start (the same repo with no root
# marker, so `npm test` says Missing script wherever it runs), the gate must
# report an ENVIRONMENT fault (rc 3) — never "the implementation is missing".
EREPO="$(mk_marker_repo)"
rm -f "$EREPO/.runner-ok"
( cd "$EREPO" && git_q rm -q --cached .runner-ok >/dev/null 2>&1 && git_q commit -qm "drop marker" \
    && git_q branch -f lcars/m-001 HEAD ) >/dev/null 2>&1
( cd "$EREPO" && shasum -a 256 tests/sprite-sheets.test.js ) \
  >"$EREPO/.git/lcars/missions/m-001/tickets/t-001/proof-tests.sha256"
eout="$(gate_pc "$EREPO" "$FAKE_NPM")"
if printf '%s\n' "$eout" | grep -q '^PCRC=3$' \
   && ! printf '%s\n' "$eout" | grep -q 'implementation is NOT present'; then
  ok "C4. npm's Missing script is reported as an ENVIRONMENT fault (rc 3), not a missing impl"
else
  bad "C4. a runner that could not start was still blamed on the implementation: $eout"
fi

# =============================================================================
# The controls must have RUN. A suite that silently skips its positive controls
# and prints OK has shipped on this project; the count is the guard.
# =============================================================================
EXPECTED=16
echo
printf 'post-commit-false-red: %d passed, %d failed (%d checks expected)\n' "$pass" "$fail" "$EXPECTED"
if [ "$((pass + fail))" -ne "$EXPECTED" ]; then
  printf '  \033[31mFAIL\033[0m SKIP GUARD: %d checks ran, %d were declared — a control was skipped\n' \
    "$((pass + fail))" "$EXPECTED"
  exit 1
fi
[ "$fail" -eq 0 ]
