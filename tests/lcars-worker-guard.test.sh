#!/usr/bin/env bash
#
# Tests for "`copilot` CAN NEVER BE VS CODE'S SHIM" (Session 217, part B).
#
# THE HAZARD (memory: copilot-shim-forkbomb-is-generic). VS Code ships its own
# `copilot` under .../github.copilot-chat/copilotCli/ — a /bin/sh launcher for
# copilotCLIShim.js, which re-invokes `copilot` BY NAME. Anything named
# `copilot` earlier on PATH and the shim then call each other until the machine
# cannot fork. It ate one night (2026-09-14) and came back through a SYMLINK
# (2026-09-18) after a one-file cure. So the cure here is ONE guard every place
# LCARS starts a worker CLI goes through:
#
#   skills/lcars-init/worker-guard.sh   — the bash rule (lcars_worker_bin_guard)
#   web/lcars_serve/worker_guard.py     — the daemon's copy of the SAME rule,
#                                         held to it by the parity checks below.
#
# ⚠ THIS FILE NEVER EXECUTES ANY COPILOT. Not the real one, not VS Code's shim.
# The shim fixtures below are harmless scripts that merely LIVE where the shim
# lives or CARRY its marker; if one were ever run it would drop a sentinel file,
# and the tests assert that sentinel never appears. The real shim and the real
# /opt/homebrew/bin/copilot are only ever RESOLVED (paths + reads), never run.
#
# Usage: bash tests/lcars-worker-guard.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/skills/lcars-init/worker-guard.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

SENTINEL="$TMPROOT/A-SHIM-WAS-EXECUTED"

# A harmless stand-in: if anything ever RUNS it, the sentinel says so.
harmless() { # <path> [<extra line>]
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\n%s\n: >"%s"\nexit 99\n' "${2:-}" "$SENTINEL" >"$1"
  chmod +x "$1"
}

# 1. Lives where VS Code's shim lives (path shape; the space in the path too).
SHIM_DIR="$TMPROOT/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli"
SHIM="$SHIM_DIR/copilot"
harmless "$SHIM"
# 2. An innocuous path, but it carries the shim's own marker (a copy / a
#    wrapper that hard-codes the shim).
MARKED="$TMPROOT/elsewhere/copilot"
harmless "$MARKED" '# exec "$HELPER" "/x/copilotCli/copilotCLIShim.js" "$@"'
# 3. A symlink named `copilot` on a scratch PATH dir pointing at the shim —
#    the exact 2026-09-18 route.
LINKBIN="$TMPROOT/scratch-bin"; mkdir -p "$LINKBIN"
ln -s "$SHIM" "$LINKBIN/copilot"
# 4. A symlink to a symlinked DIRECTORY holding the shim (two hops).
ln -s "$SHIM_DIR" "$TMPROOT/dirlink"
ln -s "$TMPROOT/dirlink/copilot" "$LINKBIN/copilot-via-dir"
# 5. A self-answering stub that records it ran (allowed).
STUB="$TMPROOT/stub-bin/copilot"
mkdir -p "$(dirname "$STUB")"
printf '#!/bin/sh\necho "stub ran" >"%s/stub-ran"\nexit 0\n' "$TMPROOT" >"$STUB"; chmod +x "$STUB"

# 6. A REAL (non-shim) copilot in its own PATH dir — what the refusal should
#    point at. Self-answering: never run by the guard, harmless if it were.
REALBIN="$TMPROOT/real-bin"; mkdir -p "$REALBIN"
printf '#!/bin/sh\necho "copilot 0.0 (stub)"\nexit 0\n' >"$REALBIN/copilot"; chmod +x "$REALBIN/copilot"

# guard <bin> [PATH] -> "rc<TAB>stderr" from the bash rule
guard_sh() { # <bin> [PATH] [hint]
  local p="${2:-$PATH}"
  PATH="$p" bash -c '. "$1"; lcars_worker_bin_guard "$2" "$3"' _ "$GUARD" "$1" "${3:-}" 2>&1 >/dev/null
  echo "rc=$?"
}
guard_py() { # <bin> [PATH] [hint]
  local p="${2:-$PATH}"
  PATH="$p" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1])
from lcars_serve.worker_guard import editor_shim_refusal
m = editor_shim_refusal(sys.argv[2], sys.argv[3])
print(m) if m else None
print("rc=%d" % (1 if m else 0))' "$REPO_ROOT/web" "$1" "${3:-}" 2>&1
}

