#!/usr/bin/env bash
#
# S236 — PROOF AT THE SEAMS. Fast, SCOPED suite.
#
# THE GROUND TRUTH THIS EXISTS FOR. Over the weekend of 26–29 Sep six live
# breaks got past green test suites, and every single one sat at a STUBBED SEAM:
# two code paths touch the same state and the suite only ever drove one side.
# The producer wrote one issue format and the consumer parsed another; an empty
# allow-list meant "show everything"; demote had no effect; a workflow ran a
# module as a file; the runner's `gh` defaulted to github.com and crawled the
# wrong org. A plan could claim a test PROVED a producer/consumer pair while the
# test stubbed one half and fed the other a hand-written fixture.
#
# The cure is a DECLARATION, audited — never a detector. The Plan worker declares
# every producer/consumer pair its ticket creates (`seams`) and every CI
# entrypoint it adds (`entrypoints`); the harness checks the MECHANICAL half; the
# reviewer audits the judgement half; Verify RECORDS what was declared.
#
# What this suite drives:
#   A. the mechanical validator, through the REAL `run.sh plan-save` over real
#      plan.json fixtures (behaviors 1–3).
#   B. the HOST CHECKLIST — a non-github.com origin (and a PRD that names a host)
#      makes the assembled Plan prompt carry the checklist and the mission carry
#      `hostChecklist: true`; github.com carries neither (behavior 4).
#   C. the Verify readout — every declared seam/entrypoint test listed with
#      exists:yes/no at the tip (behavior 5).
#   D. the PROMPT CONTRACT — plan.md, plan-review.md and implement-tdd.md each
#      carry their rule paragraphs, asserted BY HEADING so a later edit cannot
#      silently drop one (behavior 6).
#   E. PLAN REVIEW'S OBJECTIONS reaching a human WHOLE, through the real
#      `review-save` — the readout, pending.json and pendingQuestion (behavior 8).
#
# THE CAPTAIN'S RULING OF 2026-10-01 — "we let the AI reviewer check it". The
# WORKFLOW RULE is DELETED: there was a scan that read a ticket's prose for a
# `.github/workflows/*.yml` path, inferred ownership of it, and demanded an
# entrypoints entry or a by-name disclaimer. It produced three faults in one
# session — it rejected a ticket that named a workflow only to FORBID editing
# it, it rejected plans that do not use the contract at all, and it rejected the
# round's own required proof sentence for naming the workflow it runs — and it
# taught a live planner to delete workflow filenames out of its own guardrail
# prose to get past it. Behaviors 0d–0i and 1k–1l pin the ruling: NAMING a
# workflow file is not a claim. Behavior 1 pins the half that did NOT change —
# every field of a declaration that IS made is still checked. Plan Review is the
# only backstop now, and behavior 6 (6z8–6z10) pins that its prompt says so.
#
# BEHAVIOR 8 (section E) is the second cure of the same session: print_objections
# field-split raw JSON on `"`, so every objection carrying an escaped quote was
# cut at the first one — on the readout AND in the escalation question the
# captain is asked. It reads the verdict with a JSON reader now.
#
# S236 FIX ROUND 1 added one more behavior inside A:
#   7. THE PRODUCER RECORDS THE CLAIM. `roundTripTest` is a bare PATH, so on a
#      CONFORMING plan the reviewer's "reject a stubbed round-trip test" gate had
#      nothing to read and auto-approved. Every entry now carries a
#      `roundTripProof` / `realRunProof` sentence; the harness checks it is there
#      and non-blank, the reviewer judges what it says.
#
# Stubbed workers only; no model, no tokens. Runs in a few seconds.
# NEVER run the full tests/run.sh for this. Usage: bash tests/plan-seams.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
STAGES="$REPO_ROOT/skills/lcars-run/stages"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ===========================================================================
section "A. the mechanical validator (real plan-save, real plan.json)"
# ===========================================================================

# A fresh git repo with one mission parked at `plan`. No githubIssue, so
# gh_relabel is a no-op and nothing reaches a forge.
new_mission() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }
JSON
  echo "$repo"
}

run_plan_save() { # repo planfile -> sets RC + OUT (+ NOTE = the reject note)
  OUT="$( cd "$1" && bash "$SCRIPT" plan-save --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
  NOTE=""
  [ -f "$(dirname "$2")/.plan-reject-note" ] && NOTE="$(cat "$(dirname "$2")/.plan-reject-note")"
}

# One ticket, with $1 spliced in as EXTRA keys (already comma-terminated).
plan_with() { # extra-keys -> plan.json on stdout
  cat <<JSON
[
  {
    "id": "t-001",
    "title": "Do the thing",
    "description": "Build the thing end to end.",
    "acceptanceCriteria": ["it works"],
$1
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "rationale": "It is the foundation."
  }
]
JSON
}

mkplan() { # name extra-keys -> echoes the plan path (its own dir, for the note)
  local d; d="$(mktemp -d "$TMPROOT/plan.XXXX")"
  plan_with "$2" > "$d/plan.json"
  echo "$d/plan.json"
}

# The same, with the ticket's DESCRIPTION replaced — the field a pre-S236 plan
# most often names a workflow file in ("Add .github/workflows/publish.yml ...").
mkplan_desc() { # name description extra-keys -> echoes the plan path
  local p; p="$(mkplan "$1" "$3")"
  "${LCARS_PYTHON_BIN:-python3}" - "$p" "$2" <<'DESC_PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[0]["description"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"), indent=2)
DESC_PY
  echo "$p"
}

# --- back-compat: a plan that declares NEITHER key is untouched --------------
# Every in-flight mission and every pre-S236 plan has no seams/entrypoints. The
# keys are ADDITIVE: absence must stay valid or this round breaks every plan
# already on disk (and every other plan suite).
P="$(mkplan legacy '')"
run_plan_save "$(new_mission)" "$P"
check "0a a plan with NO seams/entrypoints keys is still accepted" "[ '$RC' -eq 0 ]"

# --- back-compat, THE AXIS THAT WAS MISSING A CONTROL ------------------------
# S236 fix round 3. 0a's legacy plan names no workflow file ANYWHERE, so it
# could not see the one way back-compat actually broke: the WORKFLOW RULE ran
# over every plan, gated on nothing, while rules 1/3/4 were all gated on
# `declaring`. An ordinary pre-S236 ticket whose `description` happens to say
# "Add .github/workflows/publish.yml that runs the handler" — a very common
# sentence — was REJECTED here and ACCEPTED on main. A plan that does not use
# the contract must not be held to a part of it; the keys are ADDITIVE.
# So the control is a legacy plan WITH a workflow filename in its prose.
WFDESC='Add .github/workflows/publish.yml that runs the handler on a tag push.'
P="$(mkplan_desc legacy-wf-desc "$WFDESC" '')"
run_plan_save "$(new_mission)" "$P"
check "0b a LEGACY plan (no seams/entrypoints keys) whose DESCRIPTION names a workflow file is ACCEPTED" \
  "[ '$RC' -eq 0 ]"

# The same axis through a different field: a legacy ticket's declaredEdits.
P="$(mkplan legacy-wf-edits '    "declaredEdits": [".github/workflows/publish.yml", "src/hub.py"],')"
run_plan_save "$(new_mission)" "$P"
check "0c a LEGACY plan whose declaredEdits name a workflow file is ACCEPTED" \
  "[ '$RC' -eq 0 ]"

# …and a plan that DOES use the contract is held to the DECLARATIONS it makes —
# and to nothing it merely MENTIONS. Same description, same filename: the ticket
# declares `entrypoints: []` with a note that never names the file, and that is
# ACCEPTED. See the ruling block in run.sh's validate_plan_seams.
P="$(mkplan_desc declaring-wf-desc "$WFDESC" '    "seams": [],
    "seamsNote": "this ticket writes no state another path reads.",
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "0d a DECLARING plan whose DESCRIPTION names a workflow file, with no entry and no disclaimer, is ACCEPTED" \
  "[ '$RC' -eq 0 ]"
