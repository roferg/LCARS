#!/usr/bin/env bash
# S185 — THE INITIALIZATION MISSION: scaffold waiver, real gates after it,
# promotion at approve, and the unlock the captain can SEE.
#
# The captain's 2026-09-05 ruling: the test foundation is established BEFORE any
# normal mission runs, by an INITIALIZATION mission filed from Establish Vision,
# with the captain at Verify to watch the suite run. This suite pins the four
# facts that ruling turns into code:
#
#   1. The SCAFFOLD ticket (the mission's FIRST, by PLAN/WAVE order) may exit
#      through the audited waiver — flipFlop "not-applicable" WITH a recorded
#      reason — and that reason surfaces at Verify. A waiver with NO reason still
#      rejects, everywhere.
#   2. A waiver on ANY LATER ticket of an initialization mission is REJECTED.
#      A waiver on ANY ticket of a NORMAL mission is UNCHANGED — accepted.
#   3. The declared-setup safety mechanics are unchanged and TIGHTER: the scaffold
#      arm may only target the REPO ROOT, a workspace root is refused, and an
#      install carrying a shell metacharacter is REFUSED AND NOT EXECUTED.
#   4. At APPROVE (not mid-mission) the established testCommand is PROMOTED into
#      the repo's config.json, and the foundation gate + the BOARD's own data
#      path both unlock on it.
#
# Plus the salvage's SEPARATE FINDING: an absent/ENOENT runner on the parent leg
# must read as an ENV FAILURE (inconclusive), never as proof.
#
# ZERO worker spend by construction: nothing here spawns a worker at all, and the
# one drive that could runs under a PATH shim with COUNTING fakes for BOTH
# `claude` and `copilot` plus the SPEND FUSE.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
APPROVE="$REPO_ROOT/skills/lcars-approve/approve.sh"
GATE="$REPO_ROOT/skills/lcars-init/foundation-gate.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# --- SPEND FUSE (S182 rig.sh contract, verbatim) ----------------------------
# Every leg that COULD spawn a worker runs under a PATH shim carrying COUNTING
# fakes for BOTH `claude` and `copilot`. An empty shim dir puts the REAL billed
# claude on PATH — that leaked money once on this round — so the fuse refuses to
# run at all when either fake is missing. Never the LCARS_WORKER_BIN env var:
# S159 proved it loses to a persisted state.json workerBin.
SHIM="$TMPROOT/shim"; SPEND_LOG="$TMPROOT/spend.log"
mkdir -p "$SHIM"; : > "$SPEND_LOG"
for b in claude copilot; do
  cat > "$SHIM/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) echo "0.0.0-s185-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\n' "\$(basename "\$0")" >> "$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$b"
done
fuse() {
  [ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] && return 0
  echo "SPEND FUSE TRIPPED: no counting claude/copilot in '$SHIM' — REFUSING (would bill)" >&2
  return 1
}
fuse || exit 1
spends() { awk '/^SPAWN/{n++} END{print n+0}' "$SPEND_LOG" 2>/dev/null || echo 0; }

# --- fixtures ---------------------------------------------------------------
# A REAL git repo carrying a REAL mission dir. `type` is "initialization" or "".
new_mission_repo() { # type [ticket-ids...] -> echoes repo dir
  local mtype="$1"; shift
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false )
  printf '# ctx\n' > "$repo/CONTEXT.md"
  ( cd "$repo" && git add -A && git commit -qm init )
  local md="$repo/.git/lcars/missions/m-001"
  mkdir -p "$md/tickets" "$repo/.git/lcars"
  printf '{\n  "version": 1\n}\n' > "$repo/.git/lcars/config.json"
  {
    printf '{\n  "id": "m-001",\n'
    [ -n "$mtype" ] && printf '  "missionType": "%s",\n' "$mtype"
    printf '  "type": "feature",\n  "title": "t",\n  "stage": "implement",\n  "branch": "lcars/m-001"\n}\n'
  } > "$md/state.json"
  # waves.json in the canonical Schedule shape — wave-then-plan ORDER is what
  # `init_first_ticket` reads, deliberately not a directory listing.
  {
    printf '[\n'
    local n=0 t
    for t in "$@"; do
      n=$((n+1))
      [ "$n" -gt 1 ] && printf ',\n'
      printf '  {\n    "wave": %s,\n    "tickets": [\n      {\n        "id": "%s",\n        "issue": null\n      }\n    ]\n  }' "$n" "$t"
    done
    printf '\n]\n'
  } > "$md/waves.json"
  for t in "$@"; do mkdir -p "$md/tickets/$t"; done
  echo "$repo"
}

result_json() { # file ticket flipFlop [reason]
  local f="$1" t="$2" ff="$3" why="${4:-}"
  {
    printf '{ "ticketId": "%s", "passed": true, "attempts": 1, "summary": "s",\n' "$t"
    printf '  "newTests": [], "testEdits": [], "flipFlop": "%s"' "$ff"
    [ -n "$why" ] && printf ',\n  "flipFlopReason": "%s"' "$why"
    printf ' }\n'
  } > "$f"
}

pv() { # repo mission ticket result-file -> PVRC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" proof-validate-result-test --mission "$2" --ticket "$3" --result "$4" 2>&1 )"
  PVRC="$(printf '%s\n' "$OUT" | sed -n 's/^PVRC=//p' | tail -1)"
}

# ===========================================================================
# A. THE FIRST TICKET IS DERIVED FROM THE PLAN/WAVE ORDERING
# ===========================================================================
# The scaffold ticket is "the mission's first ticket", and WHICH one that is has
# exactly one honest source: the order Schedule wrote into waves.json. A
# filesystem listing of tickets/ answers a different question (which ticket dir
# was created or sorted first) and would hand the waiver to whichever ticket
# happened to run first. So the fixture below deliberately gives the SCAFFOLD
# ticket a name that sorts LAST.
repo="$(new_mission_repo initialization t-zzz-scaffold t-aaa-later)"
OUT="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        bash "$SCRIPT" init-first-ticket-test --mission m-001 --ticket t-zzz-scaffold 2>&1 )"
if printf '%s' "$OUT" | grep -q '^FIRST=t-zzz-scaffold$'; then
  ok "A1. the first ticket comes from waves.json ORDER, not a directory listing"