echo "4. a bin that resolves under github.copilot-chat is refused, by name, with the fix"
out="$(guard_sh "$SHIM")"
check "4. refused (non-zero)" "printf '%s' \"\$out\" | grep 'rc=1' >/dev/null"
check "4. ONE sentence naming the path it found" \
  "[ \"\$(printf '%s\n' \"\$out\" | grep -vc '^rc=')\" = 1 ] && printf '%s' \"\$out\" | grep -qF \"$SHIM\""
check "4. …and a fix (the PATH fix, the one that works on every path)" \
  "printf '%s' \"\$out\" | grep -F 'ahead of it on PATH' >/dev/null || printf '%s' \"\$out\" | grep -F 'in place of' >/dev/null"
check "4. a script carrying the shim's own marker is refused too" \
  "guard_sh '$MARKED' | grep 'rc=1' >/dev/null"

echo "4b. the refusal happens BEFORE any spawn, at worker-adapter's one exec"
out="$(cd "$TMPROOT" && PATH="$REALBIN:/usr/bin:/bin" env -u LCARS_WORKER_BIN_INTERNAL LCARS_WORKER_BIN="$SHIM" bash "$ADAPTER" spawn copilot repo-read "$TMPROOT/out4" "hello" 2>&1)"; rc=$?
check "4b. worker-adapter spawn refuses (non-zero)" "[ $rc -ne 0 ]"
check "4b. …saying which path and the fix (the real CLI it found, and the variable that wins there)" \
  "printf '%s' \"\$out\" | grep -qF \"$SHIM\" && printf '%s' \"\$out\" | grep -F \"LCARS_WORKER_BIN=$REALBIN/copilot\" >/dev/null"

echo "5. a symlink named copilot on PATH that points at the shim"
check "5. bare \`copilot\` resolving through the symlink is refused" \
  "guard_sh copilot '$LINKBIN:/usr/bin:/bin' | grep 'rc=1' >/dev/null"
check "5. …and the sentence names the REAL path it resolved to, not just the link" \
  "guard_sh copilot '$LINKBIN:/usr/bin:/bin' | grep -F 'github.copilot-chat/copilotCli/copilot' >/dev/null"
check "5. a link through a symlinked DIRECTORY is followed too" \
  "guard_sh '$LINKBIN/copilot-via-dir' | grep 'rc=1' >/dev/null"
out="$(cd "$TMPROOT" && PATH="$LINKBIN:/usr/bin:/bin" env -u LCARS_WORKER_BIN bash "$ADAPTER" spawn copilot repo-read "$TMPROOT/out5" "hello" 2>&1)"; rc=$?
check "5. worker-adapter with no LCARS_WORKER_BIN (bin = \`copilot\` on PATH) refuses" "[ $rc -ne 0 ]"

echo "6. the real binary and the committed stubs are allowed"
if [ -e /opt/homebrew/bin/copilot ]; then
  check "6. /opt/homebrew/bin/copilot (a symlink to npm-loader.js) is ALLOWED — resolved only, never run" \
    "guard_sh /opt/homebrew/bin/copilot | grep 'rc=0' >/dev/null"
else
  printf '  (no /opt/homebrew/bin/copilot on this machine — skipped)\n'
fi
for s in tests/drives/holodeck-shim/copilot tests/drives/deploy-watcher/shim/copilot tests/drives/align-heal/faultinj/copilot; do
  check "6. committed stub $s is allowed" "guard_sh '$REPO_ROOT/$s' | grep 'rc=0' >/dev/null"
done
check "6. a bin that is not on PATH at all is not the guard's to refuse (the spawn's own error says so)" \
  "guard_sh no-such-cli-s217 | grep 'rc=0' >/dev/null"
out="$(cd "$TMPROOT" && LCARS_WORKER_BIN="$STUB" bash "$ADAPTER" spawn copilot repo-read "$TMPROOT/out6" "hello" 2>&1)"; rc=$?
check "6. a self-answering stub still SPAWNS through worker-adapter" "[ -f '$TMPROOT/stub-ran' ]"

REAL_SHIM="$HOME/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot"
if [ -e "$REAL_SHIM" ]; then
  check "4. the REAL VS Code shim on this machine is refused — by resolution only" \
    "guard_sh '$REAL_SHIM' | grep 'rc=1' >/dev/null"
  check "4. …and the daemon's copy refuses it too" \
    "guard_py '$REAL_SHIM' | grep 'rc=1' >/dev/null"
fi