check "0e …and nothing is written to the reject-note channel" "[ -z \"\$NOTE\" ]"

# The same axis through declaredEdits — the field the old scan read as "owns it".
P="$(mkplan declaring-wf-edits '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",
    "declaredEdits": [".github/workflows/publish.yml", "src/hub.py"],')"
run_plan_save "$(new_mission)" "$P"
check "0f a DECLARING plan whose declaredEdits name a workflow file is ACCEPTED" \
  "[ '$RC' -eq 0 ]"

# FAULT 1 of the three the scan produced in one session: the guardrail sentence.
# A pure-CLI ticket that names a workflow ONLY to forbid editing it was rejected,
# and the note that exists to explain the absence could not be worded to pass.
# The planner's only ways out were a FALSE declaration or DELETING the guardrail
# — and a live planner was measured doing exactly that. It is accepted now, and
# the note does NOT have to name the file to earn it.
P="$(mkplan_desc declaring-wf-forbid \
  'Add the promote subcommand. Do NOT touch .github/workflows/publish.yml - that file belongs to t-004 and editing it here would break the publish job.' \
  '    "seams": [],
    "seamsNote": "pure CLI; it writes no state another path reads.",
    "entrypoints": [],
    "entrypointsNote": "this ticket adds no CI entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "0g a ticket that names a workflow ONLY to FORBID editing it is ACCEPTED without naming it in any note" \
  "[ '$RC' -eq 0 ]"

# FAULT 3: the round's OWN proof sentence. `realRunProof` is required to say how
# the test runs the entrypoint as CI does, and the natural sentence NAMES the
# workflow it runs — so the scan read the round's own required field as a claim
# of ownership over a second file and rejected it. A proof sentence is prose.
P="$(mkplan declaring-proof-names-wf '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "cli", "path": "bin/publish",
                     "realRunTest": "tests/test_publish_cli.py",
                     "realRunProof": "it runs bin/publish with the argv .github/workflows/publish.yml passes it, from the repo root, with the Actions env set."}],')"
run_plan_save "$(new_mission)" "$P"
check "0h a workflow filename inside a required realRunProof sentence does not reject the plan" \
  "[ '$RC' -eq 0 ]"

# …and the blanket statement of the ruling: NAMING workflow files is not a claim.
P="$(mkplan_desc declaring-wf-many \
  'Wire the hub. .github/workflows/ci.yml, .github/workflows/publish.yml and .github/workflows/release.yaml all call it; none of them is ours.' \
  '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint in this slice.",')"
run_plan_save "$(new_mission)" "$P"
check "0i a ticket naming THREE workflow files in prose, declaring none, is ACCEPTED" \
  "[ '$RC' -eq 0 ]"

# --- behavior 1: a DECLARATION THAT IS MADE IS STILL CHECKED, IN FULL --------
# RULING OF 2026-10-01. The prose scan is gone; the declaration checks are NOT.
# This is the half the captain is relying on, so every field of a declared
# entrypoint is driven here.

# The whole, correct declaration is accepted.
P="$(mkplan wf-ok '    "seams": [],
    "seamsNote": "this ticket writes no state another path reads.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": "it reads the publish step command out of the yml and runs that exact command from the repo root with the Actions env set."}],
    "declaredEdits": [".github/workflows/publish.yml", "src/hub.py"],')"
run_plan_save "$(new_mission)" "$P"
check "1a a DECLARED workflow entrypoint with realRunTest + realRunProof is ACCEPTED" \
  "[ '$RC' -eq 0 ]"

# A declared entry with no realRunTest is rejected BY NAME.
P="$(mkplan wf-nortt '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunProof": "it runs the publish step command from the repo root."}],')"
run_plan_save "$(new_mission)" "$P"
check "1b a declared workflow entrypoint with NO realRunTest is REJECTED" "[ '$RC' -ne 0 ]"
check "1c …naming the ticket, the key and the file" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -qF 'realRunTest' && printf '%s' \"\$OUT\" | grep -qF '.github/workflows/publish.yml'"
check "1d …and it reaches the retrying worker on the S178 reject-note channel" \
  "printf '%s' \"\$NOTE\" | grep -qF 'realRunTest'"

# A declared entry with a BLANK realRunProof is rejected BY NAME.
P="$(mkplan wf-blankproof '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": "   "}],')"
run_plan_save "$(new_mission)" "$P"
check "1e a declared workflow entrypoint with a BLANK realRunProof is REJECTED, naming the key" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'realRunProof'"

# A declared entry whose realRunTest is NOT a test path is rejected BY NAME.
P="$(mkplan wf-testoutside '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "src/hub.py",
                     "realRunProof": "it runs the publish step command from the repo root with the Actions env set."}],')"
run_plan_save "$(new_mission)" "$P"
check "1f a declared workflow entrypoint whose realRunTest is OUTSIDE the tests dir is REJECTED" \
  "[ '$RC' -ne 0 ]"
check "1g …naming the key and the offending path" \
  "printf '%s' \"\$OUT\" | grep -qF 'realRunTest' && printf '%s' \"\$OUT\" | grep -qF 'src/hub.py'"

# kind and path are still checked on a declared entry.
P="$(mkplan wf-badkind '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "script", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": "it runs the publish step command from the repo root."}],')"
run_plan_save "$(new_mission)" "$P"
check "1h a declared entrypoint with an unknown kind is REJECTED, naming kind" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'kind'"

P="$(mkplan wf-nopath '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": "it runs the publish step command from the repo root."}],')"
run_plan_save "$(new_mission)" "$P"
check "1i a declared entrypoint with NO path is REJECTED, naming path" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'path'"

# A ticket may own one workflow (an entry) and merely mention another.
P="$(mkplan wf-own-and-mention '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/ci.yml",
                     "realRunTest": "tests/test_ci.py",
                     "realRunProof": "it reads the run step out of ci.yml and runs that exact command from the repo root with the Actions env set."}],
    "entrypointsNote": "ci.yml is ours.",
    "declaredEdits": [".github/workflows/ci.yml", ".github/workflows/publish.yml"],')"
run_plan_save "$(new_mission)" "$P"
check "1j a ticket may declare one workflow and merely mention another" "[ '$RC' -eq 0 ]"

# THE REMOVED RULE, asserted as an ABSENCE: no rejection anywhere may accuse a
# ticket of naming a workflow file it did not declare. That sentence is what a
# live planner learned to dodge by deleting its own guardrail prose.
P="$(mkplan_desc declaring-wf-absence "$WFDESC" '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "1k no rejection accuses a ticket of merely NAMING a workflow file" \
  "! printf '%s' \"\$OUT\" | grep -qi 'names the workflow file'"
check "1l …and the plan is not bounced for it" "[ '$RC' -eq 0 ]"
# --- behavior 2: a test path outside the tests dir is REJECTED --------------
P="$(mkplan rtt-outside '    "seams": [{"producer": "cli writes request.json",
               "consumer": "the hub handler parses request.json",
               "roundTripTest": "src/hub.py"}],
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "2a a roundTripTest path OUTSIDE the tests dir is REJECTED" "[ '$RC' -ne 0 ]"
check "2b the reason names the ticket, the key and the path" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -qF 'roundTripTest' && printf '%s' \"\$OUT\" | grep -qF 'src/hub.py'"

P="$(mkplan rtt-inside '    "seams": [{"producer": "cli writes request.json",
               "consumer": "the hub handler parses request.json",
               "roundTripTest": "tests/test_request_roundtrip.py",
               "roundTripProof": "it calls the real CLI writer, reads back the file it wrote, and hands that to the real parse_request()."}],
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "2c …under tests/ it is accepted" "[ '$RC' -eq 0 ]"