else
  bad "A1. first ticket wrong: $OUT"
fi
if printf '%s' "$OUT" | grep -q '^SCAFFOLD=yes$'; then
  ok "A2. the wave-1 ticket is recognised as the scaffold ticket"
else
  bad "A2. wave-1 ticket not recognised as scaffold: $OUT"
fi
OUT="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        bash "$SCRIPT" init-first-ticket-test --mission m-001 --ticket t-aaa-later 2>&1 )"
if printf '%s' "$OUT" | grep -q '^SCAFFOLD=no$'; then
  ok "A3. a later ticket is NOT the scaffold ticket even when it sorts first"
else
  bad "A3. later ticket wrongly read as scaffold: $OUT"
fi

# ===========================================================================
# B. THE WAIVER DISCIPLINE
# ===========================================================================
repo="$(new_mission_repo initialization t-scaffold t-two)"
rf="$TMPROOT/r.json"

result_json "$rf" t-scaffold not-applicable "this ticket CREATES the test system, so its parent commit has no runner to be red against"
pv "$repo" m-001 t-scaffold "$rf"
if [ "$PVRC" = 0 ]; then
  ok "B1. scaffold ticket + waiver + reason → ACCEPTED"
else
  bad "B1. scaffold waiver rejected: $OUT"
fi

result_json "$rf" t-scaffold not-applicable ""
pv "$repo" m-001 t-scaffold "$rf"
if [ "$PVRC" != 0 ] && printf '%s' "$OUT" | grep -q 'flipFlopReason'; then
  ok "B2. a waiver with NO reason still REJECTS, even for the scaffold ticket"
else
  bad "B2. reasonless waiver accepted for the scaffold ticket (rc=$PVRC)"
fi

result_json "$rf" t-two not-applicable "nothing testable changed"
pv "$repo" m-001 t-two "$rf"
if [ "$PVRC" != 0 ] && printf '%s' "$OUT" | grep -q 'INITIALIZATION mission'; then
  ok "B3. a waiver on a NON-FIRST ticket of an initialization mission is REJECTED"
else
  bad "B3. later-ticket waiver was accepted (rc=$PVRC): $OUT"
fi
if printf '%s' "$OUT" | grep -q 't-scaffold'; then
  ok "B3b. the rejection NAMES the ticket that may waive"
else
  bad "B3b. the rejection does not name the scaffold ticket: $OUT"
fi
# S185 fix round 1 (D2). The sentence was built as
#   "${ff_first:+…\"$ff_first\", not this one}${ff_first:-…could not be read…}"
# and `${var:-…}` expands to $var ITSELF when $var is non-empty, so the id was
# appended to its own sentence: '…the scaffold ticket is "t-scaffold", not this
# one t-scaffold.' This is the ONE sentence the captain reads on a rejection.
if printf '%s' "$OUT" | grep -q 'not this one\. Only the SCAFFOLD ticket'; then
  ok "B3c. …exactly once — the sentence ends cleanly, no duplicated ticket id"
else
  bad "B3c. the rejection sentence is malformed (duplicated id?): $(printf '%s' "$OUT" | head -2)"
fi
if [ "$(printf '%s' "$OUT" | grep -o 't-scaffold' | wc -l | tr -d ' ')" = 1 ]; then
  ok "B3d. the scaffold ticket id appears exactly ONCE in the rejection"
else
  bad "B3d. the scaffold ticket id is repeated: $(printf '%s' "$OUT" | head -2)"
fi

# THE NORMAL MISSION IS UNCHANGED, byte for byte. tests/proof-gates.test.sh has
# ~10 cases relying on this (comment-only refactor, pure rename, pure config).
normal="$(new_mission_repo "" t-one t-two)"
result_json "$rf" t-two not-applicable "comment-only refactor; no behaviour changed"
pv "$normal" m-001 t-two "$rf"
if [ "$PVRC" = 0 ]; then
  ok "B4. a waiver on a LATER ticket of a NORMAL mission is still ACCEPTED"
else
  bad "B4. the normal-mission waiver regressed: $OUT"
fi