echo "parity. the daemon's copy answers exactly as the bash rule does"
for b in "$SHIM" "$MARKED" "$LINKBIN/copilot-via-dir" "$STUB" \
         "$REPO_ROOT/tests/drives/holodeck-shim/copilot" no-such-cli-s217 /opt/homebrew/bin/copilot; do
  check "parity. $(basename "$(dirname "$b")")/$(basename "$b")" \
    "[ \"\$(guard_sh '$b')\" = \"\$(guard_py '$b')\" ]"
done
check "parity. bare \`copilot\` through the PATH symlink" \
  "[ \"\$(guard_sh copilot '$LINKBIN:/usr/bin:/bin')\" = \"\$(guard_py copilot '$LINKBIN:/usr/bin:/bin')\" ]"

echo "D2. the refusal's fix is TRUE on every path that emits it (fix round 1)"
# The old sentence advised LCARS_WORKER_BIN=/opt/homebrew/bin/copilot everywhere,
# but init resolves through LCARS_COPILOT_BIN/PATH and the daemon's picker
# outranks LCARS_WORKER_BIN — only the PATH fix works on every path. So the
# sentence LEADS with the PATH fix (the real CLI's own dir, found on PATH, never
# guessed when it can be found) and names a variable only where the CALLER says
# that variable wins.
out="$(guard_sh copilot "$LINKBIN:$REALBIN:/usr/bin:/bin")"
check "D2. leads with the PATH fix, naming the dir the REAL copilot was found in" \
  "printf '%s' \"\$out\" | grep -F \"put $REALBIN ahead of it on PATH\" >/dev/null"
check "D2. with no caller hint it names NO variable (none is known to win)" \
  "! printf '%s' \"\$out\" | grep -F 'LCARS_WORKER_BIN' >/dev/null"
out="$(guard_sh copilot "$LINKBIN:/usr/bin:/bin")"
check "D2. no real copilot findable on PATH → falls back to /opt/homebrew/bin" \
  "printf '%s' \"\$out\" | grep -F 'put /opt/homebrew/bin ahead of it on PATH' >/dev/null"
out="$(guard_sh copilot "$LINKBIN:$REALBIN:/usr/bin:/bin" LCARS_COPILOT_BIN)"
check "D2. a caller's variable hint names THAT variable, pointed at the real CLI" \
  "printf '%s' \"\$out\" | grep -F \"LCARS_COPILOT_BIN=$REALBIN/copilot\" >/dev/null && ! printf '%s' \"\$out\" | grep -F 'LCARS_WORKER_BIN' >/dev/null"
out="$(guard_sh copilot "$LINKBIN:$REALBIN:/usr/bin:/bin" 'restart the viewscreen')"
check "D2. a caller's plain hint is the sentence's last step" \
  "printf '%s' \"\$out\" | grep -F 'then restart the viewscreen.' >/dev/null"
out="$(guard_sh "$SHIM" "$REALBIN:/usr/bin:/bin")"
check "D2. an ABSOLUTE shim path: PATH order cannot cure it, so it says to use the real path in its place" \
  "printf '%s' \"\$out\" | grep -F \"$REALBIN/copilot in place of $SHIM\" >/dev/null && ! printf '%s' \"\$out\" | grep -F 'ahead of it on PATH' >/dev/null"
check "D2. FOLLOWING the PATH advice really cures it (real dir ahead of the shim link → allowed)" \
  "guard_sh copilot '$REALBIN:$LINKBIN:/usr/bin:/bin' | grep 'rc=0' >/dev/null"
for h in "" LCARS_COPILOT_BIN LCARS_WORKER_BIN 'restart the viewscreen'; do
  for p in "$LINKBIN:$REALBIN:/usr/bin:/bin" "$LINKBIN:/usr/bin:/bin" "$LINKBIN/:$REALBIN/:/usr/bin:/bin"; do
    check "D2 parity. copilot, hint='$h', PATH=${p//$TMPROOT/…}" \
      "[ \"\$(guard_sh copilot '$p' '$h')\" = \"\$(guard_py copilot '$p' '$h')\" ]"
  done
  check "D2 parity. absolute shim, hint='$h'" \
    "[ \"\$(guard_sh '$SHIM' '$REALBIN:/usr/bin:/bin' '$h')\" = \"\$(guard_py '$SHIM' '$REALBIN:/usr/bin:/bin' '$h')\" ]"
done