# The repo's OWN convention counts as its tests dir — a co-located *.test.ts is
# a test file wherever it sits (plan.md's manifest rules say exactly that).
P="$(mkplan rtt-colocated '    "seams": [{"producer": "the store writes the theme",
               "consumer": "the reader reads the theme",
               "roundTripTest": "src/theme.test.ts",
               "roundTripProof": "it calls the real setTheme(), then reads the attribute back through the real token reader."}],
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "2d a co-located src/*.test.ts round-trip test is accepted" "[ '$RC' -eq 0 ]"

# An absolute path is not a repo path at all.
P="$(mkplan rtt-abs '    "seams": [{"producer": "a", "consumer": "b",
               "roundTripTest": "/tmp/tests/test_x.py"}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "2e an ABSOLUTE test path is REJECTED" "[ '$RC' -ne 0 ]"

# A seam with no roundTripTest at all is rejected by name.
P="$(mkplan seam-nortt '    "seams": [{"producer": "cli writes request.json",
               "consumer": "the hub handler parses it"}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "2f a seam with NO roundTripTest is REJECTED, naming the key" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'roundTripTest'"
check "2g …and names the seam's producer so the worker knows WHICH seam" \
  "printf '%s' \"\$OUT\" | grep -qF 'cli writes request.json'"

# --- behavior 3: an empty list needs a note ---------------------------------
P="$(mkplan empty-nonote '    "seams": [],
    "entrypoints": [],
    "entrypointsNote": "no new entrypoint.",')"
run_plan_save "$(new_mission)" "$P"
check "3a an empty seams[] with NO seamsNote is REJECTED" "[ '$RC' -ne 0 ]"
check "3b the reason names the ticket and seamsNote" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -qF 'seamsNote'"

P="$(mkplan empty-note '    "seams": [],
    "seamsNote": "this ticket is a pure renderer; it writes no state any other path reads.",
    "entrypoints": [],
    "entrypointsNote": "it adds no CLI and no workflow.",')"
run_plan_save "$(new_mission)" "$P"
check "3c …with a note it is ACCEPTED" "[ '$RC' -eq 0 ]"

P="$(mkplan empty-blanknote '    "seams": [],
    "seamsNote": "   ",
    "entrypoints": [],
    "entrypointsNote": "none needed.",')"
run_plan_save "$(new_mission)" "$P"
check "3d a BLANK seamsNote is not a note" "[ '$RC' -ne 0 ]"

P="$(mkplan ep-nonote '    "seams": [],
    "seamsNote": "no shared state.",
    "entrypoints": [],')"
run_plan_save "$(new_mission)" "$P"
check "3e an empty entrypoints[] with NO entrypointsNote is REJECTED" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'entrypointsNote'"

# --- the contract is all-or-nothing ACROSS the plan -------------------------
# A plan that uses the new keys must use them on EVERY ticket, or a worker
# silences the contract by simply omitting it on the ticket that has a seam.
cat > "$TMPROOT/mixed.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "A",
    "description": "d",
    "acceptanceCriteria": ["c"],
    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [],
    "entrypointsNote": "none.",
    "estimatedReadLoc": 1,
    "estimatedTestLoc": 1,
    "estimatedNewLoc": 1,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "rationale": "r"
  },
  {
    "id": "t-002",
    "title": "B",
    "description": "d",
    "acceptanceCriteria": ["c"],
    "estimatedReadLoc": 1,
    "estimatedTestLoc": 1,
    "estimatedNewLoc": 1,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "rationale": "r"
  }
]
JSON
mkdir -p "$TMPROOT/mixdir" && cp "$TMPROOT/mixed.json" "$TMPROOT/mixdir/plan.json"
run_plan_save "$(new_mission)" "$TMPROOT/mixdir/plan.json"
check "3f a plan that declares the keys on SOME tickets is REJECTED for the rest" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 't-002'"

# --- the EXISTING rules are untouched ---------------------------------------
P="$(mkplan noac '    "seams": [], "seamsNote": "none.",
    "entrypoints": [], "entrypointsNote": "none.",')"
"${LCARS_PYTHON_BIN:-python3}" - "$P" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d[0]["rationale"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
run_plan_save "$(new_mission)" "$P"
check "3g a missing REQUIRED field still fails with the old message" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'rationale'"

# --- behavior 7: the PRODUCER RECORDS THE CLAIM -----------------------------
# S236 fix round 1, and the important one. `roundTripTest` carries a bare test
# PATH — that is Plan's own contract, and both live engines obeyed it (Copilot
# wrote "tests/test_list.py"; Claude wrote four *_roundtrip.py paths). But
# plan-review.md told the reviewer to "read what each roundTripTest is described
# as" — and on a plan that FOLLOWS the contract there is nothing to read. So the
# advertised gate ("reject a round-trip test whose description stubs either
# half") fired only when a planner volunteered the sentence that convicted it.
# A planner that names a bare path and says nothing got an automatic APPROVE,
# and the stub appeared for the first time at Implement — the exact failure
# class this round exists to close.
#
# The cure is RECORD, DO NOT INFER, applied to the claim itself: every seam
# carries `roundTripProof`, one sentence saying HOW that test drives both real
# halves, and every entrypoint carries `realRunProof`. The harness checks it is
# THERE and not blank; whether the sentence describes a real test or a stub is
# the reviewer's judgement, and the harness never guesses at it.

P="$(mkplan proof-missing '    "seams": [{"producer": "cli writes request.json",
               "consumer": "the hub handler parses request.json",
               "roundTripTest": "tests/test_request_roundtrip.py"}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "7a a seam that names a BARE test path and no roundTripProof is REJECTED" \
  "[ '$RC' -ne 0 ]"
check "7b the reason names the ticket, the seam and roundTripProof" \
  "printf '%s' \"\$OUT\" | grep -q 't-001' && printf '%s' \"\$OUT\" | grep -qF 'roundTripProof' && printf '%s' \"\$OUT\" | grep -qF 'cli writes request.json'"
check "7c …and it reaches the retrying worker on the reject-note channel" \
  "printf '%s' \"\$NOTE\" | grep -qF 'roundTripProof'"

P="$(mkplan proof-blank '    "seams": [{"producer": "a", "consumer": "b",
               "roundTripTest": "tests/test_x.py",
               "roundTripProof": "   "}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "7d a BLANK roundTripProof is not a claim" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'roundTripProof'"

P="$(mkplan proof-ok '    "seams": [{"producer": "cli writes request.json",
               "consumer": "the hub handler parses request.json",
               "roundTripTest": "tests/test_request_roundtrip.py",
               "roundTripProof": "it calls the CLI writer, reads back the file it actually wrote, and passes that bytes-for-bytes to the real parse_request(); no sample constant anywhere."}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "7e …a seam carrying a roundTripProof is ACCEPTED" "[ '$RC' -eq 0 ]"

P="$(mkplan rrp-missing '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py"}],')"
run_plan_save "$(new_mission)" "$P"
check "7f an entrypoint with no realRunProof is REJECTED, naming the key" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'realRunProof'"

P="$(mkplan rrp-blank '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": ""}],')"
run_plan_save "$(new_mission)" "$P"
check "7g a BLANK realRunProof is not a claim" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -qF 'realRunProof'"

P="$(mkplan rrp-ok '    "seams": [],
    "seamsNote": "none.",
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                     "realRunTest": "tests/test_publish_workflow.py",
                     "realRunProof": "it reads the publish step command out of the yml and runs that exact command from the repo root with GITHUB_SERVER_URL, GITHUB_REPOSITORY_OWNER and GITHUB_EVENT_PATH set the way a runner sets them."}],')"
run_plan_save "$(new_mission)" "$P"
check "7h …an entrypoint carrying a realRunProof is ACCEPTED" "[ '$RC' -eq 0 ]"

# THE HARNESS DOES NOT JUDGE THE SENTENCE. A proof that openly describes a stub
# is accepted MECHANICALLY and bounced by the REVIEWER — the record/infer split
# this project holds to. If the harness ever starts grading prose here, this
# check is what fails, and that is the point.
P="$(mkplan proof-is-a-stub '    "seams": [{"producer": "a", "consumer": "b",
               "roundTripTest": "tests/test_x.py",
               "roundTripProof": "it mocks the producer and feeds the consumer a hand-written SAMPLE fixture."}],
    "entrypoints": [],
    "entrypointsNote": "none.",')"