# THE VICE THE SCAFFOLD TICKET WOULD OTHERWISE BE CAUGHT IN. Its job is to build
# a test system, which means AUTHORING a test — and the declared-edits guard
# demands every test file in the diff be declared. But the generic rule rejects
# "not-applicable" beside a non-empty newTests ("a ticket that authors tests must
# expect them to flip"), which is exactly the premise that is false here: the
# parent commit has no runner for those tests to be red against. Measured on the
# stage path: without this the scaffold ticket bounced on `declared-edits (FAIL)`
# every time (tests/drives/s185/stage-drive.sh).
scaffold_with_tests() { # file ticket
  cat > "$1" <<JSON
{ "ticketId": "$2", "passed": true, "attempts": 1, "summary": "s",
  "newTests": ["test/greet.test.js"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the test system; its parent has no runner" }
JSON
}
scaffold_with_tests "$rf" t-scaffold
pv "$repo" m-001 t-scaffold "$rf"
if [ "$PVRC" = 0 ]; then
  ok "B6. the SCAFFOLD ticket may DECLARE its tests and still waive the flip-flop"
else
  bad "B6. the scaffold ticket cannot declare the test it wrote: $OUT"
fi
scaffold_with_tests "$rf" t-two
pv "$repo" m-001 t-two "$rf"
if [ "$PVRC" != 0 ]; then
  ok "B7. a LATER ticket declaring tests AND waiving is still REJECTED"
else
  bad "B7. a later ticket got the scaffold exemption"
fi
scaffold_with_tests "$rf" t-two
pv "$normal" m-001 t-two "$rf"
if [ "$PVRC" != 0 ] && printf '%s' "$OUT" | grep -q 'must expect them to flip'; then
  ok "B8. a NORMAL mission still rejects waiver-plus-newTests, in the old words"
else
  bad "B8. the normal-mission rule changed (rc=$PVRC): $OUT"
fi

# FAIL-CLOSED. An initialization mission whose ordering cannot be read must not
# hand the waiver out on a guess.
noplan="$(new_mission_repo initialization)"
rm -f "$noplan/.git/lcars/missions/m-001/waves.json"
result_json "$rf" t-x not-applicable "nothing to prove"
pv "$noplan" m-001 t-x "$rf"
if [ "$PVRC" != 0 ]; then
  ok "B5. an unreadable mission ordering REFUSES the waiver (fail-closed)"
else
  bad "B5. the waiver was granted with no readable ordering"
fi
# S185 fix round 1 (D4). B5 above deletes waves.json; this is the OTHER shape —
# waves.json PRESENT and unparseable, with a perfectly good plan sitting beside
# it. `init_first_ticket` consults waves.json ALONE once it exists and does NOT
# drop back to plan order, because waves.json is wave-then-plan order and can
# legitimately differ from the plan's rows: a plan-order answer on a SCHEDULED
# mission would be a GUESS at which ticket is the scaffold one, and that guess is
# what grants the mission's only waiver. Refusing beats guessing, and this pins
# that it still refuses.
corrupt="$(new_mission_repo initialization t-scaffold t-two)"
printf 'this is not JSON at all {{{\n' > "$corrupt/.git/lcars/missions/m-001/waves.json"
printf '[\n  { "id": "t-scaffold", "title": "t" },\n  { "id": "t-two", "title": "t" }\n]\n' \
  > "$corrupt/.git/lcars/missions/m-001/approved-plan.json"
result_json "$rf" t-scaffold not-applicable "this ticket CREATES the test system"
pv "$corrupt" m-001 t-scaffold "$rf"
if [ "$PVRC" != 0 ]; then
  ok "B5b. a PRESENT-but-unreadable waves.json REFUSES the waiver — no fallback guess"
else
  bad "B5b. a corrupt ordering was second-guessed from plan order and the waiver GRANTED"
fi

# ===========================================================================
# C. THE WAIVER'S REASON SURFACES AT VERIFY
# ===========================================================================
# The whole honesty contract rests on this: LCARS never claims a proof it did not
# make, and the captain at Verify is the proof — which only works if Verify TELLS
# them the ticket was waived and why.
vrepo="$(new_mission_repo initialization t-scaffold)"
vmd="$vrepo/.git/lcars/missions/m-001"
python3 - "$vmd/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["stage"]="verify"
json.dump(d,open(p,"w"),indent=2)
PY
result_json "$vmd/tickets/t-scaffold/result.json" t-scaffold not-applicable \
  "this ticket establishes the repo test system; its parent has no runner"
cat > "$vmd/tickets/t-scaffold/flip-flop.json" <<'JSON'
{ "ticket": "t-scaffold", "verdict": "skipped",
  "reason": "declared not-applicable: this ticket establishes the repo test system; its parent has no runner" }
JSON
OUT="$( cd "$vrepo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
        bash "$SCRIPT" verify-summary --mission m-001 2>&1 )" || true
if printf '%s' "$OUT" | grep -q 'flip-flop N/A' \
   && printf '%s' "$OUT" | grep -q 'establishes the repo test system'; then
  ok "C1. Verify's proof readout SHOWS the waiver AND its recorded reason"
else
  bad "C1. the waiver reason is INVISIBLE at Verify — the dishonesty this design exists to avoid: $(printf '%s' "$OUT" | tail -5)"
fi

# ===========================================================================
# D. DECLARED-SETUP SAFETY — the salvage, deliberately taken
# ===========================================================================
setup_repo() { # -> repo with an initialization mission at m-001/t-scaffold
  local r; r="$(new_mission_repo initialization t-scaffold)"
  echo "$r"
}
apply_setup() { # repo manifest setup-dir pkg extra-env... -> ASRC + ASNOTE + OUT
  local r="$1" mf="$2" sd="$3" pkg="$4"; shift 4
  OUT="$( cd "$r" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
          bash "$SCRIPT" apply-declared-setup-test --mission m-001 --ticket t-scaffold \
               --result "$mf" --setup "$sd" "$pkg" 2>&1 )"
  ASRC="$(printf '%s\n' "$OUT" | sed -n 's/^ASRC=//p' | tail -1)"
  ASNOTE="$(printf '%s\n' "$OUT" | sed -n 's/^ASNOTE=//p' | tail -1)"
}

# D1. THE METACHARACTER GUARD. The allowlist is a PREFIX match with no end
# anchor and the command is handed to `bash -c`, so before this guard
# `npm --version && touch X` was accepted AND EXECUTED (driven, S183 tester).
repo="$(setup_repo)"
PWNED="$TMPROOT/pwned-$$"
rm -f "$PWNED"
mkdir -p "$TMPROOT/sd-empty"
printf '{ "package": "", "gap": "no runner", "installCommand": "npm --version && touch %s" }\n' "$PWNED" \
  > "$TMPROOT/mf-meta.json"
apply_setup "$repo" "$TMPROOT/mf-meta.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'metacharacter'; then
  ok "D1a. an install with a shell metacharacter is REFUSED"
else
  bad "D1a. metacharacter install accepted (rc=$ASRC note=$ASNOTE)"
fi
if [ ! -e "$PWNED" ]; then
  ok "D1b. …and it was NOT EXECUTED (no side effect on disk)"
else
  bad "D1b. THE INSTALL RAN — $PWNED exists"
fi

