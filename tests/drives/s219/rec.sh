#!/bin/bash
# rec.sh <turn#> <rule-text> <reasked yes/no> [answer-file]
S="$(cd "$(dirname "$0")" && pwd)"; N=$1; A="${4:-$S/prompts/turn-$N.answer.txt}"
{ echo "## Turn $N"; echo; echo "**Question (verbatim, as the board showed it):**"; echo; sed 's/^/> /' "$S/prompts/turn-$N.q.txt"; echo
  echo "**Copilot's answer (verbatim, as sent):**"; echo; sed 's/^/> /' "$A"; echo
  echo "**Rests on:** $2"; echo; echo "**Re-asked:** $3"; echo; } >> "$S/stand-in-decisions.md"