run_plan_save "$(new_mission)" "$P"
check "7i a roundTripProof that DESCRIBES a stub is accepted mechanically (the reviewer's job, not the harness's)" \
  "[ '$RC' -eq 0 ]"

# Back-compat is unchanged: a pre-S236 plan has neither key and never reaches
# the proof rule at all.
P="$(mkplan legacy-again '')"
run_plan_save "$(new_mission)" "$P"
check "7j a plan with NO seams/entrypoints is still untouched by the proof rule" \
  "[ '$RC' -eq 0 ]"

# ===========================================================================
section "B. the host checklist (behavior 4)"
# ===========================================================================
# A stub worker adapter that RECORDS every assembled prompt, and answers the
# plan role with the fixture plan named by $STUB_PLAN.
make_adapter() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
sub="$1"; role="${LCARS_WORKER_ROLE:-$3}"; outdir="$4"; prompt="$5"
[ "$sub" = "spawn" ] || exit 0
{ printf '=== ROLE %s ===\n' "$role"; printf '%s\n' "$prompt"; } >>"$PROMPTS"
case "$role" in
  plan)
    cp "$STUB_PLAN" "$outdir/plan.json"
    if [ "${STUB_OMIT_MATRIX:-0}" != 1 ]; then
      printf '{"visibleChanges":[],"dependencies":[],"combinations":[],"outboundCalls":[]}\n' > "$outdir/coverage-matrix.json"
    fi
    ;;
  plan-review)
    if [ -n "${STUB_TAMPER_MATRIX:-}" ]; then printf '{}\n' > "$STUB_TAMPER_MATRIX"; fi
    printf '{ "passed": true, "issues": [] }\n' > "$outdir/verdict.json"
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A real git repo on a real mission branch, parked at $2 (default `plan`), whose
# origin URL is $1 (empty = no origin at all). $3 is extra PRD prose.
e2e_repo() { # origin-url [stage] [prd-extra] -> echoes repo dir
  local url="$1" stage="${2:-plan}" prd_extra="${3:-}"
  local repo; repo="$(mktemp -d "$TMPROOT/e2e.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    printf '# fixture\n' > README.md
    printf '# Context\n\nA fixture repo.\n' > CONTEXT.md
    git add -A && git commit -q -m init
    git checkout -q -b lcars/test-001
    [ -n "$url" ] && git remote add origin "$url"
    :
  ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  # ONE FIELD PER LINE — lcars_state_set edits LINES, and refuses anything else
  # (that refusal is what makes `hostChecklist` observable here at all).
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "$stage",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null
}
JSON
  printf '# PRD\n\nA CLI writes a request file; a workflow handler parses it.\n%s\n' \
    "$prd_extra" > "$d/prd.md"
  printf '# Validated Plan\n\n## Synthesis\nBuild it.\n' > "$d/validated-plan.md"
  make_adapter "$repo.adapter"
  printf '#!/usr/bin/env bash\necho UNEXPECTED-SPAWN >&2\nexit 96\n' >"$repo.worker"
  chmod +x "$repo.worker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo.gh"; chmod +x "$repo.gh"
  echo "$repo"
}

# A legal plan for the stub worker to emit, in the CANONICAL shape
# validate_plan_json parses (one field per line; `{` / `}` on their own lines).
cat > "$TMPROOT/stub-plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Write the request file",
    "description": "The CLI writes request.json; the hub handler parses it.",
    "acceptanceCriteria": ["a request round-trips"],
    "seams": [{"producer": "the CLI writes request.json", "consumer": "the hub handler parses request.json", "roundTripTest": "tests/test_request_roundtrip.py", "roundTripProof": "it calls the real CLI writer, reads back the file it actually wrote, and hands that to the real parse_request()."}],
    "entrypoints": [],
    "entrypointsNote": "no new CI entrypoint in this slice.",
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "rationale": "the seam is the whole slice"
  }
]
JSON

run_plan_stage() { # repo -> sets RC, OUT, PROMPT_FILE
  : >"$1.prompts"
  # GIT_TERMINAL_PROMPT / GIT_SSH_COMMAND: a bogus origin must FAIL FAST if
  # anything ever tries to reach it, never hang this suite on a credential or
  # host-key prompt.
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/usr/bin/false \
      PROMPTS="$1.prompts" STUB_PLAN="$TMPROOT/stub-plan.json" \
      bash "$SCRIPT" plan --mission test-001 2>&1 )"
  RC=$?
  PROMPT_FILE="$1.prompts"
}

# --- a NON-github.com origin -------------------------------------------------
R="$(e2e_repo 'git@github.example.com:acme/widgets.git')"
run_plan_stage "$R"
check "4a the Plan stage runs on a non-github.com origin" "[ '$RC' -eq 0 ]"
check "4b the assembled Plan prompt carries the HOST CHECKLIST" \
  "grep -qi 'host checklist' '$PROMPT_FILE'"
check "4c …and names the host" "grep -qF 'github.example.com' '$PROMPT_FILE'"
check "4d …and requires every outbound URL built FROM the host" \
  "grep -qi 'outbound' '$PROMPT_FILE'"
check "4e …and the runner's gh pinned with --hostname" \
  "grep -qF -- '--hostname' '$PROMPT_FILE'"
check "4f …and gh auth status --hostname" \
  "grep -qF 'gh auth status --hostname' '$PROMPT_FILE'"
check "4g …and a test asserting the URL a real call goes to" \
  "grep -qi 'the URL a real call' '$PROMPT_FILE'"
check "4h the mission carries hostChecklist: true" \
  "grep -q '\"hostChecklist\"' '$R/.git/lcars/missions/test-001/state.json' && grep -q 'hostChecklist\": true' '$R/.git/lcars/missions/test-001/state.json'"

# --- a github.com origin: NEITHER ------------------------------------------
R2="$(e2e_repo 'git@github.com:acme/widgets.git')"
run_plan_stage "$R2"
check "4i the Plan stage runs on a github.com origin" "[ '$RC' -eq 0 ]"
check "4j …and the prompt carries NO host checklist" \
  "! grep -qi 'host checklist' '$PROMPT_FILE'"
check "4k …and the mission carries NO hostChecklist flag" \
  "! grep -q 'hostChecklist' '$R2/.git/lcars/missions/test-001/state.json'"

# --- a github.com origin whose PRD NAMES a host ----------------------------
R3="$(e2e_repo 'git@github.com:acme/widgets.git' plan \
  'All issues live on github.example.com, so pin every call with --hostname.')"
run_plan_stage "$R3"
check "4l a PRD naming a host fires the checklist even on a github.com origin" \
  "[ '$RC' -eq 0 ] && grep -qi 'host checklist' '$PROMPT_FILE'"
check "4m …and the mission carries hostChecklist: true" \
  "grep -q 'hostChecklist\": true' '$R3/.git/lcars/missions/test-001/state.json'"

# "github.com" written out in a PRD must NOT be read as a non-default host.
R4="$(e2e_repo 'git@github.com:acme/widgets.git' plan \
  'The repo lives on github.com and the badge links to github.com.')"
run_plan_stage "$R4"
check "4n a PRD that only says github.com fires NOTHING" \
  "[ '$RC' -eq 0 ] && ! grep -qi 'host checklist' '$PROMPT_FILE'"

