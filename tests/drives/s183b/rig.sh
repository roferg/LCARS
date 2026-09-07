#!/usr/bin/env bash
# S183b TESTER RIG — zero-spend fixture builder + drive harness for the
# foundation oracle and the filing gate.
#
# Inherits S182's SPEND FUSE contract verbatim: every drive runs under a PATH
# shim carrying COUNTING fake `claude` + `copilot`, and refuses to run at all if
# they are not there (an empty shim dir puts the REAL billed claude on PATH).
set -u

LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
INIT_SH="$LCARS_SRC/skills/lcars-init/init.sh"
FILE_SH="$LCARS_SRC/skills/lcars-file/file.sh"
UPDATE_SH="$LCARS_SRC/skills/lcars-update/update.sh"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
GATE_SH="$LCARS_SRC/skills/lcars-init/foundation-gate.sh"
READINESS_SH="$LCARS_SRC/skills/lcars-init/readiness.sh"

FIX_ROOT="${FIX_ROOT:-${TMPDIR:-/tmp}lcars-s183b}"
FIX_ROOT="${FIX_ROOT%/}"

# --- shim (S182 rig.sh, verbatim contract) ---------------------------------
make_shim() {
  local log="$1" d b
  d="$(mktemp -d "${TMPDIR:-/tmp}/s183shim.XXXXXX")"
  for b in claude copilot; do
    cat > "$d/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*)
      printf 'PROBE\t%s\t--version\n' "\$(basename "\$0")" >> "$log"
      echo "0.0.0-s183-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\t%s\n' "\$(basename "\$0")" "\$(printf '%s' "\$*" | head -c 120 | tr '\n' ' ')" >> "$log"
{ echo "=== \$(basename "\$0") ==="; printf '%s\n' "\$*"; } >> "$log.argv"
printf '%s' "\$*" | grep -oE 'EXACTLY: /[^[:space:]]+' | sed 's/^EXACTLY: //' \
  | while read -r p; do
      mkdir -p "\$(dirname "\$p")"
      printf '# stub written by the S183b counting fake worker\n\nNo real model ran.\n' > "\$p"
    done
exit 0
SH
    chmod +x "$d/$b"
  done
  echo "$d"
}

fuse() {
  local sh="${1:-}"
  if [ -n "$sh" ] && [ -x "$sh/claude" ] && [ -x "$sh/copilot" ]; then return 0; fi
  echo "SPEND FUSE TRIPPED: no counting claude/copilot at '${sh:-<empty>}' — REFUSING (would bill)" >&2
  return 1
}

drive() { # repo shim [env pairs…] -- argv…
  local r="$1" sh="$2"; shift 2
  fuse "$sh" || { RC=99; OUT="REFUSED-BY-FUSE"; return 0; }
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # bash 3.2: "${envs[@]}" on an EMPTY array explodes under `set -u`.
  OUT="$( cd "$r" && env PATH="$sh:$PATH" LCARS_GH_BIN=true \
            LCARS_GIT_BIN="$(command -v git)" \
            ${envs[@]+"${envs[@]}"} "$@" 2>&1 )"
  RC=$?
}

calls()  { awk '/^SPAWN/{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }
probes() { awk '/^PROBE/{n++} END{print n+0}' "$1" 2>/dev/null || echo 0; }

# --- fixture helpers -------------------------------------------------------
newrepo() { # name → path (fresh; unborn HEAD, no commit)
  local p="$FIX_ROOT/$1"
  rm -rf "$p"; mkdir -p "$p"
  git -C "$p" init -q 2>/dev/null || git -C "$p" init 2>/dev/null >/dev/null
  git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
  git -C "$p" config commit.gpgsign false
  echo "$p"
}
commitall() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "${2:-fixture}" >/dev/null 2>&1; }

# --- probes ----------------------------------------------------------------
verdict() { # repo → "status<TAB>foundation<TAB>why"
  ( cd "$1" && bash "$READINESS_SH" --json 2>/dev/null ) \
    | sed -E 's/.*"status":"([^"]*)".*"foundation":(null|"[^"]*"),"foundationWhy":(null|"[^"]*").*/\1\t\2\t\3/'
}
line() { ( cd "$1" && bash "$READINESS_SH" --line 2>&1 ); }
gate() { ( cd "$1" && bash "$GATE_SH" 2>&1 ); echo "GATE_RC=$?"; }
