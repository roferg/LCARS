#!/usr/bin/env bash
#
# S114 — the REAL liveness signal. run.sh's hang guard now maintains a sidecar
# $MISSION_DIR/worker-liveness.json describing the LIVE cold worker's output
# activity — thinking (burning CPU) / producing (output grew) / quiet (idle+silent)
# — and REMOVES it on EVERY exit (normal or HUNG) so a finished/dead worker shows
# NO pulse. This is derived PURELY from the cpu/sig data the hang guard already
# computes; the stagnant/kill semantics are untouched (that is the sibling suite
# tests/lcars-worker-hang.test.sh, which MUST stay green).
#
# STANDALONE, STUB-ONLY: FAKE workers made of bash builtins ONLY — NO model
# worker, NO claude/copilot, NO gh, NO network, ZERO tokens. Safe to run directly.
#
# Usage: bash tests/worker-liveness.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# --- extract the functions under test (mirror lcars-worker-hang.test.sh) ------
HG_LIB="$TMPROOT/liveness.lib.sh"
sed -n '/^pid_alive() {/,/^}/p'                 "$RUN_SH" >"$HG_LIB"
sed -n '/^_pgid_cpu_sum() {/,/^}/p'             "$RUN_SH" >>"$HG_LIB"
sed -n '/^_file_size_mtime() {/,/^}/p'          "$RUN_SH" >>"$HG_LIB"
sed -n '/^_liveness_output_bytes() {/,/^}/p'    "$RUN_SH" >>"$HG_LIB"
sed -n '/^_liveness_write() {/,/^}/p'           "$RUN_SH" >>"$HG_LIB"
sed -n '/^_wait_for_exit_or_poll() {/,/^}/p'    "$RUN_SH" >>"$HG_LIB"
sed -n '/^run_worker_hang_guarded() {/,/^}/p'   "$RUN_SH" >>"$HG_LIB"
# shellcheck source=/dev/null
. "$HG_LIB"

for fn in pid_alive _pgid_cpu_sum _file_size_mtime _liveness_output_bytes \
          _liveness_write _wait_for_exit_or_poll run_worker_hang_guarded; do
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: could not extract $fn from $RUN_SH" >&2
    exit 1
  fi
done

state_of() { sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$1" 2>/dev/null; }

# Fast poll + short floor so a few-second stub exercises real transitions.
export LCARS_WORKER_HANG_POLL=1
export LCARS_WORKER_HANG_CPU_MIN=0     # any CPU>0 reads as "thinking"
export LCARS_LIVENESS_MIN_WRITE=1      # tester floor (production default is 5s)
export LCARS_LIVENESS_STAGE=implement

# === A. thinking → producing → quiet, then REMOVED on clean exit =============
export LCARS_WORKER_HANG_SECS=30       # generous: the quiet tail must NOT be killed
A_MDIR="$TMPROOT/mA"; mkdir -p "$A_MDIR"
A_OUT="$TMPROOT/oA"; mkdir -p "$A_OUT"
A_LIVE="$A_MDIR/worker-liveness.json"
STUB="$TMPROOT/phases.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
out="$1/.worker.out"
# phase 1 — THINKING: burn CPU ~4s, no output.
end=$((SECONDS + 4)); while [ "$SECONDS" -lt "$end" ]; do :; done
# phase 2 — PRODUCING: append output every second ~4s (idle between appends).
for i in 1 2 3 4; do printf 'chunk %s\n' "$i" >>"$out"; sleep 1; done
# phase 3 — QUIET: idle + silent ~4s.
sleep 4
exit 0
EOF
chmod +x "$STUB"

# Drive the guard in the background; MISSION_DIR selects the sidecar location.
( MISSION_DIR="$A_MDIR" run_worker_hang_guarded "$A_OUT" "$STUB" "$A_OUT" ) &
guard_pid=$!

seen=""; first_state=""; producing_bytes=""
while kill -0 "$guard_pid" 2>/dev/null; do
  if [ -f "$A_LIVE" ]; then
    st="$(state_of "$A_LIVE")"
    if [ -n "$st" ]; then
      [ -n "$first_state" ] || first_state="$st"
      case " $seen " in *" $st "*) : ;; *) seen="$seen $st" ;; esac
      if [ "$st" = "producing" ] && [ -z "$producing_bytes" ]; then
        producing_bytes="$(sed -n 's/.*"outputBytes":\([0-9]*\).*/\1/p' "$A_LIVE")"
      fi
    fi
  fi
  sleep 0.4
done
wait "$guard_pid"; a_rc=$?
sleep 1   # let the finalize (rm) settle

seen="$(printf '%s' "$seen" | sed 's/^ *//')"
if [ "$a_rc" -eq 0 ]; then
  ok "A1. working worker runs to completion (rc 0 — not killed)"
