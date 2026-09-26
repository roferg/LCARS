#!/usr/bin/env bash
#
# tests/no-rigs.test.sh — the durable gate that keeps TEST RIGS out of the
# LCARS product repo.
#
# THE RULING (captain, 2026-09-25): "I don't want the test rigs checked into
# the LCARS repo at all. If they're useful to have, put them in lcars-dev."
#
# WHAT WAS ACTUALLY IN HERE when the ruling landed: 3,913 tracked files and
# ~109 MB under `tests/drives/` — 1,246 .json, 559 .txt, 474 .log against only
# 158 .sh and 155 .md. The bulk was RECORDED RUN OUTPUT that everyone believed
# was never committed. The rig SCRIPTS moved to lcars-dev's own
# `tests/drives/`; the recorded artefacts were UNTRACKED and left on disk; the
# handful of files that shipped suites actually source or exec moved to
# `tests/lib/` because they are shared EQUIPMENT, not one session's rig, and
# LCARS must stay clonable-and-testable (CLAUDE.md's golden rule).
#
# WHY A SUITE AND NOT JUST A .gitignore. A `.gitignore` line is advisory: it
# stops an accidental `git add`, and nothing at all stops `git add -f` or a
# path that a future ignore-rule edit un-ignores. This suite reads the REAL
# GIT INDEX and fails if a rig is tracked anywhere in it. It runs in ship-it's
# full-suite gate, so a re-add cannot reach `main` unnoticed. It reads the
# index with `ls-files -s -z`, not a plain listing, because core.quotePath
# C-quotes a non-ASCII path — `"tests/drives/caf\303\251.json"` — and a
# `^tests/drives/` scan of that listing silently misses it.
#
# IT IS A CLOSED INVENTORY, NOT A HEURISTIC. Nothing here guesses whether a
# path "looks like a rig" from its name or extension — a name-classifier is
# the one thing this project has watched be beaten by rewording, generation
# after generation. The gate knows what is ALLOWED and refuses the rest.
#
# WHAT THE SCOPE ACTUALLY IS, because an earlier version of this header
# promised more than the code delivered (and a doc that over-promises is
# exactly how the tests/lib/README.md defect happened). There are TWO
# different strengths here, on purpose:
#
#   * OVER THE WHOLE INDEX the gate holds exactly one opinion: a `drives`
#     path segment, at any depth, in any case, is refused — `drives/x`,
#     `Drives/x`, `web/tests/drives/x` and `tests/drives/x` alike, plus a
#     symlink named `drives`. (The first spelling of this gate matched the
#     literal, root-anchored pathspec `tests/drives`, so all of those walked
#     past it; the second was case-SENSITIVE on a case-INSENSITIVE
#     filesystem, so `Drives/` walked past it too.) It also refuses a root
#     `.gitmodules` that declares a submodule under `tests/` or with a
#     `drives` segment.
#   * UNDER `tests/` — and only there — the inventory is CLOSED. Every
#     tracked path must be one of: a top-level `*.test.sh` suite,
#     `tests/run.sh`, a path declared in `tests/lib/MANIFEST`, or a path
#     declared in `tests/fixtures/MANIFEST`. Everything else is refused by
#     default, so a rig at `tests/rigs/s999/`, `tests/lib/s999/` or
#     `tests/fixtures/drives-archive/` is refused without the gate having to
#     recognise the word "rig". Gitlinks (mode 160000) are refused here too:
#     a submodule is an unbounded tree hanging off one index entry.
#   * OUTSIDE `tests/`, apart from that one `drives` opinion, this gate is
#     SILENT. A rig tree at `web/rigs/`, `scratch/` or `skills/*/rig-runs/`
#     is NOT refused. That is a deliberate scope choice, not an oversight —
#     but it is a real limit and it is stated here rather than implied away.
#
# THE TWO MANIFESTS are the allow-lists, one per closed area:
# `tests/lib/MANIFEST` for the shared equipment and `tests/fixtures/MANIFEST`
# for the fixture data. A new file in either fails until somebody adds a row.
# Fixtures were originally left OPEN — one narrow deny-rule on the exec bit —
# and a fresh tester walked 120 real rig files through that door at mode 644
# while the gate printed the clean-tree tally. The closed half turned away
# every attack aimed at it, so the closed pattern now covers both.
#
# PATHS ARE NOT LINES. A path containing a newline is refused outright before
# any allow-list lookup, because `grep -F` reads each line of its pattern as
# a separate alternative and a two-line path therefore matches an allow-list
# holding only its second line.
#
# THE CONTROL (the reason this file can be trusted). A check that has only
# ever seen the clean state cannot detect its own breakage — the same class of
# false green the ORCHESTRATION.md "known-good control" rule exists to stop.
# So section 3 builds a THROWAWAY repo and drives the very same predicate RED
# once per hole, proving each refusal can fire and then clear; and it plants
# two LEGITIMATE files (a new suite, a new fixture) that must stay GREEN, so
# "everything is refused" cannot pass for a working gate.
#
#   bash tests/no-rigs.test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
# THE PREDICATE. One function, used against the real repo in section 1 and
# driven both ways by the control in section 3. If these ever diverge the
# control stops proving anything, so there is deliberately only one.
#
# Prints "<reason>\t<path>" for every tracked path the closed inventory
# REFUSES (nothing at all when clean). Exit status is NOT the signal —
# callers read the output — because `git ls-files` exits 0 whether or not it
# matched anything.
# ---------------------------------------------------------------------------

manifest_rows() { # repo-dir -> stdout: "<mode> <path> <status> <note...>" per declared entry
  local m="$1/tests/lib/MANIFEST"
  [ -f "$m" ] || return 0
  grep -v '^[[:space:]]*#' "$m" | grep -v '^[[:space:]]*$'
}

declared_equipment() { # repo-dir -> stdout: one declared tests/lib path per line
  manifest_rows "$1" | awk '{print $2}'
}

fixture_rows() { # repo-dir -> stdout: "<mode> <path>" per declared fixture
  local m="$1/tests/fixtures/MANIFEST"
  [ -f "$m" ] || return 0
  grep -v '^[[:space:]]*#' "$m" | grep -v '^[[:space:]]*$'
}

declared_fixtures() { # repo-dir -> stdout: "<mode> <path>" per declared fixture
  fixture_rows "$1" | awk '{print $1, $2}'
}

