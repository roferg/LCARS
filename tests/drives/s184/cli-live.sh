#!/usr/bin/env bash
# S184 tester — THE CLI FRONT DOOR, live. `lcars` in a foundationless repo
# prints screen 1 + the foundation brief and stops; the SKILL then has the
# agent run the grill and call `establish-vision.sh --file`. Claude is the
# agent in the real product, and Claude is billed, so the agent role is played
# here by a LIVE copilot reading the SAME brief the router printed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/logs/cli-live"; rm -rf "$OUT"; mkdir -p "$OUT"
COPILOT="${LCARS_COPILOT_BIN:-/opt/homebrew/bin/copilot}"
REPO="$(newrepo s184-cli-live)"
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/s184cli.XXXXXX")"
cat > "$SHIM/claude" <<'SH'
#!/usr/bin/env bash
echo "S184 LIVE FENCE: claude REFUSED. argv: $*" >&2; exit 97
SH
chmod +x "$SHIM/claude"; ln -sf /usr/bin/true "$SHIM/gh"

echo "===================== 1. THE REAL CLI FRONT DOOR ====================="
( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true \
    bash "$LCARS_SRC/skills/lcars/lcars.sh" ) 2>&1 | tee "$OUT/lcars-front-door.txt"
echo "front-door rc=${PIPESTATUS[0]}"

BRIEF="$OUT/brief.txt"
( cd "$REPO" && bash "$LCARS_SRC/skills/lcars-init/establish-vision.sh" --brief ) > "$BRIEF"

IDEA="$OUT/idea.txt"
cat > "$IDEA" <<'IDEA'
a website that does personal finance stuff. Basically a Mint clone — budgets,
charts, bank sync via Plaid, a mobile app, CSV import from my bank,
recurring-bill detection, multi-currency and a shared household mode. I need it
shipped by Friday. Also a dark mode toggle, a Chrome extension and email
digests. Just plan the whole feature list now.
IDEA

echo "===================== 2. THE LIVE GRILL (copilot) ====================="
PROMPT="$(cat "$BRIEF")

=== WHAT THE CAPTAIN SAID ===

$(cat "$IDEA")

=== YOUR TASK ===
You have interviewed the captain and he will answer nothing further; he has said
'whatever you recommend is fine, just go'. Produce the four values the brief
asks you to hand back, and NOTHING else, in exactly this shape:

STACK: <one line>
REASONS:
- <line>
- <line>
SLICE: <one line, a noun phrase>
DEFERRED:
- <line>
- <line>
"
printf '%s\n' "$PROMPT" > "$OUT/grill-prompt.txt"
( cd "$REPO" && PATH="${PATH#$SHIM:}" "$COPILOT" -p "$PROMPT" --available-tools= \
    --no-ask-user --disable-builtin-mcps --no-custom-instructions \
    --model claude-opus-4.8 </dev/null ) > "$OUT/grill-reply.txt" 2> "$OUT/grill-reply.err"
echo "copilot rc=$?"
cat "$OUT/grill-reply.txt"

echo "===================== 3. PARSE + FILE ====================="
python3 - "$OUT" <<'PY'
import re,sys,os
out=sys.argv[1]; t=open(os.path.join(out,"grill-reply.txt")).read()
def sect(name, nxt):
    m=re.search(r'^%s:\s*(.*?)(?=^(?:%s):)'%(name,nxt), t, re.M|re.S)
    return (m.group(1).strip() if m else "")
stack=re.search(r'^STACK:\s*(.+)$', t, re.M)
slice_=re.search(r'^SLICE:\s*(.+)$', t, re.M)
reasons=sect("REASONS","SLICE|DEFERRED|STACK")
deferred=sect("DEFERRED","STACK|REASONS|SLICE") or (t.split("DEFERRED:",1)[1] if "DEFERRED:" in t else "")
clean=lambda s:"\n".join(l.lstrip("-* ").strip() for l in s.splitlines() if l.strip())
open(os.path.join(out,"stack.txt"),"w").write((stack.group(1).strip() if stack else ""))
open(os.path.join(out,"slice.txt"),"w").write((slice_.group(1).strip() if slice_ else ""))
open(os.path.join(out,"reasons.txt"),"w").write(clean(reasons)+"\n")
open(os.path.join(out,"deferred.txt"),"w").write(clean(deferred)+"\n")
print("STACK:",open(os.path.join(out,"stack.txt")).read())
print("SLICE:",open(os.path.join(out,"slice.txt")).read())
PY
STACK="$(cat "$OUT/stack.txt")"; SLICE="$(cat "$OUT/slice.txt")"
[ -n "$STACK" ] || { echo "FAIL: no stack parsed"; exit 1; }
( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true \
   bash "$LCARS_SRC/skills/lcars-init/establish-vision.sh" --file \
     --idea "$IDEA" --stack "$STACK" --slice "$SLICE" \
     --reasons "$OUT/reasons.txt" --deferred "$OUT/deferred.txt" ) 2>&1 | tee "$OUT/file.txt"
mid="$(ls -t "$REPO/.git/lcars/missions" 2>/dev/null | head -1)"
echo "mission=$mid"
cp "$REPO/.git/lcars/missions/$mid/prd.md" "$OUT/prd.md" 2>/dev/null
cp "$REPO/.git/lcars/vision.md" "$OUT/vision.md" 2>/dev/null
cp "$REPO/.git/lcars/missions/$mid/state.json" "$OUT/state.json" 2>/dev/null
echo "REPO=$REPO  OUT=$OUT"
