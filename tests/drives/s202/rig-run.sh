#!/usr/bin/env bash
# S202 — run one LCARS verb inside the rig, the way the captain would.
#   bash tests/drives/s202/rig-run.sh xo on --engine copilot
#   bash tests/drives/s202/rig-run.sh run m-cap
#   bash tests/drives/s202/rig-run.sh answer
# Extra env for one call:  RIG_ENV_EXTRA="A=1 B=2" bash rig-run.sh ...
set -uo pipefail
OUT="${LCARS_S202_RIG_OUT:-${TMPDIR:-/tmp}/lcars-s202-tester}"
# shellcheck disable=SC1090
. "$OUT/rig.env"
SK="$RIG_HOME/.claude/skills"
# RIG_REAL_HOME=1 keeps the captain's own $HOME so a CLI that authenticates
# out of it (claude) can log in. LCARS itself still runs from the worktree
# scripts, and every write it makes is repo-scoped under the fixture's
# .git/lcars -- nothing installs into $HOME.
USE_HOME="$RIG_HOME"
[ "${RIG_REAL_HOME:-}" = "1" ] && USE_HOME="$HOME"
verb="$1"; shift
case "$verb" in
  xo)       script="$SK/lcars-xo/xo.sh" ;;
  run)      script="$SK/lcars-run/run.sh" ;;
  answer)   script="$SK/lcars-answer/answer.sh" ;;
  respond)  script="$SK/lcars-respond/respond.sh" ;;
  status)   script="$SK/lcars-status/status.sh" ;;
  *)        script="$SK/lcars-$verb/$verb.sh" ;;
esac
cd "$RIG_FIXTURE" || exit 77
# shellcheck disable=SC2086
exec env PATH="$RIG_BIN:$PATH" HOME="$USE_HOME" \
  LCARS_VERSION_CHECK=0 LCARS_OWNER_WARM=0 LCARS_GH_USER=roferg \
  LCARS_NOTIFY=true \
  GH_TOKEN="$(gh auth token 2>/dev/null)" \
  ${RIG_ENV_EXTRA:-} \
  bash "$script" "$@"