# --- Plan Review is told to check the host criterion ------------------------
run_plan_review() { # repo -> RC, PROMPT_FILE
  : >"$1.prompts"
  OUT="$( cd "$1" && env \
      LCARS_GH_BIN="$1.gh" LCARS_WORKER_BIN="$1.worker" \
      LCARS_WORKER_ADAPTER="$1.adapter" LCARS_WORKER_HANG_SECS=0 \
      GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=/usr/bin/false \
      PROMPTS="$1.prompts" \
      bash "$SCRIPT" plan-review --mission test-001 2>&1 )"
  RC=$?
  PROMPT_FILE="$1.prompts"
}
R5="$(e2e_repo 'git@github.example.com:acme/widgets.git' plan-review)"
cp "$TMPROOT/stub-plan.json" "$R5/.git/lcars/missions/test-001/plan.json"
run_plan_review "$R5"
check "4o the reviewer is told to check every outbound call names its host" \
  "grep -qi 'host' '$PROMPT_FILE' && grep -qF 'github.example.com' '$PROMPT_FILE'"

R6="$(e2e_repo 'git@github.com:acme/widgets.git' plan-review)"
cp "$TMPROOT/stub-plan.json" "$R6/.git/lcars/missions/test-001/plan.json"
run_plan_review "$R6"
check "4p …and a github.com mission's reviewer prompt carries no host block" \
  "! grep -qi 'host checklist' '$PROMPT_FILE'"

# S332: drive the new artifact through the real Plan/Review boundaries. Workers
# remain stubs; these assertions prove plumbing, not live model enumeration.
check "S332 Plan persists the worker's matrix alongside its tickets" \
  "[ -f '$R/.git/lcars/missions/test-001/coverage-matrix.json' ]"
run_plan_review "$R"
check "S332 Review receives the persisted matrix by path" \
  "[ '$RC' -eq 0 ] && grep -qF '$R/.git/lcars/missions/test-001/coverage-matrix.json' '$PROMPT_FILE'"
R_MISSING="$(e2e_repo '')"
STUB_OMIT_MATRIX=1 run_plan_stage "$R_MISSING"
check "S332 a new Plan worker cannot omit the matrix" \
  "[ '$RC' -ne 0 ] && printf '%s' \"\$OUT\" | grep -q 'coverage matrix cannot be read'"
check "S332 the missing-matrix rejection reaches the retrying worker" \
  "grep -q 'coverage matrix cannot be read' '$PROMPT_FILE'"
check "S332 missing matrix never installs a plan or spends a reviewer round" \
  "[ ! -f '$R_MISSING/.git/lcars/missions/test-001/plan.json' ] && [ ! -f '$R_MISSING/.git/lcars/missions/test-001/plan-review-1.json' ]"
R_TAMPER="$(e2e_repo '' plan-review)"
cp "$TMPROOT/stub-plan.json" "$R_TAMPER/.git/lcars/missions/test-001/plan.json"
printf '{"visibleChanges":[],"dependencies":[],"combinations":[],"outboundCalls":[]}\n' \
  > "$R_TAMPER/.git/lcars/missions/test-001/coverage-matrix.json"
STUB_TAMPER_MATRIX="$R_TAMPER/.git/lcars/missions/test-001/coverage-matrix.json" run_plan_review "$R_TAMPER"
check "S332 a read-only reviewer cannot rewrite the accepted coverage matrix" \
  "[ '$RC' -ne 0 ] && grep -q 'worker_fence_breach.*coverage-matrix.json' '$R_TAMPER/.git/lcars/missions/test-001/events.jsonl'"

# ===========================================================================
section "C. the Verify readout RECORDS the declared tests (behavior 5)"
# ===========================================================================
MID="test-001"
verify_repo() { # -> echoes repo dir, mission at `verify`, one tracked test file
  local repo; repo="$(mktemp -d "$TMPROOT/ver.XXXX")"
  (
    cd "$repo"
    git init -q -b main; git config user.email t@t; git config user.name t
    mkdir -p tests
    printf 'def test_roundtrip(): assert True\n' > tests/test_request_roundtrip.py
    printf '# fixture\n' > README.md
    git add -A && git commit -q -m init
  ) >/dev/null 2>&1
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m/tickets/t-001"
  cat > "$m/state.json" <<JSON
{
  "id": "$MID",
  "type": "feature",
  "title": "Add the hub",
  "stage": "verify",
  "branch": "lcars/$MID",
  "base": "main",
  "githubIssue": null
}
JSON
  # parse_waves_table is LINE-oriented: "wave" and each "id" need their own line.
  cat > "$m/waves.json" <<'JSON'
[
  { "wave": 1, "tickets": [
      { "id": "t-001", "issue": null } ] }
]
JSON
  printf '{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",\n  "newTests": [], "testEdits": [], "flipFlop": "expected" }\n' \
    > "$m/tickets/t-001/result.json"
  cat > "$m/plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Write the request file",
    "description": "d",
    "acceptanceCriteria": ["c"],
    "seams": [{"producer": "the CLI writes request.json", "consumer": "the hub handler parses request.json", "roundTripTest": "tests/test_request_roundtrip.py", "roundTripProof": "it calls the real CLI writer and feeds what it wrote to the real parse_request()."}],
    "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml", "realRunTest": "tests/test_publish_workflow.py", "realRunProof": "it runs the publish step command from the repo root with the Actions env set."}],
    "estimatedReadLoc": 1,
    "estimatedTestLoc": 1,
    "estimatedNewLoc": 1,
    "dependencies": [],
    "establishesSharedInfrastructure": false,
    "rationale": "r"
  }
]
JSON
  echo "$repo"
}

RV="$(verify_repo)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RV/gh"; chmod +x "$RV/gh"
VOUT="$RV/out.txt"; VRC=0
( cd "$RV" && LCARS_GH_BIN="$RV/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$VOUT" 2>&1 ) || VRC=$?
check "5a verify-summary exits 0" "[ '$VRC' -eq 0 ]"
check "5b it lists the ticket's SEAM" \
  "grep -qF 'the CLI writes request.json' '$VOUT' && grep -qF 'the hub handler parses request.json' '$VOUT'"
check "5c the TRACKED round-trip test is recorded exists:yes" \
  "grep -F 'tests/test_request_roundtrip.py' '$VOUT' | grep -qi 'exists: *yes'"
check "5d the ABSENT real-run test is recorded exists:no" \
  "grep -F 'tests/test_publish_workflow.py' '$VOUT' | grep -qi 'exists: *no'"
check "5e it names the entrypoint's workflow file" \
  "grep -qF '.github/workflows/publish.yml' '$VOUT'"
check "5f it is a RECORD, not a judgement (no pass/fail verdict on a seam)" \
  "! grep -Ei 'seam.*(FAILED|UNPROVEN|REJECT)' '$VOUT'"

# a pre-S236 plan (no seams/entrypoints) prints NOTHING new
RV2="$(verify_repo)"
"${LCARS_PYTHON_BIN:-python3}" - "$RV2/.git/lcars/missions/$MID/plan.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for t in d: t.pop("seams", None); t.pop("entrypoints", None)
json.dump(d, open(p, "w"), indent=2)
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$RV2/gh"; chmod +x "$RV2/gh"
V2="$RV2/out.txt"; V2RC=0
( cd "$RV2" && LCARS_GH_BIN="$RV2/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$V2" 2>&1 ) || V2RC=$?
check "5g a plan with no seams/entrypoints prints no seams block at all" \
  "[ '$V2RC' -eq 0 ] && ! grep -qi 'SEAMS AND ENTRYPOINTS' '$V2'"

# --- S236 fix round 2: the READOUT PRINTS THE RECORDED PROOF SENTENCE --------
# The round's whole argument is that a bare test path is unauditable. The Verify
# gate was handing the captain exactly that bare path while the sentence that
# makes it auditable sat unprinted in plan.json. It is printed now — beside the
# test path it qualifies, WHOLE, and still graded by nobody.
#
# flat <file> — the file with every run of whitespace (newlines included)
# collapsed to one space. A wrapped sentence reassembles EXACTLY under this, so
# these checks pin the WORDS, not where the wrapper happened to break the line,
# and a truncation cannot pass them.
flat() { tr '\n\t' '  ' < "$1" | tr -s ' '; }

SEAMPROOF='it calls the real CLI writer and feeds what it wrote to the real parse_request().'
RUNPROOF='it runs the publish step command from the repo root with the Actions env set.'
check "5h the seam's recorded roundTripProof is PRINTED" \
  "flat '$VOUT' | grep -qF \"\$SEAMPROOF\""