# The guard is a TIGHTENING of the same mechanic, so it covers the ORIGINAL
# evidence-gated package arm too, not only the new scaffold arm.
repo="$(setup_repo)"
mkdir -p "$repo/pkgA"
PWNED2="$TMPROOT/pwned2-$$"; rm -f "$PWNED2"
printf '{ "package": "pkgA", "gap": "g", "installCommand": "npm i; touch %s" }\n' "$PWNED2" \
  > "$TMPROOT/mf-meta2.json"
apply_setup "$repo" "$TMPROOT/mf-meta2.json" "$TMPROOT/sd-empty" pkgA
if [ "$ASRC" != 0 ] && [ ! -e "$PWNED2" ]; then
  ok "D1c. the guard covers the evidence-gated PACKAGE arm as well"
else
  bad "D1c. the package arm still executes a chained install (rc=$ASRC)"
fi

# D2. THE SCAFFOLD ARM ONLY TARGETS THE REPO ROOT.
repo="$(setup_repo)"
printf '{ "package": "tools/inner", "gap": "g", "installCommand": "" }\n' > "$TMPROOT/mf-sub.json"
apply_setup "$repo" "$TMPROOT/mf-sub.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'REPO ROOT'; then
  ok "D2. a scaffold setup aimed at a SUBDIRECTORY is refused"
else
  bad "D2. subdirectory scaffold setup accepted (rc=$ASRC note=$ASNOTE)"
fi

# D3. NEVER src/ — unchanged, and it still holds on the scaffold arm.
repo="$(setup_repo)"
mkdir -p "$TMPROOT/sd-src/src"
printf 'x\n' > "$TMPROOT/sd-src/src/evil.ts"
printf '{ "package": "", "gap": "g", "installCommand": "" }\n' > "$TMPROOT/mf-root.json"
apply_setup "$repo" "$TMPROOT/mf-root.json" "$TMPROOT/sd-src" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'src/'; then
  ok "D3. a scaffold declaration touching src/ is refused"
else
  bad "D3. src/ declaration accepted on the scaffold arm (rc=$ASRC note=$ASNOTE)"
fi

# D4. A WORKSPACE ROOT is refused — LCARS will not manufacture a root test
# system for a workspace it does not understand (its packages' pre-existing
# tests would be collected as credit for work this mission never did).
for marker in pnpm-workspace.yaml lerna.json nx.json turbo.json rush.json go.work; do
  repo="$(setup_repo)"
  printf 'x\n' > "$repo/$marker"
  OUT="$( cd "$repo" && env LCARS_GP_ROOT="$repo" bash "$SCRIPT" greenfield-workspace-test 2>&1 )"
  if printf '%s' "$OUT" | grep -q "$marker"; then
    ok "D4-$marker. recognised as a workspace marker"
  else
    bad "D4-$marker. NOT recognised (got: $OUT)"
  fi
done
repo="$(setup_repo)"
printf '{ "name": "x", "workspaces": ["packages/*"] }\n' > "$repo/package.json"
OUT="$( cd "$repo" && env LCARS_GP_ROOT="$repo" bash "$SCRIPT" greenfield-workspace-test 2>&1 )"
if printf '%s' "$OUT" | grep -q 'workspaces'; then
  ok "D4-npm. a \"workspaces\" key in package.json is a workspace marker"
else
  bad "D4-npm. npm workspaces not recognised (got: $OUT)"
fi
repo="$(setup_repo)"
printf '[workspace]\nmembers = ["a"]\n' > "$repo/Cargo.toml"
OUT="$( cd "$repo" && env LCARS_GP_ROOT="$repo" bash "$SCRIPT" greenfield-workspace-test 2>&1 )"
if printf '%s' "$OUT" | grep -q 'Cargo.toml'; then
  ok "D4-cargo. Cargo [workspace] is a workspace marker"
else
  bad "D4-cargo. cargo workspace not recognised (got: $OUT)"
fi
repo="$(setup_repo)"
printf 'x\n' > "$repo/pnpm-workspace.yaml"
apply_setup "$repo" "$TMPROOT/mf-root.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'WORKSPACE'; then
  ok "D5. apply_declared_setup REFUSES a workspace root on the scaffold arm"
else
  bad "D5. workspace root accepted (rc=$ASRC note=$ASNOTE)"
fi

# D6. A repo where nothing detectable results → refused. A runner nothing can
# invoke is not an established test system.
repo="$(setup_repo)"
mkdir -p "$TMPROOT/sd-noop"
printf 'nothing\n' > "$TMPROOT/sd-noop/NOTES.md"
apply_setup "$repo" "$TMPROOT/mf-root.json" "$TMPROOT/sd-noop" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'detect'; then
  ok "D6. a setup that leaves no DETECTABLE test command is refused"
else
  bad "D6. undetectable setup accepted (rc=$ASRC note=$ASNOTE)"
fi

# ===========================================================================
# D7. THE REFUSAL THE CAPTAIN CAN SEE (S185 fix round 1, D3)
# ===========================================================================
# impl_greenfield_invite REFUSES the scaffold door on a workspace root with no
# root manifest, and it is right to: ADD-only has nothing to refuse there, so
# LCARS would INVENT a root manifest and then take credit for the packages'
# pre-existing tests. But GREENFIELD_REFUSAL_NOTE was written to events.jsonl and
# NOWHERE ELSE, so the captain — who is running the initialization mission — got
# the generic S182 park and its verdict line telling them to "Start it with
# Establish Vision": circular advice to someone already there.
#
# Driven through the REAL implement STAGE (never implement-ticket): the shortcut
# entry point is blind to the seam the captain actually walks.
ws_park() { # repo -> OUT + pending.json readable via wsay()
  OUT="$( cd "$1" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true \
          bash "$SCRIPT" implement --mission m-001 2>&1 )"
  WSRC=$?
}
wsay() { cat "$1/.git/lcars/missions/m-001/pending.json" 2>/dev/null; }

