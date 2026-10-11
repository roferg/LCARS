#!/usr/bin/env bash
#
# tests/live-check.test.sh — the LIVE-CHECK CHECKLISTS contract
# (skill source: skills/lcars-run/live-check/{README,cli,web,workflow}.md).
#
# WHAT IS UNDER TEST, AND WHY IT IS A CONTRACT AND NOT A GREP. Over the weekend
# of 26–29 Sep 2026 Number One filed 0 of 31 bugs; all 31 came from live checks
# a model did BY HAND. The 16 Number One misses were every one a REACH error —
# no screen, nothing seeded, a stub that made the seam untestable — never a
# judgement error. These checklists are that hand-work written down.
#
# THEY HAVE TWO READERS, and that is the whole reason for this suite:
#   • the buddy (a session WITH a shell) follows the PROSE;
#   • the rebuilt Number One (S239, a fenced worker with NO shell) lifts each
#     item as a DECLARED STEP the harness executes.
# So every numbered item must carry BOTH forms, and they must agree. A checklist
# whose prose and template drift is a checklist where one of its two readers is
# quietly checking something else. This suite measures, per item:
#   1. a `**Evidence:**` line and a `**DEFECT:**` line in the prose;
#   2. exactly one fenced `run:` / `workflow:` / `read:` template whose body is
#      valid JSON carrying an `expect` object and an `evidence` path;
#   3. that the template's `evidence` path is the one the prose names (lockstep);
#   4. that the path is numbered with the item's own number.
# Plus: the items the weekend proved load-bearing are present BY NAME.
#
# It reads the INSTALLED files, because the installed copy is what a session
# actually opens — and it carries its own empty-dir control so a false green
# (the suite passing against an absent file) cannot happen.
#
# Usage: bash tests/live-check.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
LCDIR="${LCARS_SKILLS_DEST:-$HOME/.claude/skills}/lcars-run/live-check"

pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# has <file> <extended-regex> — case-insensitive presence, file operand always
# given so grep never reads this suite's inherited stdin (S208).
has() { grep -qiE "$2" "$1" 2>/dev/null; }

echo
echo "=== lcars-run live-check: the checklist contract ========================"
echo

# ==========================================================================
# 1. the files are installed
# ==========================================================================
echo "-- 1. installed --"
for f in README.md cli.md web.md workflow.md; do
  check "$f is installed at $LCDIR/$f" "[ -f '$LCDIR/$f' ]"
done

# ==========================================================================
# 2. the dual-form contract, item by item
# ==========================================================================
echo "-- 2. every item carries BOTH forms --"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
CONTRACT="$SCRATCH/contract.py"
cat >"$CONTRACT" <<'PY'
import json, re, sys

KINDS = ("run", "workflow", "read")

def items(text):
    """Split a checklist into its numbered items: ### <N>. <title>."""
    out = []
    cur = None
    for line in text.splitlines():
        m = re.match(r'^###\s+(\d+)\.\s+(.*)$', line)
        if m:
            cur = {"n": int(m.group(1)), "title": m.group(2).strip(), "body": []}
            out.append(cur)
        elif cur is not None:
            cur["body"].append(line)
    for it in out:
        it["body"] = "\n".join(it["body"])
    return out

def templates(body):
    """Every fenced run:/workflow:/read: block in an item body, as (kind, json)."""
    found = []
    lines = body.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r'^```(run|workflow|read):\s*(.*)$', lines[i])
        if not m:
            i += 1
            continue
        kind, inline = m.group(1), m.group(2)
        buf = []
        i += 1
        while i < len(lines) and not lines[i].startswith("```"):
            buf.append(lines[i])
            i += 1
        i += 1
        raw = inline if inline.strip() else "\n".join(buf)
        try:
            obj = json.loads(raw)
        except Exception as e:
            obj = {"__parse_error__": str(e)}
        found.append((kind, obj))
    return found