submodule_paths() { # repo-dir -> stdout: each `path = X` declared by the INDEX's .gitmodules
  git -C "$1" show ':.gitmodules' 2>/dev/null \
    | sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p'
}

refused_paths() { # repo-dir -> stdout: "<reason>\t<path>" per refused tracked path
  local repo="$1" allow fixallow rec mode p rest sm bad_sm
  allow="$(declared_equipment "$repo")"
  fixallow="$(declared_fixtures "$repo")"
  # -z: NUL-terminated and UNQUOTED, so a path with a quote/backslash/newline
  # in it cannot dodge the scan the way core.quotePath's C-quoting would let
  # a plain `ls-files` listing dodge a `[ -e ]`-style check.
  while IFS= read -r -d '' rec; do
    mode="${rec%% *}"                # "<mode> <sha> <stage>\t<path>"
    p="${rec#*$'\t'}"

    # RULE 0 — a path containing a NEWLINE is refused outright, before any
    # allow-list is consulted. `grep -F` treats every LINE of its pattern as
    # a SEPARATE alternative, so a two-line path
    # `tests/lib/s999rig<NL>tests/lib/cage.py` matches an allow-list that
    # contains only `tests/lib/cage.py` — the rig half is never looked at.
    # (A fresh tester tracked exactly that and the gate printed the
    # clean-tree tally.) This is the same family as the core.quotePath bug
    # this file already fixed: the read went to `-z` to get RAW paths, then
    # handed those raw paths straight to LINE-oriented matchers. Everything
    # downstream — `grep -qxF`, `grep -c .`, `grep "^reason\t"`, `cut -f1` —
    # assumes one refusal per line, so the escape hatch is closed here and
    # the path is reported with its newline rendered as a literal \n so the
    # refusal itself stays one line.
    case "$p" in
      *$'\n'*) printf 'newline-in-path\t%s\n' "${p//$'\n'/\\n}"; continue ;;
    esac

    # RULE 1 — a `drives` path segment anywhere, at any depth, in ANY CASE.
    # macOS is case-insensitive: `Drives/s999/x.sh` and `drives/s999/x.sh`
    # are THE SAME DIRECTORY, and the first spelling of this rule refused
    # only the second. One keystroke walked the whole corpus past it.
    case "/$p/" in
      */[Dd][Rr][Ii][Vv][Ee][Ss]/*) printf 'drives-dir\t%s\n' "$p"; continue ;;
    esac

    # RULE 1b — a root `.gitmodules` that DECLARES a submodule under tests/
    # (or one with a `drives` segment). A submodule hangs an unbounded tree
    # off a single index entry; the gitlink itself is refused by RULE 2b, and
    # this refuses the declaration too, so the intent is still named when the
    # two are staged apart. Read from the INDEX, because the index is what
    # this gate judges.
    if [ "$p" = .gitmodules ]; then
      bad_sm=""
      while IFS= read -r sm; do
        [ -n "$sm" ] || continue
        case "/$sm/" in */[Dd][Rr][Ii][Vv][Ee][Ss]/*) bad_sm="$sm" ;; esac
        case "$sm" in tests/*) bad_sm="$sm" ;; esac
      done <<SUBMODULES
$(submodule_paths "$repo")
SUBMODULES
      [ -n "$bad_sm" ] && printf 'gitmodules-declares-rig\t%s\n' "$p"
      continue
    fi

    # RULE 2 — outside tests/ this gate has no opinion (see the header: the
    # closed inventory is scoped to tests/, deliberately).
    case "$p" in tests/*) ;; *) continue ;; esac

    # RULE 2b — a GITLINK (mode 160000) under tests/. One index entry, an
    # unbounded working tree, and none of the rules below ever see a single
    # one of its files. It is not 100755, so the old fixtures rule waved it
    # through as well.
    if [ "$mode" = 160000 ]; then
      printf 'submodule\t%s\n' "$p"; continue
    fi

    # RULE 3 — the closed inventory under tests/.
    rest="${p#tests/}"
    case "$rest" in
      */*)            ;;                                  # nested: fall through
      run.sh|*.test.sh) continue ;;                       # a shipped suite / the runner
      *) printf 'undeclared-under-tests\t%s\n' "$p"; continue ;;
    esac
    case "$p" in
      tests/fixtures/*)
        # Fixtures are inert DATA, and this inventory is CLOSED — declared in
        # tests/fixtures/MANIFEST at a stated mode, or refused.
        #
        # It used to be an OPEN deny-list with exactly one refusal (mode
        # 100755), and that single narrow rule was the whole door: a fresh
        # tester copied 120 real rig files out of lcars-dev/tests/drives/
        # into tests/fixtures/drives-archive/, stripped the exec bits and
        # force-added them, and the gate printed `76 passed, 0 failed` — the
        # exact tally a clean tree prints. `bash tests/fixtures/s999-rig/
        # rig.sh` then ran fine, because a rig script at 644 runs perfectly,
        # and the recorded .json/.log artefacts that were the real bulk of
        # the original 109 MB are inert data an exec-bit rule can never
        # reach. The tests/lib/ half of this gate — a closed allow-list —
        # turned away every attack aimed at it, so that same pattern is now
        # applied here rather than a third one invented.
        #
        # The exec bit is still its own reason, checked first, because
        # "executable file among the fixtures" is a more useful thing to be
        # told than "undeclared".
        [ "$mode" = 100755 ] && { printf 'executable-fixture\t%s\n' "$p"; continue; }
        # Mode AND path, so a symlink (120000) planted at a declared path is
        # refused too. Safe against the RULE 0 hazard: a newline can only
        # reach this comparison inside $p, and RULE 0 already refused those.
        printf '%s\n' "$fixallow" | grep -qxF "$mode $p" && continue
        printf 'undeclared-fixture\t%s\n' "$p"; continue ;;
      tests/lib/*)
        printf '%s\n' "$allow" | grep -qxF "$p" && continue
        printf 'undeclared-equipment\t%s\n' "$p"; continue ;;
      *) printf 'undeclared-under-tests\t%s\n' "$p"; continue ;;
    esac
  done < <(git -C "$repo" ls-files -s -z)
}

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "FATAL: $REPO_ROOT is not a git checkout — this gate reads the git index" >&2; exit 1; }

echo "no-rigs — test rigs must not be tracked in the LCARS product repo"

# --- section 1: the real repo's index --------------------------------------
echo
echo "-- section 1: the LCARS index carries no rigs --"
if [ -f "$REPO_ROOT/tests/lib/MANIFEST" ]; then
  ok "1. tests/lib/MANIFEST exists (the equipment allow-list the gate reads)"
else
  bad "1. tests/lib/MANIFEST is MISSING — without it every tests/lib path is refused"
fi
if [ -f "$REPO_ROOT/tests/fixtures/MANIFEST" ]; then
  ok "1. tests/fixtures/MANIFEST exists (the fixture allow-list the gate reads)"
else
  bad "1. tests/fixtures/MANIFEST is MISSING — without it every tests/fixtures path is refused"
fi

listing="$(refused_paths "$REPO_ROOT")"
count="$(printf '%s' "$listing" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
  ok "1. the whole index is inside the closed inventory (0 refused paths)"
else
  bad "1. $count tracked path(s) refused — rigs belong in lcars-dev, artefacts belong untracked"
  printf '%s\n' "$listing" | head -20 | sed 's/^/       /'
  [ "$count" -gt 20 ] && printf '       ... and %d more\n' "$((count - 20))"
fi

# Each rule gets its own row, so a failure names the hole rather than a total.
for reason in newline-in-path drives-dir gitmodules-declares-rig submodule \
              undeclared-equipment undeclared-fixture undeclared-under-tests \
              executable-fixture; do
  n="$(printf '%s\n' "$listing" | grep -c "^$reason	" || true)"
  if [ "$n" -eq 0 ]; then
    ok "1. no tracked path refused as $reason"
  else
    bad "1. $n tracked path(s) refused as $reason"
    printf '%s\n' "$listing" | grep "^$reason	" | head -10 | sed 's/^/       /'
  fi
done

# --- section 2: the .gitignore rule ----------------------------------------
# Textual grep would pass on a commented-out line, so ASK GIT: is a path under
# tests/drives ignored? `git check-ignore -q` answers 0 = ignored.
#
# THE QUESTION THIS SECTION ASKS is "does a RULE cover this path". Whether
# something is TRACKED is section 1's question, and section 1 answers it.
# Conflating the two made this section lie in two different ways:
#
#   1. Without --no-index, check-ignore consults the index first and reports
#      an already-TRACKED path as "not ignored". True of git's behaviour,
#      false as a diagnosis — it printed ".gitignore is missing a
#      tests/drives/ rule" whenever a rig had been force-added, sending the
#      reader off to edit a .gitignore that was perfectly correct.
#   2. When `tests/drives` is a SYMLINK, git refuses to answer at all:
#      `fatal: pathspec '...' is beyond a symbolic link`, exit 128. A plain
#      `if git check-ignore -q` reads that refusal as "no", printing the very
#      same wrong advice for a completely different reason.
#
# So ask for THREE answers, not two, and never let "git could not tell me"
# masquerade as "there is no rule".
ignore_state() { # repo-dir path -> prints: ignored | not-ignored | unanswerable: <msg>
  local out rc
  out="$(git -C "$1" check-ignore --no-index -v -- "$2" 2>&1)"; rc=$?
  case "$rc" in
    0) printf 'ignored\n' ;;
    1) printf 'not-ignored\n' ;;
    *) printf 'unanswerable: %s\n' "$(printf '%s' "$out" | head -1)" ;;
  esac
}
echo
echo "-- section 2: .gitignore refuses an ACCIDENTAL add --"
for probe in tests/drives/s999/rig.sh tests/drives/s999/runs/out.json tests/drives/anything; do
  state="$(ignore_state "$REPO_ROOT" "$probe")"
  case "$state" in
    ignored)     ok  "2. a .gitignore rule covers $probe" ;;
    not-ignored) bad "2. no .gitignore rule covers $probe — add a tests/drives/ rule" ;;
    *)           bad "2. git could not answer for $probe ($state) — NOT a .gitignore problem; see section 1" ;;
  esac
done
# Control for section 2: the rule must not be so broad it swallows the
# equipment that STAYED, or a clone would be untestable.
for keep in tests/lib/cage.py tests/lib/MANIFEST tests/no-rigs.test.sh tests/run.sh; do
  state="$(ignore_state "$REPO_ROOT" "$keep")"
  case "$state" in
    not-ignored) ok  "2. CONTROL: $keep is still visible to git (rule is scoped, not greedy)" ;;
    ignored)     bad "2. CONTROL: the ignore rule wrongly swallows $keep" ;;
    *)           bad "2. CONTROL: git could not answer for $keep ($state)" ;;
  esac
done

# --- section 3: the control — prove the refusal can actually FIRE ----------
# A throwaway repo, so the real index is never touched. The SAME refused_paths
# predicate section 1 judges the real repo with is driven red, then green,
# once per hole — and then driven the other way with two LEGITIMATE files, so
# a gate that simply refuses everything cannot pass this section.
echo
echo "-- section 3: CONTROL — the gate goes RED on a planted rig, GREEN when it's gone --"
CTL="$(mktemp -d "${TMPDIR:-/tmp}/lcars-no-rigs-control.XXXXXX")"
# Section 5's decoy lives in the THROWAWAY repo, never in the repo this gate
# guards. It used to be written to $REPO_ROOT/tests/ and removed by this
# trap, which covers a normal exit, SIGINT and SIGTERM — but not SIGKILL,
# and a kill -9 left an un-ignored `.test.sh` sitting in the product repo
# that `git add -A` would commit and tests/run.sh would then execute. A gate
# does not get to write into the thing it is guarding.
DECOY="$CTL/tests/zz-no-rigs-control-decoy.test.sh"
cleanup() { [ -n "${CTL:-}" ] && rm -rf "$CTL"; }
trap cleanup EXIT

git -C "$CTL" init -q 2>/dev/null
git -C "$CTL" config user.email t@example.invalid
git -C "$CTL" config user.name t
# The control repo carries the SAME ignore rule and the SAME manifest the real
# repo has, so it also proves the rule is what forces the `-f` and that the
# allow-list is what the predicate reads.
cp "$REPO_ROOT/.gitignore" "$CTL/.gitignore" 2>/dev/null || printf 'tests/drives/\n' > "$CTL/.gitignore"
mkdir -p "$CTL/tests/lib" "$CTL/tests/fixtures"
cp "$REPO_ROOT/tests/lib/MANIFEST" "$CTL/tests/lib/MANIFEST"
printf '#!/usr/bin/env bash\necho suite\n' > "$CTL/tests/run.sh"
printf '#!/usr/bin/env bash\necho suite\n' > "$CTL/tests/example.test.sh"
printf '{"fixture":true}\n' > "$CTL/tests/fixtures/example.json"
# …and its own fixtures allow-list, declaring exactly those two files, so the
# control's baseline is legitimately green for the same reason the real
# repo's is: everything tracked is declared.
printf '100644 tests/fixtures/MANIFEST\n100644 tests/fixtures/example.json\n' \
  > "$CTL/tests/fixtures/MANIFEST"
git -C "$CTL" add -A >/dev/null 2>&1

# 3z. the control repo's BASELINE must be clean, or every RED below is
# meaningless — this is the known-good half of the control.
base="$(refused_paths "$CTL")"
basen="$(printf '%s' "$base" | grep -c . || true)"
if [ "$basen" -eq 0 ]; then
  ok "3z. CONTROL BASELINE: an unplanted repo (suite + run.sh + fixture + manifest) is GREEN"
else
  bad "3z. CONTROL BASELINE: the unplanted repo already refuses $basen path(s) — later REDs prove nothing"
  printf '%s\n' "$base" | sed 's/^/       /'
fi

verdict() { # repo-dir -> 0 clean, 1 refused paths present
  local n; n="$(refused_paths "$1" | grep -c . || true)"; [ "$n" -eq 0 ]
}

# 3a. the .gitignore half: a PLAIN add must not take a rig at all, which is
# what forces every plant below to use `-f`.
mkdir -p "$CTL/tests/drives/s999"
printf '#!/usr/bin/env bash\necho planted rig\n' > "$CTL/tests/drives/s999/plain.sh"
git -C "$CTL" add tests/drives >/dev/null 2>&1
if [ -z "$(git -C "$CTL" ls-files -- tests/drives)" ]; then
  ok "3a. a plain \`git add tests/drives\` adds nothing (the ignore rule holds)"
else
  bad "3a. a plain \`git add tests/drives\` tracked something — the ignore rule is not doing its job"
fi

# plant_red <label> <relpath> <expected-reason> [mode]
# Force-adds one file, requires the SAME predicate to refuse it FOR THE STATED
# REASON, then untracks it and requires the predicate to go clean again. The
# reason is asserted, not just the count: a rule that fired for the wrong
# reason would otherwise read as a pass.
plant_red() {
  local label="$1" rel="$2" want="$3" mode="${4:-644}" got reason
  mkdir -p "$CTL/$(dirname "$rel")"
  printf '#!/usr/bin/env bash\necho planted\n' > "$CTL/$rel"
  chmod "$mode" "$CTL/$rel"
  git -C "$CTL" add -f "$rel" >/dev/null 2>&1
  got="$(refused_paths "$CTL")"
  reason="$(printf '%s\n' "$got" | grep "	$rel\$" | cut -f1)"
  if [ "$reason" = "$want" ]; then
    ok "3. RED: $label -> refused as $want"
  else
    bad "3. RED: $label -> got '${reason:-<not refused at all>}', expected '$want'"
  fi
  git -C "$CTL" rm --cached -q "$rel" >/dev/null 2>&1
  if verdict "$CTL"; then
    ok "3. GREEN again after untracking $rel"
  else
    bad "3. still RED after untracking $rel — the gate is stuck red"
    refused_paths "$CTL" | sed 's/^/       /'
  fi
  if [ -f "$CTL/$rel" ]; then
    ok "3. and $rel is still on disk (untracking is not deleting)"
  else
    bad "3. untracking DELETED $rel from disk"
  fi
}

# Every spelling a fresh tester walked past the first version of this gate
# (tests/rigs/, tests/lib/, root drives/), the one it already caught
# (tests/drives/), the nested one nobody tried (web/tests/drives/), and the
# two shapes the bulk of the 109 MB actually took (a .sh rig and a recorded
# .json artefact). Each is asserted by REASON, not just "something failed".
plant_red "a rig at tests/drives/s999/ (the original shape)" tests/drives/s999/rig.sh   drives-dir             755
plant_red "a RECORDED .json under tests/drives/ (the bulk)"  tests/drives/s999/run.json drives-dir             644
plant_red "a rig at tests/rigs/s999/ (renamed directory)"    tests/rigs/s999/rig.sh     undeclared-under-tests 755
plant_red "a rig hidden BESIDE the equipment, tests/lib/"    tests/lib/s999/rig.sh      undeclared-equipment   755
plant_red "a rig at the repo ROOT, drives/s999/"             drives/s999/drive.sh       drives-dir             755
plant_red "a rig NESTED at web/tests/drives/s999/"           web/tests/drives/s999/x.sh drives-dir             755
plant_red "a recorded ARTEFACT, not a script"                tests/rigs/s999/run-1.json undeclared-under-tests 644
plant_red "an EXECUTABLE dropped among the inert fixtures"   tests/fixtures/s999/run.sh executable-fixture     755

# The four spellings a SECOND fresh tester walked past the closed-inventory
# version of this gate. Each one printed `76 passed, 0 failed` — the exact
# tally a clean tree prints — so each is asserted by REASON here.
#
# F1: the fixtures half was an open deny-list, so a rig script at 644 and a
# recorded artefact in a directory merely NAMED like drives both sailed in.
# Note `drives-archive` has no `drives` SEGMENT, so RULE 1 never sees it —
# it has to be the closed fixtures inventory that refuses these, and the
# asserted reason proves it is.
plant_red "a rig SCRIPT among the fixtures at 644 (it runs fine)"  tests/fixtures/s999-rig/rig.sh           undeclared-fixture 644
plant_red "a RECORDED rig artefact in tests/fixtures/drives-archive/" tests/fixtures/drives-archive/run-1.json undeclared-fixture 644
# F4: one keystroke. macOS is case-insensitive, so `Drives/` IS `drives/`.
plant_red "the root rig tree spelled Drives/ (case-insensitive FS)" Drives/s999/x.sh                        drives-dir         755
plant_red "…and spelled DRIVES/"                                    DRIVES/s999/y.sh                        drives-dir         755

# F2: a path with a NEWLINE in it. plant_red cannot express this — dirname,
# the mkdir and the `grep "\t$rel$"` lookup all assume one line per path,
# which is precisely the assumption being attacked — so it is spelled out.
nl_rel=$'tests/lib/s999rig\ntests/lib/cage.py'
nl_shown='tests/lib/s999rig\ntests/lib/cage.py'   # how a refusal must render it
mkdir -p "$CTL/$(dirname "$nl_rel")"
printf '#!/usr/bin/env bash\necho planted\n' > "$CTL/$nl_rel"
chmod 755 "$CTL/$nl_rel"
git -C "$CTL" add -f -- "$nl_rel" >/dev/null 2>&1
if [ -z "$(git -C "$CTL" ls-files -- "$nl_rel")" ]; then
  bad "3. SETUP: git would not track a newline path — the F2 rows below prove nothing"
else
  if [ "$(refused_paths "$CTL" | grep -F "	$nl_shown" | cut -f1)" = newline-in-path ]; then
    ok "3. RED: an executable tracked at a path containing a NEWLINE -> refused as newline-in-path"
  else
    bad "3. RED: a newline path was not refused — grep -F still reads it as two alternatives"
    refused_paths "$CTL" | sed 's/^/       /'
  fi
fi
# CONTROL for RULE 0: reproduce the primitive it guards, or the rule could be
# guarding nothing at all. `grep -F` really does match a two-line pattern
# when EITHER line is present…
if printf '%s\n' 'tests/lib/cage.py' | grep -qxF "$nl_rel"; then
  ok "3. CONTROL: grep -qxF DOES match a two-line path against a one-line allow-list (the hazard is real)"
else
  bad "3. CONTROL: could not reproduce the grep -F multi-line hazard — RULE 0 may be guarding nothing"
fi
# …and does NOT when neither line is, so the control discriminates.
if printf '%s\n' 'tests/lib/cage.py' | grep -qxF $'tests/lib/s999rig\ntests/lib/notdeclared.py'; then
  bad "3. CONTROL: grep -qxF matched a two-line path with NEITHER line declared — the control is broken"
else
  ok "3. CONTROL: and does NOT match when neither line is declared (the control discriminates)"
fi
git -C "$CTL" rm --cached -q -- "$nl_rel" >/dev/null 2>&1
rm -f "$CTL/$nl_rel"
if verdict "$CTL"; then
  ok "3. GREEN again after untracking the newline path"
else
  bad "3. still RED after untracking the newline path"
  refused_paths "$CTL" | sed 's/^/       /'
fi

# F3: a SUBMODULE. One index entry at mode 160000 carrying an unbounded tree,
# plus a root .gitmodules no rule used to inspect. `update-index --cacheinfo`
# makes the gitlink directly, so the control needs no network and no second
# repo.
sm_sha="$(printf 'not-a-real-commit' | git -C "$CTL" hash-object -w --stdin)"
git -C "$CTL" update-index --add --cacheinfo 160000,"$sm_sha",tests/fixtures/rigs >/dev/null 2>&1
if [ "$(git -C "$CTL" ls-files -s -- tests/fixtures/rigs | awk '{print $1}')" != 160000 ]; then
  bad "3. SETUP: the gitlink plant did not produce a mode-160000 entry — the F3 rows below prove nothing"
else
  if [ "$(refused_paths "$CTL" | grep "	tests/fixtures/rigs\$" | cut -f1)" = submodule ]; then
    ok "3. RED: a git SUBMODULE under tests/ (mode 160000) -> refused as submodule"
  else
    bad "3. RED: a mode-160000 gitlink under tests/ was not refused"
    refused_paths "$CTL" | sed 's/^/       /'
  fi
fi
printf '[submodule "tests/fixtures/rigs"]\n\tpath = tests/fixtures/rigs\n\turl = https://example.invalid/rigs.git\n' > "$CTL/.gitmodules"
git -C "$CTL" add -f .gitmodules >/dev/null 2>&1
if [ "$(refused_paths "$CTL" | grep "	.gitmodules\$" | cut -f1)" = gitmodules-declares-rig ]; then
  ok "3. RED: a .gitmodules declaring a submodule under tests/ -> refused as gitmodules-declares-rig"
else
  bad "3. RED: a .gitmodules declaring a rig submodule under tests/ was not refused"
fi
# COUNTER-CONTROL: an ordinary submodule outside tests/ is none of this
# gate's business (RULE 2's documented scope), so .gitmodules must go quiet
# again rather than becoming a blanket "no submodules ever".
git -C "$CTL" rm --cached -q tests/fixtures/rigs >/dev/null 2>&1
printf '[submodule "vendor/thing"]\n\tpath = vendor/thing\n\turl = https://example.invalid/thing.git\n' > "$CTL/.gitmodules"
git -C "$CTL" add -f .gitmodules >/dev/null 2>&1
if [ -z "$(refused_paths "$CTL" | grep "	.gitmodules\$")" ]; then
  ok "3. CONTROL: a .gitmodules declaring only vendor/thing is NOT refused (not a blanket no-submodules rule)"
else
  bad "3. CONTROL: an out-of-scope submodule declaration was refused — the rule is too broad"
fi
git -C "$CTL" rm --cached -q .gitmodules >/dev/null 2>&1; rm -f "$CTL/.gitmodules"
if verdict "$CTL"; then
  ok "3. GREEN again after untracking the submodule and its .gitmodules"
else
  bad "3. still RED after untracking the submodule"
  refused_paths "$CTL" | sed 's/^/       /'
fi

# A `drives` SYMLINK to a tree outside the repo: ONE index entry, mode 120000.
# The plants above left a real tests/drives DIRECTORY on disk (untracking is
# not deleting), and `ln -s x dir` would quietly make `dir/x` instead of the
# symlink this row means to test — so clear it first, and assert the plant
# took the shape intended before judging the gate on it.
rm -rf "$CTL/tests/drives"
ln -s "$CTL/tests/fixtures" "$CTL/tests/drives"
if [ ! -L "$CTL/tests/drives" ]; then
  bad "3. SETUP: the symlink plant did not produce a symlink — the row below would be meaningless"
else
  git -C "$CTL" add -f tests/drives >/dev/null 2>&1
  if [ "$(refused_paths "$CTL" | grep "	tests/drives\$" | cut -f1)" = drives-dir ]; then
    ok "3. RED: tests/drives as a SYMLINK to an outside tree -> refused as drives-dir"
  else
    bad "3. RED: a tests/drives SYMLINK was not refused"
    refused_paths "$CTL" | sed 's/^/       /'
  fi
  # CONTROL for section 2's three-way answer. This poisoned repo is the ONE
  # place where "git could not tell me" really happens, so it is the only
  # place the third branch can be proved reachable — without it, section 2's
  # unanswerable arm is dead code that has never run.
  case "$(ignore_state "$CTL" tests/drives/s999/rig.sh)" in
    unanswerable:*) ok "3. CONTROL: behind a symlink, ignore_state says 'unanswerable', NOT 'no rule'" ;;
    *)              bad "3. CONTROL: ignore_state returned '$(ignore_state "$CTL" tests/drives/s999/rig.sh)' behind a symlink — the misdiagnosis is back" ;;
  esac
fi
git -C "$CTL" rm --cached -q -r tests/drives >/dev/null 2>&1; rm -f "$CTL/tests/drives"
# The other two answers must be reachable too, or a function that only ever
# says one thing would satisfy every row above. With the symlink gone,
# tests/drives is an ordinary ignored directory again.
mkdir -p "$CTL/tests/drives/s999"; : > "$CTL/tests/drives/s999/rig.sh"
if [ "$(ignore_state "$CTL" tests/drives/s999/rig.sh)" = ignored ]; then
  ok "3. CONTROL: ignore_state says 'ignored' for a path a rule DOES cover"
else
  bad "3. CONTROL: ignore_state said '$(ignore_state "$CTL" tests/drives/s999/rig.sh)' for a covered path"
fi
if [ "$(ignore_state "$CTL" tests/lib/MANIFEST)" = not-ignored ]; then
  ok "3. CONTROL: ignore_state says 'not-ignored' for a file no rule covers"
else
  bad "3. CONTROL: ignore_state said '$(ignore_state "$CTL" tests/lib/MANIFEST)' for an uncovered file"
fi

# 3n. THE OTHER DIRECTION. Files that legitimately belong must get through —
# otherwise "it refuses the plants" is satisfied by refusing everything, and
# the gate would block the next real suite.
#
# A new SUITE needs no declaration: `tests/*.test.sh` is allowed by shape, so
# this is the pure not-refuse-everything row.
printf '#!/usr/bin/env bash\necho real suite\n' > "$CTL/tests/legitimate-new.test.sh"
git -C "$CTL" add -f tests/legitimate-new.test.sh >/dev/null 2>&1
if verdict "$CTL"; then
  ok "3n. CONTROL: a NEW tests/*.test.sh is still allowed with no declaration (not refuse-everything)"
else
  bad "3n. CONTROL: the gate refuses a legitimate new suite — it would block the next real suite"
  refused_paths "$CTL" | sed 's/^/       /'
fi
# A new FIXTURE now works the way new EQUIPMENT already did — refused until
# declared, allowed the moment it is. Round 1 asserted a new fixture was
# waved straight through, and that IS the hole F1 closes: the door has to be
# the manifest, not the file's extension or its mode. So the row is kept, but
# driven BOTH ways, which is what makes it a control rather than a wish.
#
# The name carries a second job: `notdrives` contains the string "drives"
# without being a `drives` SEGMENT, so it is the counter-control for the
# case-folded RULE 1 — if that pattern were over-broad this would come back
# as drives-dir instead.
mkdir -p "$CTL/tests/fixtures/notdrives/nested"
printf '{"real":"fixture"}\n' > "$CTL/tests/fixtures/notdrives/nested/data.json"
git -C "$CTL" add -f tests/fixtures/notdrives/nested/data.json >/dev/null 2>&1
if [ "$(refused_paths "$CTL" | grep "	tests/fixtures/notdrives/nested/data.json\$" | cut -f1)" = undeclared-fixture ]; then
  ok "3n. CONTROL: a new fixture is refused BEFORE it is declared (and as undeclared-fixture, NOT drives-dir)"
else
  bad "3n. CONTROL: a new undeclared fixture got the wrong verdict — got '$(refused_paths "$CTL" | grep "	tests/fixtures/notdrives/nested/data.json\$" | cut -f1)'"
fi
printf '100644 tests/fixtures/notdrives/nested/data.json\n' >> "$CTL/tests/fixtures/MANIFEST"
if verdict "$CTL"; then
  ok "3n. CONTROL: and ALLOWED once tests/fixtures/MANIFEST declares it (the door really is the manifest)"
else
  bad "3n. CONTROL: declaring the fixture did not allow it — the fixtures allow-list is not being read"
  refused_paths "$CTL" | sed 's/^/       /'
fi
# And the MODE is part of the declaration: the same declared path at 755 is
# still refused, so a declared row cannot be used to smuggle an executable.
chmod 755 "$CTL/tests/fixtures/notdrives/nested/data.json"
git -C "$CTL" add -f tests/fixtures/notdrives/nested/data.json >/dev/null 2>&1
if [ "$(refused_paths "$CTL" | grep "	tests/fixtures/notdrives/nested/data.json\$" | cut -f1)" = executable-fixture ]; then
  ok "3n. CONTROL: a DECLARED fixture flipped to 100755 is still refused (mode is part of the row)"
else
  bad "3n. CONTROL: a declared fixture at 100755 was allowed — the mode half of the row is not checked"
fi
chmod 644 "$CTL/tests/fixtures/notdrives/nested/data.json"
git -C "$CTL" add -f tests/fixtures/notdrives/nested/data.json >/dev/null 2>&1
# And a manifest addition must open the door it is supposed to open.
mkdir -p "$CTL/tests/lib"
printf 'echo new equipment\n' > "$CTL/tests/lib/newthing.sh"
git -C "$CTL" add -f tests/lib/newthing.sh >/dev/null 2>&1
if [ "$(refused_paths "$CTL" | grep "	tests/lib/newthing.sh\$" | cut -f1)" = undeclared-equipment ]; then
  ok "3n. CONTROL: new tests/lib equipment is refused BEFORE it is declared"
else
  bad "3n. CONTROL: new tests/lib equipment slipped in undeclared"
fi
printf '100644 tests/lib/newthing.sh doc control row\n' >> "$CTL/tests/lib/MANIFEST"
if verdict "$CTL"; then
  ok "3n. CONTROL: and ALLOWED once a MANIFEST row declares it (the door really is the manifest)"
else
  bad "3n. CONTROL: declaring it in the MANIFEST did not allow it — the allow-list is not being read"
  refused_paths "$CTL" | sed 's/^/       /'
fi

# --- section 4: the equipment that stayed is real and reachable ------------
# The move is only safe if the files the shipped suites source/exec are still
# in the product repo. This section is driven by tests/lib/MANIFEST, so the
# inventory is closed in BOTH directions: section 1 refuses a tracked file
# that no row declares, and section 4 refuses a row that no file backs. It is
# the counterweight that stops this gate being "solved" by deleting the test
# suite's own tools, and it checks each row's mode — the CLI stubs are EXEC'D
# by lcars-worker-guard (the .py equipment is run as `python3 <file>` and
# never needs the bit), so 100755 has to have survived the move.
echo
echo "-- section 4: every MANIFEST row is a real, tracked file at its declared mode --"
rows=0
while read -r m_mode m_path m_status m_note; do
  # `<<EOF $(manifest_rows …) EOF` feeds ONE EMPTY LINE when the command
  # substitution is empty (a MANIFEST that is missing, or all comments), and
  # the loop body then reported a phantom row: `rows=1`, a FAIL with a blank
  # path and `unknown status ''`. A missing manifest is section 1's finding
  # and it says so clearly; this section should report nothing at all.
  [ -n "$m_mode" ] || continue
  rows=$((rows + 1))
  why=""
  # The manifest is the allow-list for tests/lib/ and nothing else. A row
  # pointing elsewhere would read as a declaration without being one (nothing
  # outside tests/lib/ consults it), so refuse it rather than let it look
  # load-bearing.
  case "$m_path" in tests/lib/*) ;; *) why="outside tests/lib/ — this manifest declares nothing else" ;; esac
  [ -n "$why" ] || [ -f "$REPO_ROOT/$m_path" ] || why="not on disk"
  if [ -z "$why" ] && ! git -C "$REPO_ROOT" ls-files --error-unmatch "$m_path" >/dev/null 2>&1; then
    why="not tracked"
  fi
  if [ -z "$why" ]; then
    actual="$(git -C "$REPO_ROOT" ls-files -s -- "$m_path" | awk '{print $1}')"
    [ "$actual" = "$m_mode" ] || why="mode is '${actual:-?}', manifest says $m_mode"
  fi
  case "$m_status" in
    exercised|unused|doc) ;;
    *) why="${why:+$why; }unknown status '$m_status'" ;;
  esac
  if [ -z "$why" ]; then
    ok "4. $m_path — on disk, tracked, $m_mode, $m_status"
  else
    bad "4. $m_path — $why"
  fi
done <<EOF
$(manifest_rows "$REPO_ROOT")
EOF
if [ "$rows" -ge 10 ]; then
  ok "4. the manifest actually has rows to check ($rows)"
else
  bad "4. the manifest parsed to only $rows row(s) — the section above proves nothing"
fi
# CONTROL for section 4: the same three checks must FAIL on a path that is
# not there, or their passes above mean nothing.
ghost=tests/lib/zz-not-a-real-file
if [ -f "$REPO_ROOT/$ghost" ] || git -C "$REPO_ROOT" ls-files --error-unmatch "$ghost" >/dev/null 2>&1; then
  bad "4. CONTROL: the known-absent probe $ghost exists — pick another probe"
else
  ok "4. CONTROL: the on-disk/tracked checks DO fail for a path that isn't there"
fi
# CONTROL for the phantom row: the very same heredoc idiom, pointed at a repo
# with no MANIFEST at all, must yield ZERO iterations — not one blank one.
phantom=0
while read -r z_mode z_rest; do
  [ -n "$z_mode" ] || continue
  phantom=$((phantom + 1))
done <<EOF
$(manifest_rows "$CTL/definitely-not-a-repo")
EOF
if [ "$phantom" -eq 0 ]; then
  ok "4. CONTROL: an ABSENT manifest yields 0 rows, not one blank phantom row"
else
  bad "4. CONTROL: an absent manifest still yields $phantom phantom row(s)"
fi

# --- section 4b: the fixtures manifest is backed both ways ----------------
# Same counterweight as section 4, for the other closed area: section 1
# refuses a tracked fixture that no row declares, and this refuses a row that
# no file backs — so the inventory cannot be "solved" by deleting fixtures
# and leaving their declarations behind. It is summarised rather than printed
# per row, because this is a 70-odd-file data inventory, not a dozen pieces
# of executable equipment.
echo
echo "-- section 4b: every tests/fixtures/MANIFEST row is a real, tracked file at its declared mode --"
fx_rows=0; fx_bad=""
while read -r f_mode f_path f_rest; do
  [ -n "$f_mode" ] || continue
  fx_rows=$((fx_rows + 1))
  case "$f_path" in tests/fixtures/*) ;; *) fx_bad="$fx_bad
  $f_path — outside tests/fixtures/ — this manifest declares nothing else"; continue ;; esac
  if [ ! -f "$REPO_ROOT/$f_path" ]; then
    fx_bad="$fx_bad
  $f_path — not on disk"; continue
  fi
  f_actual="$(git -C "$REPO_ROOT" ls-files -s -- "$f_path" | awk '{print $1}')"
  if [ -z "$f_actual" ]; then
    fx_bad="$fx_bad
  $f_path — not tracked"
  elif [ "$f_actual" != "$f_mode" ]; then
    fx_bad="$fx_bad
  $f_path — mode is '$f_actual', manifest says $f_mode"
  fi
done <<EOF
$(fixture_rows "$REPO_ROOT")
EOF
if [ -z "$fx_bad" ]; then
  ok "4b. all $fx_rows fixture row(s) are on disk, tracked, and at their declared mode"
else
  bad "4b. some fixture rows are not backed by a real tracked file:$fx_bad"
fi
if [ "$fx_rows" -ge 10 ]; then
  ok "4b. the fixtures manifest actually has rows to check ($fx_rows)"
else
  bad "4b. the fixtures manifest parsed to only $fx_rows row(s) — the check above proves nothing"
fi
# CONTROL: the same three checks must FAIL for a row nothing backs.
fx_ghost=tests/fixtures/zz-not-a-real-fixture.json
if [ -f "$REPO_ROOT/$fx_ghost" ] || git -C "$REPO_ROOT" ls-files --error-unmatch "$fx_ghost" >/dev/null 2>&1; then
  bad "4b. CONTROL: the known-absent probe $fx_ghost exists — pick another probe"
else
  ok "4b. CONTROL: the on-disk/tracked checks DO fail for a fixture row that isn't there"
fi
# CONTROL: the manifest must declare ITSELF, or it is outside its own
# inventory and section 1 would refuse it.
if fixture_rows "$REPO_ROOT" | grep -qxF '100644 tests/fixtures/MANIFEST'; then
  ok "4b. CONTROL: the fixtures manifest declares itself (it is inside its own closed inventory)"
else
  bad "4b. CONTROL: the fixtures manifest does not declare itself"
fi

# --- section 5: no shipped suite still reaches into tests/drives -----------
# Comments are fine (provenance breadcrumbs). An executable reference is not:
# it would be a dangling dependency the moment someone clones.
echo
echo "-- section 5: no shipped suite EXECUTES anything under tests/drives --"
# EXEMPT BY NAME, never by pattern — a pattern wide enough to hide these
# would hide the next real offender too:
#   * this file, which necessarily says "tests/drives" on nearly every line;
#   * tests/claim-check.test.sh:337, whose REPRO points at a path that was
#     never tracked and is not on disk. Its 5a row has failed for that reason
#     since before this move and is deliberately left exactly as it was.
#
# It takes a ROOT so the control below can plant its decoy in the throwaway
# repo. It used to write the decoy into $REPO_ROOT/tests/ and rely on an EXIT
# trap to remove it — fine for a normal exit, SIGINT or SIGTERM, but a
# SIGKILL left an un-ignored `.test.sh` in the product repo that `git add -A`
# would commit and tests/run.sh would then execute. The exemptions are
# matched on FILENAME, so they work in either root.
scan_suites() { # root -> non-comment references to tests/drives in its suites
  grep -n 'tests/drives\|"\$DIR"/drives\|/drives/' "${1:-$REPO_ROOT}"/tests/*.test.sh 2>/dev/null \
    | grep -v ':[0-9]*:[[:space:]]*#' \
    | grep -v '/no-rigs\.test\.sh:' \
    | grep -v '/claim-check\.test\.sh:'
}
live="$(scan_suites "$REPO_ROOT" | grep -c . || true)"
if [ "$live" -eq 0 ]; then
  ok "5. no non-comment tests/drives reference left in tests/*.test.sh (this file + claim-check's REPRO exempted by name)"
else
  bad "5. $live non-comment tests/drives reference(s) remain in tests/*.test.sh"
  scan_suites "$REPO_ROOT" | sed 's/^/       /'
fi
# CONTROL for section 5: the scan must actually see an executable reference
# when one exists, or "0 remaining" means nothing. Plant one in a throwaway
# suite file — inside the CONTROL repo, never inside the repo being guarded —
# and require the very same grep to find it there.
printf '#!/usr/bin/env bash\nCAGE="$REPO_ROOT/tests/drives/s197/cage.py"\n' > "$DECOY"
decoyn="$(scan_suites "$CTL" | grep -c 'zz-no-rigs-control-decoy' || true)"
rm -f "$DECOY"
if [ "$decoyn" -ge 1 ]; then
  ok "5. CONTROL: the scan DOES catch a planted executable reference (proved red, then removed)"
else
  bad "5. CONTROL: the scan missed a planted executable reference — its 0 above proves nothing"
fi
# …and the decoy was never written into the guarded repo, not even briefly.
if [ -e "$REPO_ROOT/tests/zz-no-rigs-control-decoy.test.sh" ]; then
  bad "5. CONTROL: the decoy is in the PRODUCT repo — this gate must not write into what it guards"
else
  ok "5. CONTROL: the decoy lives in the throwaway repo; the product repo was never written to"
fi

# --- section 6: the manifest's `status` column must be TRUE ----------------
# tests/lib/README.md used to state a flat rule — "everything here is sourced
# or exec'd by a shipped suite" — that three of its own files did not meet
# (the claude halves of the holodeck and deploy-watcher shim pairs, and the
# shims' README). Nothing checked the claim, so it drifted. Now each row says
# `exercised` or `unused` and this section holds it to it, in both
# directions: an `exercised` row that no suite names is a lie, and an
# `unused` row that a suite DOES name is a stale label.
#
# The match is on the declared path with its `tests/` prefix dropped, because
# suites reach equipment both ways — `"$REPO_ROOT/tests/lib/cage.py"` and
# `"$DIR/lib/stdin_guard.py"` (harness.test.sh:149) are both real spellings.
# This file is exempt BY NAME: it necessarily names every declared path.
echo
echo "-- section 6: the MANIFEST's exercised/unused labels match the shipped suites --"
names_it() { # tests/lib/<rest> -> 0 if some suite (not this one) names it
  grep -lF "lib/${1#tests/lib/}" "$REPO_ROOT"/tests/*.test.sh 2>/dev/null \
    | grep -v '/no-rigs\.test\.sh$' | grep -q .
}
n_ex=0; n_un=0
while read -r m_mode m_path m_status m_note; do
  case "$m_status" in
    exercised)
      n_ex=$((n_ex + 1))
      if names_it "$m_path"; then
        ok "6. $m_path is labelled exercised and a suite DOES name it"
      else
        bad "6. $m_path is labelled exercised but NO suite names it — move it out or relabel it unused"
      fi ;;
    unused)
      n_un=$((n_un + 1))
      if names_it "$m_path"; then
        bad "6. $m_path is labelled unused but a suite DOES name it — relabel it exercised"
      else
        ok "6. $m_path is labelled unused and no suite names it (a declared, deliberate keep)"
      fi ;;
  esac
done <<EOF
$(manifest_rows "$REPO_ROOT")
EOF
# CONTROL: the scan is proved BOTH ways only if both kinds of row exist. If
# every row were `doc`, the loop above would print nothing and still "pass".
if [ "$n_ex" -ge 1 ] && [ "$n_un" -ge 1 ]; then
  ok "6. CONTROL: the scan was driven both ways ($n_ex exercised must hit, $n_un unused must miss)"
else
  bad "6. CONTROL: only one kind of row exists ($n_ex exercised / $n_un unused) — the scan is untested in one direction"
fi

echo
printf 'no-rigs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