check "5i the entrypoint's recorded realRunProof is PRINTED" \
  "flat '$VOUT' | grep -qF \"\$RUNPROOF\""
check "5j the proof sits BESIDE the test path it qualifies (labelled, under it)" \
  "printf '%s' \"\$(flat '$VOUT')\" | grep -qF 'tests/test_request_roundtrip.py (exists: yes) proof:'"
check "5k …and the entrypoint's proof under ITS test path" \
  "printf '%s' \"\$(flat '$VOUT')\" | grep -qF 'tests/test_publish_workflow.py (exists: no) proof:'"
check "5l the readout STILL passes no judgement on the proof" \
  "! grep -Ei 'proof.*(FAILED|UNPROVEN|REJECT|WEAK|SUSPICIOUS|LOOKS )' '$VOUT' && ! grep -Ei 'proof: *(ok|good|bad)\b' '$VOUT'"

# A LONG proof sentence — the real shape a planner writes — must come out WHOLE.
# Truncating it here would be BUG-105's defect class committed a second time.
RV3="$(verify_repo)"
LONGSEAM='it shells out to the real `lcars request` CLI writer so the bytes on disk are the ones production writes, then hands that exact file to the real parse_request() in the hub handler with no fixture or hand-rolled dict anywhere between the two halves, and asserts the round-tripped record equals the one the CLI was given.'
LONGRUN='it extracts the publish step run: block straight out of the workflow YAML and executes that exact command from the repo root with GITHUB_SERVER_URL, GITHUB_REPOSITORY_OWNER and GITHUB_EVENT_PATH set the way Actions sets them, so the command CI runs is the command under test.'
"${LCARS_PYTHON_BIN:-python3}" - "$RV3/.git/lcars/missions/$MID/plan.json" "$LONGSEAM" "$LONGRUN" <<'PY'
import json, sys
p, s, r = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
d[0]["seams"][0]["roundTripProof"] = s
d[0]["entrypoints"][0]["realRunProof"] = r
json.dump(d, open(p, "w"), indent=2)
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$RV3/gh"; chmod +x "$RV3/gh"
V3="$RV3/out.txt"; V3RC=0
( cd "$RV3" && LCARS_GH_BIN="$RV3/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$V3" 2>&1 ) || V3RC=$?
check "5m a LONG seam proof is rendered IN FULL, nothing cut" \
  "[ '$V3RC' -eq 0 ] && flat '$V3' | grep -qF \"\$LONGSEAM\""
check "5n …and a LONG entrypoint proof in full" \
  "flat '$V3' | grep -qF \"\$LONGRUN\""
check "5o …with NO truncation marker anywhere in the readout" \
  "! grep -q '…' '$V3' && ! grep -q '\.\.\.' '$V3'"
check "5p …and no single line runs past 100 columns (it WRAPPED, it did not sprawl)" \
  "[ \"\$(awk '{ if (length(\$0) > 100) c++ } END { print c+0 }' '$V3')\" -eq 0 ]"

# BACK-COMPAT, the narrow case: a plan that declares seams/entrypoints but NO
# proof keys (every plan written before S236 fix round 1) gets the OLD readout
# and not one new line.
RV4="$(verify_repo)"
"${LCARS_PYTHON_BIN:-python3}" - "$RV4/.git/lcars/missions/$MID/plan.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for t in d:
    for e in t.get("seams", []): e.pop("roundTripProof", None)
    for e in t.get("entrypoints", []): e.pop("realRunProof", None)
json.dump(d, open(p, "w"), indent=2)
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$RV4/gh"; chmod +x "$RV4/gh"
V4="$RV4/out.txt"; V4RC=0
( cd "$RV4" && LCARS_GH_BIN="$RV4/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$V4" 2>&1 ) || V4RC=$?
check "5q a plan with seams but NO proof keys still gets the seams readout" \
  "[ '$V4RC' -eq 0 ] && grep -qi 'SEAMS AND ENTRYPOINTS' '$V4'"
check "5r …and prints NO proof line at all" \
  "! grep -q 'proof:' '$V4'"
check "5s …and the test paths + exists facts are unchanged" \
  "grep -F 'tests/test_request_roundtrip.py' '$V4' | grep -qi 'exists: *yes' && grep -F 'tests/test_publish_workflow.py' '$V4' | grep -qi 'exists: *no'"
check "5t a pre-S236 plan (neither key) prints no proof line either" \
  "! grep -q 'proof:' '$V2'"

# --- S236 fix round 3: the `exists` fact is CWD-INDEPENDENT ------------------
# The readout enumerated the tracked set with a bare `git ls-files`, which prints
# paths RELATIVE TO CWD. Run from anywhere but the repo root the tracked set held
# no `tests/...` path at all, so EVERY declared test read `exists: no` — the one
# mechanical fact the record carries, silently inverted by the directory the
# captain happened to be standing in. Nothing about the mission changes here;
# only the cwd does, so the record must not move.
RV3="$(verify_repo)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RV3/gh"; chmod +x "$RV3/gh"
mkdir -p "$RV3/sub/deeper"
V3="$RV3/out-root.txt"; V3RC=0
( cd "$RV3" && LCARS_GH_BIN="$RV3/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$V3" 2>&1 ) || V3RC=$?
V4="$RV3/out-sub.txt"; V4RC=0
( cd "$RV3/sub/deeper" && LCARS_GH_BIN="$RV3/gh" bash "$SCRIPT" verify-summary --mission "$MID" \
    >"$V4" 2>&1 ) || V4RC=$?
check "5u verify-summary runs from a SUBDIRECTORY" "[ '$V4RC' -eq 0 ]"
check "5v …and the TRACKED round-trip test still reads exists:yes from there" \
  "grep -F 'tests/test_request_roundtrip.py' '$V4' | grep -qi 'exists: *yes'"
check "5w …and the genuinely ABSENT real-run test still reads exists:no" \
  "grep -F 'tests/test_publish_workflow.py' '$V4' | grep -qi 'exists: *no'"
check "5x the readout from the repo root is unchanged (tracked test reads exists:yes)" \
  "[ '$V3RC' -eq 0 ] && grep -F 'tests/test_request_roundtrip.py' '$V3' | grep -qi 'exists: *yes'"
check "5y the seams record is byte-identical from the root and from the subdirectory" \
  "diff <(grep -E 'seam:|entrypoint|exists:' '$V3') <(grep -E 'seam:|entrypoint|exists:' '$V4') >/dev/null"

# ===========================================================================
section "D. the prompt contract — three prompts, one rule (behavior 6)"
# ===========================================================================
# Asserted BY HEADING, so a later edit cannot silently drop a rule: the heading
# is the anchor and the rule's load-bearing sentence is checked under it.
#
# blk <file> <heading-substring> -> the lines from that heading to the next
# heading at the same-or-higher level.
blk() {
  "${LCARS_PYTHON_BIN:-python3}" - "$1" "$2" <<'PY'
import re, sys
want = sys.argv[2].lower()
lines = open(sys.argv[1]).read().split("\n")
out, lvl = [], None
for ln in lines:
    m = re.match(r"^(#{1,6})\s+(.*)$", ln)
    if m:
        if lvl is None:
            if want in m.group(2).lower():
                lvl = len(m.group(1)); out.append(ln)
            continue
        if len(m.group(1)) <= lvl:
            break
    if lvl is not None:
        out.append(ln)
sys.stdout.write("\n".join(out))
PY
}
# has <label> <needle> <haystack> — asserts the needle is present, with
# WHITESPACE NORMALISED on both sides. What is pinned is the RULE, not where the
# author happened to wrap the line: a reflow must not be able to fail this, and
# a deletion must not be able to pass it.
nows() { printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' '; }
has() { # label needle haystack
  if printf '%s' "$(nows "$3")" | grep -qiF "$(nows "$2")"; then
    ok "$1"
  else
    bad "$1 (missing: $2)"
  fi
}

