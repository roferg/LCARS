#!/bin/bash
# ask.sh <turn#> <question-file> [extra-note-file]  -> prints Copilot's answer; saves prompt+answer under prompts/
S="$(cd "$(dirname "$0")" && pwd)"; N="$1"; Q="$2"; X="${3:-}"
P="$S/prompts/turn-$N.prompt.txt"
{ cat "$S/prompts/context.txt"; echo; echo "=== THE INTERVIEWER'S CURRENT QUESTION (answer this) ==="; cat "$Q";
  if [ -n "$X" ]; then echo; echo "=== NOTE FROM THE DRIVER ==="; cat "$X"; fi; } > "$P"
cd /private/tmp || exit 1
/opt/homebrew/bin/copilot -p "$(cat "$P")" --model claude-opus-4.8 --available-tools= --disable-builtin-mcps --no-custom-instructions --no-auto-update --no-ask-user --no-color -s > "$S/prompts/turn-$N.answer${X:+-reask}.txt" 2> "$S/prompts/turn-$N.stderr${X:+-reask}.txt"
rc=$?; cat "$S/prompts/turn-$N.answer${X:+-reask}.txt"; exit $rc