problems = []
counts = {}
for path in sys.argv[1:]:
    name = path.rsplit("/", 1)[-1]
    try:
        text = open(path).read()
    except Exception as e:
        problems.append("%s: unreadable (%s)" % (name, e))
        continue
    its = items(text)
    counts[name] = len(its)
    if not its:
        problems.append("%s: no numbered `### N.` items at all" % name)
        continue
    for k, it in enumerate(its, start=1):
        tag = "%s item %d" % (name, it["n"])
        if it["n"] != k:
            problems.append("%s: numbering is not contiguous (expected %d)" % (tag, k))
        body = it["body"]
        ev = re.search(r'\*\*Evidence:\*\*\s*`([^`]+)`', body)
        if not ev:
            problems.append("%s: no **Evidence:** `<path>` line in the prose" % tag)
        if not re.search(r'\*\*DEFECT:\*\*', body):
            problems.append("%s: no **DEFECT:** line in the prose" % tag)
        tpls = templates(body)
        if len(tpls) != 1:
            problems.append("%s: %d fenced step templates, expected exactly 1"
                            % (tag, len(tpls)))
            continue
        kind, obj = tpls[0]
        if "__parse_error__" in obj:
            problems.append("%s: the %s: template is not valid JSON (%s)"
                            % (tag, kind, obj["__parse_error__"]))
            continue
        if not isinstance(obj.get("expect"), dict):
            problems.append("%s: the %s: template has no `expect` object" % (tag, kind))
        tev = obj.get("evidence")
        if not isinstance(tev, str) or not tev:
            problems.append("%s: the %s: template has no `evidence` path" % (tag, kind))
        else:
            if not re.match(r'^live-check/%02d-' % it["n"], tev):
                problems.append("%s: template evidence `%s` is not numbered live-check/%02d-*"
                                % (tag, tev, it["n"]))
            if ev and ev.group(1) != tev:
                problems.append("%s: PROSE and TEMPLATE disagree on the evidence path "
                                "(prose `%s` vs template `%s`)" % (tag, ev.group(1), tev))
        if kind == "run":
            argv = obj.get("argv")
            if not isinstance(argv, list) or not argv:
                problems.append("%s: the run: template has no argv list" % tag)
            elif not re.match(r'^<.+>$', str(argv[0])):
                problems.append("%s: run: argv[0] `%s` is not a <placeholder> for the "
                                "product's own name" % (tag, argv[0]))
        if kind == "workflow" and not obj.get("file"):
            problems.append("%s: the workflow: template has no `file`" % tag)
        if kind == "read" and not obj.get("path"):
            problems.append("%s: the read: template has no `path`" % tag)

for p in problems:
    print("PROBLEM: %s" % p)
print("ITEMS: %s" % json.dumps(counts, sort_keys=True))
sys.exit(1 if problems else 0)
PY

CONTRACT_OUT="$SCRATCH/contract.out"
python3 "$CONTRACT" "$LCDIR/cli.md" "$LCDIR/web.md" "$LCDIR/workflow.md" \
  >"$CONTRACT_OUT" 2>&1
crc=$?
sed -n 's/^PROBLEM: /    /p' "$CONTRACT_OUT" | head -40
check "every numbered item carries prose (Evidence + DEFECT) AND one valid fenced template, in lockstep" \
  "[ $crc -eq 0 ]"
sed -n 's/^ITEMS: /  item counts: /p' "$CONTRACT_OUT"
check "each checklist has at least four items" \
  "python3 -c 'import json,sys,re;t=open(sys.argv[1]).read();c=json.loads(re.search(r\"ITEMS: (.*)\",t).group(1));sys.exit(0 if c and all(v>=4 for v in c.values()) else 1)' '$CONTRACT_OUT'"

# ==========================================================================
# 3. the items the weekend proved load-bearing, BY NAME
# ==========================================================================
# Every one of these is a check that found real bugs on 26–29 Sep. A checklist
# missing one has a hole exactly the shape of the bug it would have caught.
echo "-- 3. the named items --"
check "cli.md: run \`--help\` and treat a missing subcommand as a defect" \
  "grep -qF -- '--help' '$LCDIR/cli.md'"
check "cli.md: bad input" \
  "has '$LCDIR/cli.md' 'bad input|invalid input|garbage'"
check "cli.md: TWO ACTORS — two HOMEs" \
  "has '$LCDIR/cli.md' 'two actors' && grep -c 'HOME' '$LCDIR/cli.md' | grep -qvx 0"
check "cli.md: make coinciding identities DIFFER (owner != login, draft name != title)" \
  "has '$LCDIR/cli.md' 'identities' && has '$LCDIR/cli.md' 'owner.*login' && has '$LCDIR/cli.md' 'name.*title'"