else
  bad "A1. working worker rc (expected 0, got $a_rc)"
fi
case " $seen " in *" thinking "*) ok "A2. THINKING observed (CPU-busy, silent)";;
  *) bad "A2. never observed thinking (seen:$seen)";; esac
case " $seen " in *" producing "*) ok "A3. PRODUCING observed (output grew)";;
  *) bad "A3. never observed producing (seen:$seen)";; esac
case " $seen " in *" quiet "*) ok "A4. QUIET observed (idle+silent tail)";;
  *) bad "A4. never observed quiet (seen:$seen)";; esac
if [ -n "$producing_bytes" ] && [ "$producing_bytes" -gt 0 ] 2>/dev/null; then
  ok "A5. producing is HONEST — outputBytes>0 when producing ($producing_bytes)"
else
  bad "A5. producing without real output bytes (got '$producing_bytes')"
fi
if [ ! -e "$A_LIVE" ]; then
  ok "A6. sidecar REMOVED on clean exit (a finished worker shows no pulse)"
else
  bad "A6. sidecar survived a clean exit: $(cat "$A_LIVE" 2>/dev/null)"
fi

# === B. the HUNG path also REMOVES the sidecar (never a stale 'producing') ====
export LCARS_WORKER_HANG_SECS=3
B_MDIR="$TMPROOT/mB"; mkdir -p "$B_MDIR"
B_OUT="$TMPROOT/oB"; mkdir -p "$B_OUT"
B_LIVE="$B_MDIR/worker-liveness.json"
HUNG="$TMPROOT/hung.sh"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$HUNG"; chmod +x "$HUNG"

( MISSION_DIR="$B_MDIR" run_worker_hang_guarded "$B_OUT" "$HUNG" )
b_rc=$?
sleep 1
if [ "$b_rc" -eq 137 ]; then
  ok "B1. hung worker returns the HUNG sentinel (137) — hang semantics intact"
else
  bad "B1. hung worker sentinel (expected 137, got $b_rc)"
fi
if [ ! -e "$B_LIVE" ]; then
  ok "B2. sidecar REMOVED on the HUNG path (a killed worker shows no pulse)"
else
  bad "B2. sidecar survived the HUNG path: $(cat "$B_LIVE" 2>/dev/null)"
fi

# === C. no MISSION_DIR ⇒ NO sidecar written anywhere (Align context-pack path)
C_OUT="$TMPROOT/oC"; mkdir -p "$C_OUT"
QUICK="$TMPROOT/quick.sh"; printf '#!/usr/bin/env bash\nsleep 1\nexit 0\n' >"$QUICK"; chmod +x "$QUICK"
before="$(find "$TMPROOT" -name worker-liveness.json 2>/dev/null | wc -l | tr -d ' ')"
( unset MISSION_DIR; run_worker_hang_guarded "$C_OUT" "$QUICK" )
c_rc=$?
after="$(find "$TMPROOT" -name worker-liveness.json 2>/dev/null | wc -l | tr -d ' ')"
if [ "$c_rc" -eq 0 ] && [ "$before" = "$after" ]; then
  ok "C. no MISSION_DIR ⇒ no sidecar written (byte-identical no-op path)"
else
  bad "C. no-MISSION_DIR path wrote a sidecar or bad rc (rc=$c_rc before=$before after=$after)"
fi

# === D. _liveness_write emits the exact documented JSON shape ================
D_LIVE="$TMPROOT/shape.json"
_liveness_write "$D_LIVE" plan 100 142 512 producing
shape="$(cat "$D_LIVE" 2>/dev/null)"
expected='{"stage":"plan","startedAt":100,"lastOutputTs":142,"outputBytes":512,"state":"producing"}'
if [ "$shape" = "$expected" ]; then
  ok "D1. liveness JSON shape is exact: $shape"
else
  bad "D1. liveness JSON shape drift — got: $shape"
fi
if _liveness_bytes_out="$(_liveness_output_bytes "$STUB" "$STUB")" \
   && [ "$_liveness_bytes_out" -gt 0 ] 2>/dev/null; then
  ok "D2. _liveness_output_bytes sums file sizes ($_liveness_bytes_out)"
else
  bad "D2. _liveness_output_bytes failed (got '${_liveness_bytes_out:-}')"
fi

# === E. anti-thrash: the production write floor DEFAULTS to 5s (structural) ==
HG_BODY="$(declare -f run_worker_hang_guarded)"
if grep -Eq 'LCARS_LIVENESS_MIN_WRITE:-5' <<<"$HG_BODY"; then
  ok "E. write-floor default is 5s (SSE stays calm at poll=1)"
else
  bad "E. no 5s write-floor default found in the guard"
fi

# --- summary ----------------------------------------------------------------
echo
printf 'worker-liveness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