wsrepo="$(new_mission_repo initialization t-scaffold)"
printf 'packages:\n  - "packages/*"\n' > "$wsrepo/pnpm-workspace.yaml"
( cd "$wsrepo" && git add -A && git commit -qm ws >/dev/null 2>&1 )
ws_park "$wsrepo"
if [ "$WSRC" = 0 ] && grep -q '"awaitingHuman": *true' "$wsrepo/.git/lcars/missions/m-001/state.json"; then
  ok "D7a. a workspace-root initialization mission PARKS (rc 0, not a die)"
else
  bad "D7a. no park (rc=$WSRC): $(printf '%s' "$OUT" | tail -4)"
fi
if wsay "$wsrepo" | grep -q 'WORKSPACE ROOT (pnpm-workspace.yaml)'; then
  ok "D7b. the park the captain READS carries the real reason, naming the marker"
else
  bad "D7b. the refusal note is still events.jsonl-only: $(wsay "$wsrepo" | tr -d '\n' | head -c 400)"
fi
if wsay "$wsrepo" | grep -q 'will not invent one'; then
  ok "D7c. …and says WHY LCARS refused rather than inventing a root test system"
else
  bad "D7c. the note is truncated to the marker alone"
fi
if grep -q 'test_setup_invite_refused' "$wsrepo/.git/lcars/missions/m-001/events.jsonl" 2>/dev/null; then
  ok "D7d. the refusal is still on the timeline too (events.jsonl unchanged)"
else
  bad "D7d. the refusal event stopped being emitted"
fi

# THE S182 PARK IS INTACT for every non-workspace caller. Same fixture shape, a
# NORMAL mission: no refusal note exists, so the wording must be exactly what
# S182 shipped — no stray sentence, no dangling connector.
nwrepo="$(new_mission_repo "" t-one)"
ws_park "$nwrepo"
if wsay "$nwrepo" | grep -q 'no test command is configured for this repo'; then
  ok "D7e. a NON-workspace park still speaks the S182 wording"
else
  bad "D7e. the S182 park wording changed: $(wsay "$nwrepo" | tr -d '\n' | head -c 400)"
fi
if wsay "$nwrepo" | grep -qi 'refused to establish\|Why this INITIALIZATION mission'; then
  bad "D7f. a refusal note leaked into a park it is not about"
else
  ok "D7f. …and carries NO refusal note — the addition is empty by default"
fi
if [ "$(spends)" = 0 ]; then
  ok "D7g. both parks hired NOBODY (zero worker spend)"
else
  bad "D7g. a worker was hired on the park path — REAL MONEY IF THE SHIM SLIPS"
fi

# ===========================================================================
# E. THE SEPARATE FINDING — an ENOENT parent leg is an ENV FAILURE, not proof
# ===========================================================================
# proof_parent_red_kind counted `npm ENOENT` as a red that PROVES work. For an
# initialization mission that is the load-bearing failure mode: if ticket 1's
# setup never lands on the branch, ticket 2's parent has no runner, ENOENT reads
# as "red = proof", and LCARS reports a flip-flop that never happened.
env_kind() { # runner-output -> rc 0 when classified as an env failure
  printf '%s' "$1" | bash "$SCRIPT" red-gate-env-detect-test
}
if env_kind 'npm error code ENOENT
npm error syscall open
npm error path /tmp/x/package.json
npm error enoent Could not read package.json'; then
  ok "E1. npm ENOENT on a manifest-less parent reads as an ENV FAILURE"
else
  bad "E1. npm ENOENT still reads as a real red (= false proof)"
fi
if env_kind 'bash: node_modules/.bin/vitest: No such file or directory'; then
  ok "E2. a missing runner BINARY reads as an ENV FAILURE"
else
  bad "E2. a missing runner binary still reads as a real red"
fi
# …and the tightening must not swallow a GENUINE red.
if env_kind "AssertionError: expected 'ok' to equal 'npm error code ENOENT'"; then
  bad "E3. an assertion QUOTING npm's ENOENT was misread as an env failure"
else
  ok "E3. an assertion quoting the ENOENT phrase is still a genuine red"
fi
if env_kind '  ✗ adds two numbers
  1 failed | 2 passed
  expected 3 to be 4'; then
  bad "E4. a plain assertion red was misread as an env failure"
else
  ok "E4. a plain assertion red is untouched"
fi

# ===========================================================================
# F. PROMOTION AT APPROVE — and the unlock, on the board's own data path
# ===========================================================================
# Before approve the repo config must NOT carry testCommand: the runner exists
# only on the mission branch until merge, and writing repo config mid-mission
# would poison sibling missions.
mk_verify_repo() { # -> repo at verify with an open PR + an established runner
  local r; r="$(new_mission_repo initialization t-scaffold)"
  local md="$r/.git/lcars/missions/m-001"
  python3 - "$md/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["stage"]="verify"; d["prUrl"]="https://example.invalid/pr/1"; d["issue"]=1
json.dump(d,open(p,"w"),indent=2)
PY
  printf '{\n  "testCommand": "npx vitest run",\n  "establishedBy": "t-scaffold"\n}\n' \
    > "$md/test-command.json"
  echo "$r"
}
repo="$(mk_verify_repo)"
CFG="$repo/.git/lcars/config.json"
if ! grep -q 'testCommand' "$CFG"; then
  ok "F1. BEFORE approve, repo config has NO testCommand"
else
  bad "F1. repo config was written mid-mission"
fi
# The foundation gate refuses on this repo before the promotion.
( cd "$repo" && bash "$GATE" --check >/dev/null 2>&1 )
if [ "$?" = 20 ]; then
  ok "F2. BEFORE approve, the foundation gate REFUSES (lcars file + holodeck locked)"
else
  bad "F2. the gate did not refuse before promotion"
fi

# A stub host adapter: pr-view reports OPEN, pr-merge succeeds. `reconcile` is
# stubbed to exit 0 (base not ahead) so approve goes straight to the merge.
cat > "$TMPROOT/host.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr-view)  printf 'state\tOPEN\nbaseRefName\tmain\nheadRefName\tlcars/m-001\ntitle\tt\nnumber\t1\n'; exit 0 ;;
  pr-merge) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMPROOT/host.sh"