check "cli.md: FOLLOW THE DATA END TO END" \
  "has '$LCDIR/cli.md' 'end to end'"
check "cli.md: check the HOST of every outbound call" \
  "has '$LCDIR/cli.md' 'host of every outbound call'"
check "workflow.md: check the HOST of every outbound call too" \
  "has '$LCDIR/workflow.md' 'host of every outbound call'"
check "web.md: the 400 px IFRAME recipe (headless Chrome will not lay out below 500 px)" \
  "has '$LCDIR/web.md' '400 ?px' && has '$LCDIR/web.md' 'iframe' && has '$LCDIR/web.md' '500 ?px'"
check "web.md: READ THE DEPLOYED ARTIFACT, not \"deploy succeeded\"" \
  "has '$LCDIR/web.md' 'deploy succeeded'"
check "workflow.md: read the published artifact, not \"deploy succeeded\"" \
  "has '$LCDIR/workflow.md' 'deploy succeeded'"
check "workflow.md: run it EXACTLY as CI does (the real entrypoint)" \
  "has '$LCDIR/workflow.md' 'exactly as|the real entrypoint'"
check "workflow.md: names \`autopilot.sh workflow-run\` as the runner" \
  "grep -qF 'workflow-run' '$LCDIR/workflow.md'"
check "workflow.md: names the env Actions always sets, all four" \
  "( for v in GITHUB_SERVER_URL GITHUB_REPOSITORY_OWNER GITHUB_EVENT_PATH GITHUB_REPOSITORY; do grep -qF \"\$v\" '$LCDIR/workflow.md' || exit 1; done )"
check "workflow.md: a module run as a FILE is the named acceptance case" \
  "has '$LCDIR/workflow.md' 'python3 -m |as a module'"
for f in cli web workflow; do
  check "$f.md: RE-VERIFY after every fix round with DIFFERENT data" \
    "has '$LCDIR/$f.md' 're-verify' && has '$LCDIR/$f.md' 'different data'"
done
check "all three: the check runs from a DETACHED worktree with a throwaway HOME" \
  "( for f in cli web workflow; do has \"$LCDIR/\$f.md\" 'detached|throwaway' || exit 1; done )"

# ==========================================================================
# 3a. THE ORPHANED LABEL — the hole a live tester found by LOOKING
# ==========================================================================
# S234 round 1, defect 1. The fixture page put `class="host"` on the three
# `<td>` cells and NOT on the `<th>Host</th>` header, and the stylesheet hid
# `.host` below 500 px. At phone width every Host CELL vanished and the Host
# HEADER stayed, over an empty column with the row borders stopping halfway
# across — and ALL SIX of web item 3's DEFECT bullets answered "no": no
# horizontal scroll, the column DID collapse, no text under 12 px, the media
# query was not keyed below 400 px, no controls to overlap, and the spec never
# said the host must be readable. A reader ticking those six bullets records
# PASS with a visibly broken page on the screen. Only the instruction to LOOK
# at the shot caught it. So the case is now a bullet of its own, in BOTH forms.
echo "-- 3a. the orphaned label (a header that outlives what it describes) --"
check "web.md item 3: a header/label/caption that STAYS while the media query hides what it describes is a DEFECT" \
  "has '$LCDIR/web.md' 'header, label, caption' && has '$LCDIR/web.md' 'hides the thing it describes'"
check "web.md item 3: the bullet says WHAT TO COMPARE WITH WHAT (a performable check, not a warning)" \
  "has '$LCDIR/web.md' 'every (heading|header).*against'"
check "web.md item 3's TEMPLATE carries the matching expect key (the two readers stay in lockstep)" \
  "grep -qF 'labelSurvivesItsValue' '$LCDIR/web.md'"

# ==========================================================================
# 3b. THE EVIDENCE DIR IS FLAT — no two checklists may claim one filename
# ==========================================================================
# S234 round 1, defect 2. web item 7 and workflow item 7 BOTH named
# `live-check/07-reverify-r2.txt`, and the evidence dir is one flat directory
# per mission. A milestone that runs both checklists — the common case — had
# the second silently overwrite the first: exactly the untraceable evidence
# README.md forbids ("an evidence file nobody can trace back to an item is not
# evidence"). This asserts the WHOLE SET is unique, so a future item cannot
# reintroduce it, and the same pass audits every fenced template for a
# product-specific flag baked in (defect 6).
echo "-- 3b. evidence paths unique / no baked-in product flags --"
AUDIT="$SCRATCH/audit.py"
cat >"$AUDIT" <<'PY'
import json, os, re, sys