# --- plan.md ---------------------------------------------------------------
PB="$(blk "$STAGES/plan.md" "seams")"
check "6a plan.md has a seams/entrypoints HEADING" "[ -n \"\$PB\" ]"
has "6b plan.md teaches the seams key"              'seams'         "$PB"
has "6c …and the entrypoints key"                   'entrypoints'   "$PB"
has "6d …and roundTripTest"                         'roundTripTest' "$PB"
has "6e …and realRunTest"                           'realRunTest'   "$PB"
has "6f …and seamsNote for an empty list"           'seamsNote'     "$PB"
has "6g …and entrypointsNote"                       'entrypointsNote' "$PB"
has "6h …THE ROUND-TRIP RULE, in the worker's own words" \
    'no hand-written fixture between them' "$PB"
has "6i …build the body with the real producer"     'real producer' "$PB"
has "6j …feed it to the real consumer"              'real consumer' "$PB"
has "6k …the stubbed-seam rule"  "stubs the seam it claims to prove" "$PB"
has "6l …does not count as proof"                   "count as proof" "$PB"
has "6m …the real-entrypoint rule: GITHUB_SERVER_URL"       'GITHUB_SERVER_URL' "$PB"
has "6n …GITHUB_REPOSITORY_OWNER"                   'GITHUB_REPOSITORY_OWNER' "$PB"
has "6o …GITHUB_EVENT_PATH"                         'GITHUB_EVENT_PATH' "$PB"
has "6p …same cwd"                                  'same cwd'      "$PB"
has "6q …same command"                              'same command'  "$PB"
# S179 vs S236 — a DIRECT CONFLICT between two tracked documents, which is how
# this file reached 4 worked examples and 8 json fences without either side
# noticing. The S179 guard (wave-serialization 2i/2j/7j/7k) pins this file to ONE
# worked example and TWO json fences, because three MEASURED live turns
# transplanted a prompt's worked example verbatim onto an unrelated screen. This
# check originally demanded TWO MORE copyable ones.
# Resolved on the captain's ruling (BUG-108, option a): consolidate. Both cases
# are still TAUGHT — in prose, with no copyable ticket for a worker to lift. Do
# not restore a copyable example here; raising the count is how the guard dies.
check "6r plan.md teaches BOTH cases in practice — a seam and a workflow entrypoint" \
  "[ \"\$(printf '%s' \"\$PB\" | grep -c 'In practice')\" -ge 2 ]"
has "6s …the workflow example names a .github/workflows file" \
    '.github/workflows/' "$PB"
# S236 fix round 1 — the producer records the claim, and the workflow hatch.
has "6s1 plan.md teaches roundTripProof"                'roundTripProof' "$PB"
has "6s2 …and realRunProof"                             'realRunProof'   "$PB"
check "6s3 …BOTH worked examples carry the proof sentence" \
  "[ \"\$(printf '%s' \"\$PB\" | grep -c 'roundTripProof')\" -ge 2 ] && printf '%s' \"\$PB\" | grep -q 'realRunProof'"
check "6s4 …and the canonical plan.json shape carries roundTripProof" \
  "grep -q 'roundTripProof' '$STAGES/plan.md'"
has "6s5 …and it teaches the by-name disclaimer for a workflow it does not own" \
    'entrypointsNote' "$PB"
has "6s6 …naming the file in the note is the recorded disclaimer" \
    'do not own' "$PB"

# --- plan-review.md --------------------------------------------------------
RB="$(blk "$STAGES/plan-review.md" "seams")"
check "6t plan-review.md has a seams/entrypoints AUDIT heading" "[ -n \"\$RB\" ]"
has "6u the reviewer audits seams for COMPLETENESS against the PRD" 'complete' "$RB"
has "6v …a writer + a reader with an empty seams[] is an objection" 'empty' "$RB"
has "6w …and it is raised as an ordinary objection (a LOOP), not a new verdict" \
    'objection' "$RB"
has "6x …reject a roundTripTest description that stubs either half" 'stub' "$RB"
has "6y …and the entrypoints half"  'entrypoints' "$RB"
check "6z plan-review.md still documents ONLY the three verdict outcomes" \
  "! grep -qiE '\"(verdict|outcome)\": *\"(seam|stubbed)' '$STAGES/plan-review.md'"
check "6z2 …and passed/issues is still the verdict shape" \
  "grep -q '\"passed\"' '$STAGES/plan-review.md' && grep -q '\"issues\"' '$STAGES/plan-review.md'"
# S236 fix round 1 — the reviewer audits a field that ALWAYS EXISTS, not prose a
# planner may or may not have volunteered. On a conforming plan `roundTripTest`
# is a bare path and there is nothing to read; `roundTripProof` is the sentence
# the producer is REQUIRED to record, so the audit has a surface every time.
has "6z3 the reviewer audits roundTripProof BY NAME"   'roundTripProof' "$RB"
has "6z4 …and realRunProof"                            'realRunProof'   "$RB"
has "6z5 …and rejects an empty / boilerplate proof"    'boilerplate'    "$RB"
check "6z6 …and no longer rests the audit on reading the roundTripTest PATH" \
  "! printf '%s' \"\$(nows \"\$RB\")\" | grep -qiF 'read what each \`roundTripTest\` is described as'"
has "6z7 …a proof naming no real consumer is an objection" 'objection'   "$RB"
# RULING OF 2026-10-01 — the prose scan is deleted, so the reviewer is the ONLY
# backstop on a ticket that adds a CI workflow and declares no entrypoint. The
# prompt must say that PLAINLY and must not lean on a mechanical pre-filter.
has "6z8 the reviewer is told it is the ONLY check on an undeclared CI workflow" \
    'the only check' "$RB"
has "6z9 …and that is stated about a CI workflow specifically" \
    'CI workflow' "$RB"
check "6z10 …and the prompt no longer claims the harness checks that a workflow file has an entrypoint" \
  "! printf '%s' \"\$(nows \"\$RB\")\" | grep -qiF 'a workflow file has an entrypoint'"

# --- implement-tdd.md ------------------------------------------------------
IB="$(blk "$STAGES/implement-tdd.md" "seams")"
check "6aa implement-tdd.md has a seams/entrypoints heading" "[ -n \"\$IB\" ]"
has "6bb the ticket's seams tests are part of ITS TDD" 'TDD' "$IB"
has "6cc …both halves REAL" 'both halves' "$IB"
has "6dd …it names roundTripTest" 'roundTripTest' "$IB"
has "6ee …and realRunTest"        'realRunTest'   "$IB"
# The recorded claim BINDS the implementer: the test it writes must be the test
# the plan said it was, and a disagreement is said out loud, not quietly closed.
has "6ff …the recorded roundTripProof binds the test it writes" 'roundTripProof' "$IB"
has "6gg …and realRunProof"                                    'realRunProof'   "$IB"

# ===========================================================================
section "E. Plan Review's objections reach a human WHOLE (behavior 8)"
# ===========================================================================
# BUG: print_objections field-split raw JSON on `"` and printed field 8, so ANY
# objection containing an escaped `\"` was cut at the first one. Observed live,
# all three objections of a real verdict destroyed:
#
#     • t-002 — roundTripProof is boilerplate: \
#     • t-003 — roundTripProof is boilerplate: \
#     • t-004 — realRunProof is boilerplate: \
#
# It matters most for the objection class S236 introduced, because a boilerplate
# objection MUST quote the sentence it objects to — and the same function feeds
# `write_pending` / `pendingQuestion`, so the question the captain is asked at a
# round-3 escalation was truncated too. The full text was always intact in the
# verdict JSON; only every surface a human reads was broken.