cat > "$TMPROOT/run-stub.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMPROOT/run-stub.sh"

AOUT="$( cd "$repo" && env PATH="$SHIM:$PATH" \
          LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
          LCARS_HOST_ADAPTER="$TMPROOT/host.sh" \
          LCARS_RUN_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_RESOLVE_LOGS_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
          bash "$APPROVE" --mission m-001 2>&1 )"
ARC=$?
if grep -q '"testCommand"[[:space:]]*:[[:space:]]*"npx vitest run"' "$CFG"; then
  ok "F3. AT approve (post-merge), testCommand is PROMOTED into repo config"
else
  bad "F3. promotion did not happen (rc=$ARC): $(printf '%s' "$AOUT" | tail -5)"
fi
if printf '%s' "$AOUT" | grep -q 'FOUNDATION ESTABLISHED'; then
  ok "F3b. approve TELLS the captain the foundation landed and what unlocked"
else
  bad "F3b. approve was silent about the promotion"
fi
if grep -q 'foundation_promoted' "$repo/.git/lcars/missions/m-001/events.jsonl" 2>/dev/null; then
  ok "F3c. the promotion is on the mission timeline"
else
  bad "F3c. no foundation_promoted event"
fi

# F4. THE UNLOCK — the CLI seam.
( cd "$repo" && bash "$GATE" --check >/dev/null 2>&1 )
if [ "$?" = 0 ]; then
  ok "F4. AFTER approve, the foundation gate ALLOWS — lcars file + holodeck unlock"
else
  bad "F4. the gate still refuses after promotion"
fi

# F5. THE UNLOCK ON THE BOARD'S OWN DATA PATH. S183 shipped a lock that did not
# exist on screen and all three of S184's blockers were the same class: a
# harness called the renderer and handed it a field the SERVER never sends. So
# this asks the REAL server adapter for the REAL payload the browser reads.
BOARD_BEFORE="$TMPROOT/board-before.json"; BOARD_AFTER="$TMPROOT/board-after.json"
board_meta() { # repo outfile -> 0 when the adapter produced a payload
  ( cd "$REPO_ROOT/web" && python3 - "$1" "$2" <<'PY'
import json, sys, os
sys.path.insert(0, os.getcwd())
from lcars_serve.local_adapter import LocalAdapter
try:
    b = LocalAdapter(sys.argv[1]).board()
except Exception as e:
    print("ADAPTER-ERROR: %s" % e); sys.exit(1)
json.dump(b.get("meta", {}), open(sys.argv[2], "w"))
PY
  )
}
locked="$(mk_verify_repo)"
if board_meta "$locked" "$BOARD_BEFORE"; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("foundation") in ("greenfield","untested") else 1)' "$BOARD_BEFORE"; then
    ok "F5a. the SERVER sends meta.foundation (the field board.js locks on) before promotion"
  else
    bad "F5a. the board payload carries NO lock: $(cat "$BOARD_BEFORE")"
  fi
else
  bad "F5a. the local adapter could not build a board: $(cat "$BOARD_BEFORE" 2>/dev/null)"
fi
if board_meta "$repo" "$BOARD_AFTER"; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if d.get("foundation") else 0)' "$BOARD_AFTER"; then
    ok "F5b. AFTER promotion the SERVER stops sending meta.foundation — the board unlocks"
  else
    bad "F5b. the board is STILL locked after promotion: $(cat "$BOARD_AFTER")"
  fi
else
  bad "F5b. the local adapter could not build a board after promotion"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if d.get("frontDoor") else 0)' "$BOARD_AFTER"; then
  ok "F5c. …and the Establish Vision front door is gone from the payload too"
else
  bad "F5c. the front door still replaces the board after promotion"
fi

# F6. A NORMAL mission's approve is untouched — nothing promoted, nothing said.
nrepo="$(new_mission_repo "" t-one)"
nmd="$nrepo/.git/lcars/missions/m-001"
python3 - "$nmd/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["stage"]="verify"; d["prUrl"]="https://example.invalid/pr/2"; d["issue"]=2
json.dump(d,open(p,"w"),indent=2)
PY
printf '{\n  "testCommand": "npm test"\n}\n' > "$nrepo/.git/lcars/config.json"
NOUT="$( cd "$nrepo" && env PATH="$SHIM:$PATH" \
          LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
          LCARS_HOST_ADAPTER="$TMPROOT/host.sh" \
          LCARS_RUN_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_RESOLVE_LOGS_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
          bash "$APPROVE" --mission m-001 2>&1 )"
if printf '%s' "$NOUT" | grep -q 'FOUNDATION' ; then
  bad "F6. a NORMAL mission's approve now talks about the foundation"
else
  ok "F6. a normal mission's approve is unchanged (no promotion, no new output)"
fi
if grep -q '"testCommand"[[:space:]]*:[[:space:]]*"npm test"' "$nrepo/.git/lcars/config.json"; then
  ok "F6b. …and it did not touch the repo's existing testCommand"
else
  bad "F6b. a normal approve rewrote repo config"
fi