# Flags a template may carry: only ones that belong to a THIRD-PARTY tool the
# item names itself (headless Chrome), plus `--help`, which is the subject of
# the item that runs it. Anything else is a flag of the PRODUCT UNDER TEST, and
# the product may not have it: a prose reader adapts, a fenced no-shell reader
# cannot, and the two readers are supposed to be equally runnable.
TOOL_FLAGS = ("--headless", "--disable-gpu", "--no-sandbox", "--help")
TOOL_PREFIXES = ("--window-size=", "--screenshot=", "--user-data-dir=",
                 "--virtual-time-budget=", "--hide-scrollbars")

def items(text):
    out, cur = [], None
    for line in text.splitlines():
        m = re.match(r'^###\s+(\d+)\.', line)
        if m:
            cur = {"n": int(m.group(1)), "body": []}
            out.append(cur)
        elif cur is not None:
            cur["body"].append(line)
    for it in out:
        it["body"] = "\n".join(it["body"])
    return out

def tpl(body):
    m = re.search(r'^```(run|workflow|read):[ \t]*\n(.*?)^```', body, re.S | re.M)
    if not m:
        return (None, None)
    try:
        return (m.group(1), json.loads(m.group(2)))
    except Exception:
        return (m.group(1), None)

owner = {}
for path in sys.argv[1:]:
    name = os.path.basename(path)
    try:
        text = open(path).read()
    except Exception as e:
        print("UNREADABLE: %s (%s)" % (name, e))
        continue
    # every evidence path the PROSE names, plus every one a TEMPLATE declares
    paths = set(re.findall(r'`(live-check/[^`]+)`', text))
    for it in items(text):
        kind, obj = tpl(it["body"])
        if isinstance(obj, dict) and isinstance(obj.get("evidence"), str):
            paths.add(obj["evidence"])
        if kind == "run" and isinstance(obj, dict):
            for a in (obj.get("argv") or []):
                a = str(a)
                if not a.startswith("--"):
                    continue
                if a in TOOL_FLAGS or any(a.startswith(p) for p in TOOL_PREFIXES):
                    continue
                print("FLAG: %s item %d bakes in the product-specific flag %r. "
                      "A prose reader adapts; a fenced no-shell reader cannot. "
                      "Use a <placeholder> the product's own argv shape fills."
                      % (name, it["n"], a))
    for p in paths:
        owner.setdefault(p, set()).add(name)

for p, fs in sorted(owner.items()):
    if len(fs) > 1:
        print("DUP: %s is claimed by %s — the mission's evidence dir is FLAT, so "
              "the second checklist silently overwrites the first."
              % (p, ", ".join(sorted(fs))))
print("PATHS: %d" % len(owner))
PY
AUDIT_OUT="$SCRATCH/audit.out"
python3 "$AUDIT" "$LCDIR/cli.md" "$LCDIR/web.md" "$LCDIR/workflow.md" \
  >"$AUDIT_OUT" 2>&1
grep -E '^(DUP|FLAG|UNREADABLE):' "$AUDIT_OUT" | sed 's/^/    /' | head -20
sed -n 's/^PATHS: /  distinct evidence paths: /p' "$AUDIT_OUT"
check "no evidence path is claimed by TWO checklists (the dir is flat — the second would overwrite the first)" \
  "! grep -q '^DUP:' '$AUDIT_OUT'"
check "no fenced template bakes in a flag of the PRODUCT (both readers must be equally runnable)" \
  "! grep -q '^FLAG:' '$AUDIT_OUT'"
check "every re-verify item namespaces its evidence by checklist, so two of them cannot collide" \
  "( for f in cli web workflow; do grep -qE 'live-check/[0-9]{2}-reverify-'\"\$f\"'-r' \"$LCDIR/\$f.md\" || exit 1; done )"