echo "D2. each call site names only the variable that wins THERE"
# init: resolves copilot through LCARS_COPILOT_BIN / PATH — never LCARS_WORKER_BIN.
IREPO="$TMPROOT/init-repo"; mkdir -p "$IREPO"; git -C "$IREPO" init -q
out="$(cd "$IREPO" && PATH="$LINKBIN:$REALBIN:/usr/bin:/bin" env -u LCARS_COPILOT_BIN -u LCARS_WORKER_BIN \
  LCARS_CLAUDE_BIN=no-such-claude-s217 LCARS_GH_BIN=no-such-gh-s217 bash "$REPO_ROOT/skills/lcars-init/init.sh" 2>&1)"; rc=$?
check "D2. init refuses the shim (non-zero)" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -F 'Refusing to start' >/dev/null"
check "D2. init's fix is the PATH fix + LCARS_COPILOT_BIN — never LCARS_WORKER_BIN (it does not win there)" \
  "printf '%s' \"\$out\" | grep -F \"put $REALBIN ahead of it on PATH\" >/dev/null && printf '%s' \"\$out\" | grep -F \"LCARS_COPILOT_BIN=$REALBIN/copilot\" >/dev/null && ! printf '%s' \"\$out\" | grep -F 'LCARS_WORKER_BIN' >/dev/null"
# worker-adapter: its bin IS ${LCARS_WORKER_BIN:-$cli}, so the variable wins —
# unless LCARS set it itself (approve / Number One re-pin: _INTERNAL=1), where a
# captain's prefix is overridden, so no variable is offered.
out="$(cd "$TMPROOT" && PATH="$LINKBIN:$REALBIN:/usr/bin:/bin" env -u LCARS_WORKER_BIN -u LCARS_WORKER_BIN_INTERNAL bash "$ADAPTER" spawn copilot repo-read "$TMPROOT/outd2a" "hello" 2>&1)"
check "D2. worker-adapter (bare copilot): PATH fix + LCARS_WORKER_BIN" \
  "printf '%s' \"\$out\" | grep -F \"put $REALBIN ahead of it on PATH\" >/dev/null && printf '%s' \"\$out\" | grep -F \"LCARS_WORKER_BIN=$REALBIN/copilot\" >/dev/null"
out="$(cd "$TMPROOT" && PATH="$LINKBIN:$REALBIN:/usr/bin:/bin" LCARS_WORKER_BIN=copilot LCARS_WORKER_BIN_INTERNAL=1 bash "$ADAPTER" spawn copilot repo-read "$TMPROOT/outd2b" "hello" 2>&1)"
check "D2. worker-adapter under LCARS's own re-pin (_INTERNAL=1): PATH fix only, no variable" \
  "printf '%s' \"\$out\" | grep -F \"put $REALBIN ahead of it on PATH\" >/dev/null && ! printf '%s' \"\$out\" | grep -F 'LCARS_WORKER_BIN=' >/dev/null"
# run.sh require_worker: the same rule as the adapter (external $LCARS_WORKER_BIN
# tops resolve_worker_bin; an _INTERNAL pin does not).
check "D2. run.sh require_worker passes the LCARS_WORKER_BIN hint only when not an internal pin" \
  "awk '/^require_worker\\(\\)/{on=1} on&&/lcars_worker_bin_guard \\\"\\\$WORKER_BIN\\\"/{print; exit}' '$REPO_ROOT/skills/lcars-run/run.sh' | grep -F 'hint' >/dev/null && grep -nE 'LCARS_WORKER_BIN_INTERNAL:-.*!= *\"?1|!= *\"1\".*LCARS_WORKER_BIN_INTERNAL' '$REPO_ROOT/skills/lcars-run/run.sh' | grep -F hint >/dev/null"
# daemon: the picker's engine outranks $LCARS_WORKER_BIN, so no variable — the
# PATH fix is the daemon's PATH, which means restarting the viewscreen.
dviol="$("$PY" - "$REPO_ROOT/web/lcars_serve/actions.py" "$REPO_ROOT/web" <<'PYEOF'
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
for n in ast.walk(ast.parse(src)):
    if isinstance(n, ast.Call) and getattr(n.func, "id", getattr(n.func, "attr", "")) == "editor_shim_refusal":
        args = n.args[1:] + [k.value for k in n.keywords]
        a = args[0] if args else None
        ok = (isinstance(a, ast.Constant) and "restart the viewscreen" in str(a.value)) or (
            isinstance(a, ast.Name) and a.id == "DAEMON_SHIM_HINT")
        if not ok:
            bad.append(str(n.lineno))