# ===========================================================================
# F7. THE PROMOTED COMMAND IS THE REAL DETECTOR'S — AND A SHELL CAN RUN IT
# ===========================================================================
# S185 FIX ROUND 1, and the reason the defect survived F1-F6: every leg above
# promotes a HAND-WRITTEN record whose value is "npx vitest run" — a string with
# no embedded quotes, which is NOT a string the real detector can produce. Every
# command the detector actually emits embeds them: VITEST_RELATIVIZING_CMD
# (lcars-common.sh), the jest / mocha / `npm test --` arms, and pytest. approve
# read the record with a json_str that stopped at the first \", so the DEFAULT
# JS/TS greenfield path promoted
#     npx vitest run ${LCARS_TESTS_DIR:+\
# into repo config — `bash: -c: line 0: unexpected EOF while looking for
# matching `}'` — while readiness went on reporting foundation "ready ... its
# runner resolves", because it only ever resolved the first token, `npx`. The
# holodeck unlocked on a repo whose runner no shell can parse.
#
# So NOTHING here is hand-written. The REAL detector produces the command, the
# REAL mission-local writer records it, the REAL approve promotes it, and the
# REAL readiness surface is asked what it thinks of the result. The assertions
# are byte-equality with what the detector said, and PARSEABILITY BY A SHELL —
# never "non-empty", never "equals a string this test made up".
READINESS="$REPO_ROOT/skills/lcars-init/readiness.sh"

mk_real_verify_repo() { # -> repo at verify with an open PR + a REAL vitest tree
  local r; r="$(new_mission_repo initialization t-scaffold)"
  # The tree a scaffold ticket leaves behind on a JS/TS repo: a package.json
  # whose `test` script names vitest. This is what makes the detector take the
  # VITEST_RELATIVIZING_CMD arm — the default path, not an edge.
  printf '{\n  "name": "gf",\n  "private": true,\n  "scripts": { "test": "vitest run" }\n}\n' \
    > "$r/package.json"
  ( cd "$r" && git add -A && git commit -qm scaffold >/dev/null 2>&1 )
  python3 - "$r/.git/lcars/missions/m-001/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["stage"]="verify"; d["prUrl"]="https://example.invalid/pr/3"; d["issue"]=3
json.dump(d,open(p,"w"),indent=2)
PY
  echo "$r"
}

rrepo="$(mk_real_verify_repo)"
RMD="$rrepo/.git/lcars/missions/m-001"
RCFG="$rrepo/.git/lcars/config.json"

# THE REAL DETECTOR + THE REAL MISSION-LOCAL WRITER, through run.sh's own code.
ROUT="$( cd "$rrepo" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" greenfield-record-cmd-test --mission m-001 --ticket t-scaffold 2>&1 )"
DETECTED="$(printf '%s\n' "$ROUT" | sed -n 's/^DETECTED=//p' | tail -1)"

if [ -n "$DETECTED" ] && printf '%s' "$DETECTED" | grep -q '"'; then
  ok "F7a. the REAL detector emits a command with EMBEDDED QUOTES (the hazard is live)"
else
  bad "F7a. the fixture does not exercise the hazard — detector said: '$DETECTED' ($ROUT)"
fi
if grep -q '\\"' "$RMD/test-command.json" 2>/dev/null; then
  ok "F7b. …and the REAL mission-local record stores it ESCAPED"
else
  bad "F7b. the record carries no escaped quote: $(cat "$RMD/test-command.json" 2>/dev/null)"
fi

# THE REAL APPROVE (same stubs as F3: pr-view OPEN, pr-merge succeeds, reconcile
# a no-op), so promotion runs on the shipped post-merge path.
R7OUT="$( cd "$rrepo" && env PATH="$SHIM:$PATH" \
          LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
          LCARS_HOST_ADAPTER="$TMPROOT/host.sh" \
          LCARS_RUN_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_RESOLVE_LOGS_SCRIPT="$TMPROOT/run-stub.sh" \
          LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
          bash "$APPROVE" --mission m-001 2>&1 )"

# READ IT BACK THROUGH THE PRODUCT'S OWN SURFACE — readiness.sh --json is what
# the board, the filing gate and the holodeck all consult.
rjson() { ( cd "$1" && bash "$READINESS" --json 2>/dev/null ); }
rfield() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get(sys.argv[1]) or "")' "$2" <<<"$1"; }
RJ="$(rjson "$rrepo")"
PROMOTED="$(rfield "$RJ" testCommand)"

if [ -n "$PROMOTED" ] && [ "$PROMOTED" = "$DETECTED" ]; then
  ok "F7c. the promoted testCommand is the detector's command, BYTE FOR BYTE"
else
  bad "F7c. TRUNCATED IN PROMOTION — detector said [$DETECTED], config carries [$PROMOTED] (approve: $(printf '%s' "$R7OUT" | tail -3))"
fi
# THE ASSERTION THAT WOULD HAVE CAUGHT IT: can a shell parse what was promoted?
if [ -n "$PROMOTED" ] && bash -n -c "$PROMOTED" >/dev/null 2>&1; then
  ok "F7d. …and a SHELL CAN PARSE IT (bash -n on the promoted command)"
else
  bad "F7d. the promoted command is a SHELL SYNTAX ERROR: [$PROMOTED] — $(bash -n -c "$PROMOTED" 2>&1 | head -1)"
fi
# …and it still resolves to a runnable command with $LCARS_TESTS_DIR set, which
# is how the gate actually invokes it.
if [ -n "$PROMOTED" ] \
   && ( cd "$rrepo" && LCARS_TESTS_DIR="$rrepo/test" bash -n -c "$PROMOTED" >/dev/null 2>&1 ); then
  ok "F7e. …under \$LCARS_TESTS_DIR too — the shape the red gate runs it in"
else
  bad "F7e. the promoted command does not parse with LCARS_TESTS_DIR set: [$PROMOTED]"
fi

# THE DISHONESTY HALF. readiness must not certify a foundation it cannot parse.
R7STATUS="$(rfield "$RJ" status)"; R7FND="$(rfield "$RJ" foundation)"
if [ "$R7STATUS" = ready ] && [ "$R7FND" = ready ]; then
  ok "F7f. readiness reports ready — for a command that DOES parse"
elif [ "$R7STATUS" = broken ] && ! command -v npx >/dev/null 2>&1; then
  ok "F7f. readiness reports broken because npx is absent on this box (command itself is sound)"
else
  bad "F7f. readiness says status=$R7STATUS foundation=$R7FND for [$PROMOTED]"
fi