check "README states the unique-across-checklists rule for evidence filenames" \
  "has '$LCDIR/README.md' 'two checklists|across the checklists|never claim(ed)? by two'"

# ==========================================================================
# 3c. THE STYLE EXEMPLAR MUST BE ONE THE VALIDATOR ACCEPTS
# ==========================================================================
# S234 round 1, defect 3. The round told testers to match
# `canvas-weekend-2026-09-26/evidence/filed-prds/bug-020-1.md` line for line.
# `file-bug` REFUSES that file on three counts (no `Out of Scope`, no
# `**Seam:**`, and an AC #1 reading `Observed (real code, no stubs on the
# contract):` rather than `Observed live:`) — it predates the template. The
# validator is right; the POINTER was wrong. No checklist may send a tester at
# an exemplar the round's own gate rejects.
echo "-- 3c. the style exemplar --"
for f in README cli web workflow; do
  check "$f.md does NOT point at the archive PRD \`file-bug\` refuses" \
    "! grep -qF 'bug-020-1' '$LCDIR/$f.md'"
done

# ==========================================================================
# 4. README — who reads these, and the evidence conventions
# ==========================================================================
echo "-- 4. README --"
R="$LCDIR/README.md"
check "README names BOTH readers (the autopilot/buddy and Number One)" \
  "has '$R' 'buddy|autopilot' && has '$R' 'number one'"
# S261 — THIS ROW USED TO READ: "README says Number One has NO shell". The
# captain amended that S168 clause on 2026-10-08 (19:33 MDT); the reviewer now
# has a real shell inside a disposable detached worktree. What the row is FOR is
# unchanged — the README must say HOW Number One works these items, so that
# whoever edits a checklist knows who is going to follow it.
check "README says Number One has a shell in a disposable copy, and may also declare a step" \
  "has '$R' 'real shell inside a disposable' && has '$R' 'declare'"
check "README no longer claims it has no shell" \
  "! has '$R' 'no shell'"
check "README documents all three template kinds" \
  "( for k in 'run:' 'workflow:' 'read:'; do grep -qF \"\$k\" '$R' || exit 1; done )"
check "README documents the evidence dir under the mission" \
  "grep -qF '.git/lcars/missions' '$R' && grep -qF 'live-check/' '$R'"
check "README documents the NN-*.txt|png filename convention" \
  "has '$R' 'NN-'"
check "README states the prose/template LOCKSTEP rule" \
  "has '$R' 'lockstep|both forms|same evidence path'"
check "README points at \`autopilot.sh live-check\` as the setup verb" \
  "grep -qF 'live-check' '$R' && grep -qF 'autopilot.sh' '$R'"
check "README says the MODEL does the looking and the script owns setup/evidence/record" \
  "has '$R' 'the model does the looking|the script owns'"

# ==========================================================================
# THE CONTRACT CONTROL — prove these checks can FAIL
# ==========================================================================
# With no control, "PASS: cli.md is installed" against an absent file is the
# exact false green that let the autopilot suite report 162/0 over an empty
# skills dir. Re-run THIS suite against an empty prefix and require red.
if [ -z "${LCARS_LC_NO_NEST:-}" ]; then
  echo
  echo "-- contract control (the same suite against an EMPTY skills dir) --"
  TMPC="$(mktemp -d)"
  mkdir -p "$TMPC/lcars-run/live-check"
  nested="$TMPC/nested.txt"
  LCARS_LC_NO_NEST=1 LCARS_SKILLS_DEST="$TMPC" \
    bash "$DIR/$(basename "${BASH_SOURCE[0]}")" >"$nested" 2>&1 </dev/null
  nrc=$?
  check "against an empty live-check dir the suite goes RED (it can fail)" "[ $nrc -ne 0 ]"
  check "it fails on the ABSENT cli.md, naming the path it looked at" \
    "grep -qE 'FAIL.*cli.md is installed at .*/lcars-run/live-check' '$nested'"
  check "it does NOT print a PASS for any absent checklist (the false green)" \
    "! grep -qE 'PASS.*(cli|web|workflow).md is installed' '$nested'"
  check "the dual-form contract itself goes red on empty files" \
    "grep -qE 'FAIL.*every numbered item carries prose' '$nested'"
  rm -rf "$TMPC"
fi

echo
echo "=== live-check: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