sys.path.insert(0, sys.argv[2])
from lcars_serve.worker_guard import DAEMON_HINT
if DAEMON_HINT != "restart the viewscreen":
    bad.append("DAEMON_HINT=%r" % DAEMON_HINT)
if "from .worker_guard import DAEMON_HINT as DAEMON_SHIM_HINT" not in src:
    bad.append("DAEMON_SHIM_HINT is not worker_guard.DAEMON_HINT")
print(" ".join(bad))
PYEOF
)"
check "D2. every daemon refusal ends 'then restart the viewscreen' and names no variable ${dviol:+(lines: $dviol)}" "[ -z \"\$dviol\" ]"

check "SAFETY. no shim fixture was ever executed by anything above" "[ ! -e '$SENTINEL' ]"

echo "7. every place LCARS starts a worker CLI goes through the one guard"
# (a) bash: a line that EXECUTES a worker binary — a worker-bin variable used
#     as a command with a flag after it, or `copilot` itself as a command —
#     may only live in a file that calls lcars_worker_bin_guard.
viol="$(cd "$REPO_ROOT" && grep -rnE \
  '^[[:space:]]*([A-Z_]+=[^[:space:]]+[[:space:]]+)*(exec[[:space:]]+)?"\$\{?(bin|ENGINE_BIN|WORKER_BIN|LCARS_WORKER_BIN|COPILOT_BIN|LCARS_COPILOT_BIN)\}?"[[:space:]]+-|\$\("\$\{?(bin|ENGINE_BIN|WORKER_BIN|LCARS_WORKER_BIN|COPILOT_BIN)\}?"[[:space:]]+-' \
  skills --include='*.sh' | cut -d: -f1 | sort -u \
  | while read -r f; do grep -q 'lcars_worker_bin_guard' "$f" || echo "$f"; done)"
check "7. every bash file that execs a worker bin calls lcars_worker_bin_guard ${viol:+(offenders: $viol)}" "[ -z \"\$viol\" ]"
bare="$(cd "$REPO_ROOT" && grep -rnE '(^|[;&|(]|\$\(|exec[[:space:]])[[:space:]]*copilot[[:space:]]+-' \
  skills web/lcars_serve install.sh --include='*.sh' --include='*.py' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
check "7. no bare \`copilot -…\` invocation anywhere in skills/ or the daemon ${bare:+(found: $bare)}" "[ -z \"\$bare\" ]"
check "7. worker-adapter's one exec is preceded by the guard in adapter_spawn" \
  "awk '/^adapter_spawn\\(\\)/{on=1} on&&/lcars_worker_bin_guard/{g=1} on&&/\"\\\$bin\" -p/{print (g?\"ok\":\"late\"); exit}' '$ADAPTER' | grep -q ok"
# (b) python: any argv list shaped like a worker turn — [<bin>, "-p", …] — or
#     a literal "copilot" argv[0] must sit in a function that calls the guard.
pyviol="$("$PY" - "$REPO_ROOT" <<'PYEOF'
import ast, os, sys
root = sys.argv[1]
bad = []
paths = []
for base in ("web/lcars_serve", "skills"):
    for d, _, fs in os.walk(os.path.join(root, base)):
        if "/tests" in d:
            continue
        paths += [os.path.join(d, f) for f in fs if f.endswith(".py")]
for p in paths:
    tree = ast.parse(open(p, encoding="utf-8").read())
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        spawns = []
        for n in ast.walk(fn):
            if isinstance(n, ast.List) and len(n.elts) >= 2:
                a, b = n.elts[0], n.elts[1]
                if isinstance(b, ast.Constant) and b.value == "-p" and not isinstance(a, ast.Constant):
                    spawns.append(n.lineno)
                if isinstance(a, ast.Constant) and a.value == "copilot":
                    spawns.append(n.lineno)
        if not spawns:
            continue
        guarded = any(isinstance(n, ast.Name) and n.id in ("editor_shim_refusal", "refuse_editor_shim")
                      or isinstance(n, ast.Attribute) and n.attr in ("editor_shim_refusal", "refuse_editor_shim")
                      for n in ast.walk(fn))
        if not guarded:
            bad.append("%s:%s %s" % (os.path.relpath(p, root), spawns[0], fn.name))
print("\n".join(bad))
PYEOF
)"
check "7. every daemon function that builds a worker argv calls the guard ${pyviol:+(offenders: $pyviol)}" "[ -z \"\$pyviol\" ]"

echo
printf 'lcars worker-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