# THE NEGATIVE, on the EXACT string the bug produced: a config carrying a
# truncated command must NOT be certified ready — not by status, and not by the
# `foundation` axis the filing gate and the board lock on.
brepo="$(new_mission_repo initialization t-scaffold)"
python3 - "$brepo/.git/lcars/config.json" "$DETECTED" <<'PY'
import json, sys
cfg, detected = sys.argv[1], sys.argv[2]
# Reproduce EXACTLY what the escape-blind reader produced: everything up to the
# first embedded quote, trailing backslash and all.
i = detected.find('"')
broken = detected[:i] + '\\' if i > 0 else detected
d = json.load(open(cfg))
d["testCommand"] = broken
json.dump(d, open(cfg, "w"), indent=2)
PY
BJ="$(rjson "$brepo")"
BSTATUS="$(rfield "$BJ" status)"; BFND="$(rfield "$BJ" foundation)"; BCMD="$(rfield "$BJ" testCommand)"
if bash -n -c "$BCMD" >/dev/null 2>&1; then
  bad "F7g. the negative fixture is not actually broken: [$BCMD]"
else
  ok "F7g. the negative fixture IS the shell syntax error the bug produced"
fi
if [ "$BSTATUS" != ready ]; then
  ok "F7h. readiness --json does NOT claim status ready for a command no shell can parse"
else
  bad "F7h. readiness still claims ready for [$BCMD] — the dishonesty is intact"
fi
if [ "$BFND" != ready ]; then
  ok "F7i. …and does NOT claim foundation ready — lcars file + the holodeck stay locked"
else
  bad "F7i. the foundation axis still reads ready for [$BCMD]"
fi

# ===========================================================================
# H. A GATE THAT DID NOT RUN NEVER CLAIMS IT PASSED
# ===========================================================================
# The post-commit gate returns 0 on several "do not fail this repo" arms, and
# that rc 0 used to flow straight into `ticket_postcommit_ok` ("verified green on
# the committed branch") and into the DURABLE test landscape. MEASURED on the
# salvage branch: a branch-less mission whose implementation never reached any
# commit emitted ticket_postcommit_ok and ticket_green.
pcg() { # repo ticket [env pairs...] -> PCRC / PCSKIP / PCKIND
  local r="$1" t="$2"; shift 2
  OUT="$( cd "$r" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
          bash "$SCRIPT" post-commit-gate-test --mission m-001 --ticket "$t" 2>&1 )"
  PCRC="$(printf '%s\n' "$OUT"  | sed -n 's/^PCRC=//p'  | tail -1)"
  PCSKIP="$(printf '%s\n' "$OUT" | sed -n 's/^PCSKIP=//p' | tail -1)"
  PCKIND="$(printf '%s\n' "$OUT" | sed -n 's/^PCKIND=//p' | tail -1)"
}

# H1. NO RUNNER — "we could not check".
repo="$(new_mission_repo initialization t-scaffold)"
pcg "$repo" t-scaffold LCARS_TEST_CMD=
if [ "$PCRC" = 0 ] && [ "$PCKIND" = no-runner ] && [ -n "$PCSKIP" ]; then
  ok "H1. a runner-less post-commit gate records a SKIP, not a pass"
else
  bad "H1. no-runner skip not recorded (rc=$PCRC kind=$PCKIND)"
fi

# H2. NO COMMITTED STATE — "there is nothing to check".
repo="$(new_mission_repo initialization t-scaffold)"
python3 - "$repo/.git/lcars/missions/m-001/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("branch",None)
json.dump(d,open(p,"w"),indent=2)
PY
pcg "$repo" t-scaffold LCARS_TEST_CMD=true
if [ "$PCRC" = 0 ] && [ "$PCKIND" = not-applicable ] && [ -n "$PCSKIP" ]; then
  ok "H2. a branch-less mission records a NOT-APPLICABLE skip, not a pass"
else
  bad "H2. branch-less skip not recorded (rc=$PCRC kind=$PCKIND)"
fi

# H3. THE SALVAGE'S KNOWN-BAD KINDING, FIXED. A FAILED `git worktree add` was
# kinded `not-applicable` — "nothing to check" — so a ticket whose code never
# lands could pass green AND earn a durable verified record. There IS a committed
# ref and there IS a runner: the CHECK ITSELF failed. That is an ERROR.
repo="$(new_mission_repo initialization t-scaffold)"
( cd "$repo" && git branch lcars/m-001 >/dev/null 2>&1 )
# A `git` that answers every read but REFUSES to cut a worktree — the shape a
# full disk / a stale worktree registration produces.
cat > "$TMPROOT/git-noworktree" <<SH
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = "worktree" ] && [ "\$a" = "add" ]; then
    echo "fatal: could not create work tree dir" >&2; exit 128
  fi
  prev="\$a"
done
exec "$(command -v git)" "\$@"
SH
chmod +x "$TMPROOT/git-noworktree"
pcg "$repo" t-scaffold LCARS_TEST_CMD=true LCARS_GIT_BIN="$TMPROOT/git-noworktree"
if [ "$PCRC" = 5 ] && [ "$PCKIND" = error ]; then
  ok "H3. a FAILED worktree cut is an ERROR (rc 5), never \"nothing to check\""
else
  bad "H3. a failed worktree cut still reads as a non-result (rc=$PCRC kind=$PCKIND)"
fi
if printf '%s' "$OUT" | grep -q 'COULD NOT CUT THE GATE WORKTREE'; then
  ok "H3b. …and it says so, naming what was NOT verified"
else
  bad "H3b. the error is not legible: $OUT"
fi

# ===========================================================================
# G. ZERO SPEND
# ===========================================================================
n="$(spends)"
if [ "$n" = 0 ]; then
  ok "G1. ZERO worker spend across the whole suite (counting shim saw $n spawns)"
else
  bad "G1. the suite spawned $n worker session(s) — REAL MONEY IF THE SHIM SLIPS"
fi

printf '\ninit-mission: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