review_repo() { # [round] -> echoes repo dir, mission parked at plan-review
  local repo; repo="$(mktemp -d "$TMPROOT/rev.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  local d="$repo/.git/lcars/missions/test-001"; mkdir -p "$d"
  cat > "$repo/.git/lcars/config.json" <<'JSON'
{ "model": "claude-sonnet", "projectName": "fixture", "contextFile": null }
JSON
  cat > "$d/state.json" <<JSON
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "plan-review",
  "branch": "lcars/test-001",
  "base": "main",
  "githubIssue": null,
  "planReviewRound": ${1:-0}
}
JSON
  cp "$TMPROOT/stub-plan.json" "$d/plan.json"
  echo "$repo"
}
run_review_save() { # repo verdict [extra-env …]
  local repo="$1" verdict="$2"; shift 2
  OUT="$( cd "$repo" && env LCARS_GH_BIN=true "$@" \
      bash "$SCRIPT" review-save --mission test-001 --verdict "$verdict" 2>&1 )"
  RC=$?
}
# A literal backslash, so the truncation checks below can name the character the
# old awk render left behind without six layers of shell quoting.
BS="$(printf '\\')"
# Build a failing verdict from (ticketId, objection) pairs, through a real JSON
# writer, so the escaping in the fixture is the escaping a real reviewer emits.
# ONE ISSUE PER LINE — the CANONICAL verdict shape run.sh documents, and the
# shape the live truncation was measured on (`$4`/`$8` landed on the ticket id
# and the objection, and the objection died at its first escaped quote).
# $PRETTY=1 writes the same verdict fully pretty-printed instead.
mkverdict() { # outfile tid obj [tid obj …]
  PRETTY="${PRETTY:-0}" "${LCARS_PYTHON_BIN:-python3}" - "$@" <<'VPY'
import json, os, sys
out, rest = sys.argv[1], sys.argv[2:]
issues = [{"ticketId": rest[i], "objection": rest[i + 1]}
          for i in range(0, len(rest), 2)]
if os.environ.get("PRETTY") == "1":
    json.dump({"passed": False, "issues": issues}, open(out, "w"), indent=2)
else:
    with open(out, "w") as fh:
        fh.write('{ "passed": false, "issues": [\n')
        fh.write(",\n".join("  " + json.dumps(i) for i in issues))
        fh.write("\n] }\n")
VPY
}

# THE OBJECTION THAT EXPOSED IT — a boilerplate objection quoting the sentence.
QUOTED='roundTripProof is boilerplate: "drives both halves for real" restates the rule instead of describing THIS test; name the producer, the consumer and what crosses between them.'
PLAIN='Horizontal slice - only the data layer; re-slice it so the ticket ships a behavior.'
V="$TMPROOT/verdict-quoted.json"
mkverdict "$V" t-002 "$QUOTED" t-003 "$PLAIN"
R="$(review_repo 0)"
run_review_save "$R" "$V"
check "8a review-save on a failing verdict bounces the Mission back to Plan" \
  "[ '$RC' -eq 0 ] && printf '%s' \"\$OUT\" | grep -qF 'Stage:  plan'"
check "8b an objection containing an ESCAPED QUOTE is printed IN FULL" \
  "printf '%s' \"\$OUT\" | grep -qF \"\$QUOTED\""
check "8c …it is not cut at the first quote (the measured truncation)" \
  "! printf '%s' \"\$OUT\" | grep -qF \"boilerplate: \$BS\""
check "8d …and no backslash-escape leaks into the lines a human reads" \
  "! printf '%s' \"\$OUT\" | grep -F '    • ' | grep -qF \"\$BS\""
check "8e the PLAIN objection still prints exactly as before (the control)" \
  "printf '%s' \"\$OUT\" | grep -qF \"    • t-003 — \$PLAIN\""
check "8f …and the quoted one keeps the same <prefix><ticket> — <objection> shape" \
  "printf '%s' \"\$OUT\" | grep -qF \"    • t-002 — roundTripProof is boilerplate:\""
check "8g every objection is still ONE LINE (write_pending and head -1 depend on it)" \
  "[ \"\$(printf '%s' \"\$OUT\" | grep -c '    • ')\" -eq 2 ]"

# A LONG objection — the real shape of this class — comes out whole, not clipped.
LONG='realRunProof is boilerplate: "runs it the way CI does" restates the rule; this entry names ".github/workflows/publish.yml" and tests/test_publish_workflow.py, so say which "run:" step the test reads, which command it executes, from which cwd, and which of GITHUB_SERVER_URL, GITHUB_REPOSITORY_OWNER and GITHUB_EVENT_PATH it sets, or name a different test.'
V2="$TMPROOT/verdict-long.json"
mkverdict "$V2" t-004 "$LONG"
R2="$(review_repo 0)"
run_review_save "$R2" "$V2"
check "8h a LONG objection with several escaped quotes is printed IN FULL" \
  "printf '%s' \"\$OUT\" | grep -qF \"\$LONG\""
check "8i …with no truncation marker" \
  "! printf '%s' \"\$OUT\" | grep -q '…' && ! printf '%s' \"\$OUT\" | grep -qF '...'"

# THE ESCALATION QUESTION. The round-3 branch feeds the SAME function into
# write_pending and pendingQuestion, so the question the captain is asked was
# truncated at the first quote too.
R3="$(review_repo 2)"
run_review_save "$R3" "$V"
MD3="$R3/.git/lcars/missions/test-001"
check "8j the third failing round escalates to the human" \
  "[ '$RC' -eq 0 ] && printf '%s' \"\$OUT\" | grep -qi 'escalated'"
PQ="$("${LCARS_PYTHON_BIN:-python3}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pendingQuestion"])' "$MD3/state.json" 2>/dev/null)"
check "8k the escalation's pendingQuestion carries the FULL objection text" \
  "[ \"\$PQ\" = \"t-002 — \$QUOTED\" ]"
PJ="$("${LCARS_PYTHON_BIN:-python3}" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(d["questions"]))' "$MD3/pending.json" 2>/dev/null)"
check "8l pending.json's first question carries it in full too" \
  "printf '%s' \"\$PJ\" | grep -qF \"\$QUOTED\""
check "8m …and pending.json holds ONE question per objection, not one per quote" \
  "[ \"\$(printf '%s\n' \"\$PJ\" | grep -c .)\" -eq 2 ]"
check "8n …and the escalation readout prints the full objection as well" \
  "printf '%s' \"\$OUT\" | grep -qF \"\$QUOTED\""

# THE SAME VERDICT, FULLY PRETTY-PRINTED. A reviewer that writes its verdict with
# an indenting JSON writer puts every key on its own line, and the old field-split
# then landed on different fields entirely — it printed the objection as the
# TICKET and an empty objection after it. A JSON reader does not care.
VP="$TMPROOT/verdict-pretty.json"
PRETTY=1 mkverdict "$VP" t-002 "$QUOTED" t-003 "$PLAIN"
R5="$(review_repo 0)"
run_review_save "$R5" "$VP"
check "8r a PRETTY-PRINTED verdict renders the full objection against its ticket" \
  "[ '$RC' -eq 0 ] && printf '%s' \"\$OUT\" | grep -qF \"    • t-002 — \$QUOTED\""
check "8s …and the plain one too" \
  "printf '%s' \"\$OUT\" | grep -qF \"    • t-003 — \$PLAIN\""

# FAIL OPEN. This renders a display on a REJECTION path: no interpreter must not
# take down the Plan Review stage. Same stance as validate_plan_seams' UNCHECKED
# branch — degrade to something readable, never die.
R4="$(review_repo 0)"
run_review_save "$R4" "$V" LCARS_PYTHON_BIN=/nonexistent/python3
check "8o with NO interpreter the stage still completes and bounces to Plan" \
  "[ '$RC' -eq 0 ] && printf '%s' \"\$OUT\" | grep -qF 'Stage:  plan'"
check "8p …and still names each objecting ticket" \
  "printf '%s' \"\$OUT\" | grep -q 't-002' && printf '%s' \"\$OUT\" | grep -q 't-003'"
check "8q …degraded, it still carries the objection's own words" \
  "printf '%s' \"\$OUT\" | grep -qF 'restates the rule'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
