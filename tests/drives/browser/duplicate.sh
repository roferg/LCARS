#!/usr/bin/env bash
# ============================================================================
# S172 fix round 1 — ⧉ DUPLICATE A PROGRAM, IN A REAL BROWSER.
#
#   bash tests/drives/browser/duplicate.sh              # the product
#   bash tests/drives/browser/duplicate.sh --calibrate  # the RED CONTROLS
#   bash tests/drives/browser/duplicate.sh --all        # both
#
# WHY THIS RIG EXISTS. S172 built ⧉ Duplicate with 33 new headless tests and
# shipped it into a tester's real Chrome, where it could not duplicate either of
# the captain's two real programs. Both of the defects that mattered were
# structurally invisible to the suite that "covered" the feature:
#
#   • D1 (BLOCKER) — the room a copy lands in is `_slug`'d and capped at 48
#     characters, and every program the captain actually has is named with his
#     whole idea sentence. The "(copy N)" differentiator lived only in the
#     DISPLAY name, so it fell off the far side of the cut and all 500 candidate
#     rooms came back as the SOURCE'S OWN. The headless suite named every
#     program "Command palette" — 15 characters — so it never once reached the
#     cap. THE FIXTURE HERE IS THE CAPTAIN'S ACTUAL PROGRAM NAME, copied out of
#     his archive: 114 characters. That is the whole point of it, and it must
#     not be shortened. (Fix round 1 wrote that sentence over a 51-character
#     stand-in. It crossed the cap, so D1 was really exercised — but it
#     under-measured D3 by a factor of two, painting a 43px lineage chip where
#     his real name paints 72px, and it was too short to reach N1 at all.)
#   • D3 — the lineage chip was `max-width:14ch`, so "⧉ from Tile editor" and
#     "⧉ from Tile editor (copy)" both painted as "⧉ from Tile…": the same six
#     characters for every possible parent, on a chip whose entire job is to
#     answer "which one was that". The CSS rule resolves perfectly; it simply
#     does not fit. No node DOM harness under web/tests/ can see that — none of
#     them has any CSS or any layout at all (the documented
#     `css-rule-tests-green-never-reaches-screen` class).
#
# So the verdicts here are read off LAID-OUT BOXES and RESOLVED styles in real
# headed Chrome, driving the real daemon over a real sidecar git repo, through
# the same controls a captain clicks.
#
# WHAT IS CHECKED (each is named in duplicate-check.json, and each has a red
# control below that breaks THAT ONE):
#   DUP-CONTROL-ON-LOCKED-CARD          ⧉ Duplicate is on the SENT card, painted
#                                       and not covered — the one state the
#                                       whole feature exists for.
#   LOCK-PANE-DUPLICATE-IS-LIVE         FIX ROUND 3: open the locked program and
#                                       the ⧉ Duplicate control in its OWN CHAT
#                                       PANE is painted, enabled and wired, and
#                                       nothing there says "not built" or sends
#                                       him off to start a program under a
#                                       different name. Both earlier rounds drove
#                                       the card only, so S127's disabled
#                                       placeholder survived two "proven" rounds
#                                       in the one room a captain is standing in
#                                       when he meets the lock.
#   LOCK-PANE-DUPLICATE-WORKS           …and clicking it copies the program: the
#                                       SECOND of the two copies below is made
#                                       from the pane, not the card, so the two
#                                       controls are measured as one mechanism.
#   DUP-BLANK-NAME-WORKS                the road the dialog RECOMMENDS copies a
#                                       real-length program name without
#                                       refusing. (D1.)
#   DUP-TWO-DISTINCT-ROOMS              twice → two rooms, neither the source's.
#   COPY-CARRIES-THE-SOURCES-FILES      the room a copy landed in really holds
#                                       the source's files. FIX ROUND 2: the
#                                       tester dropped mockup.html, concept.md
#                                       and attachments/ from the copy road and
#                                       this rig said 7/7 green — the dialog's
#                                       own promise broken, in silence, because
#                                       DUP-BLANK-NAME-WORKS asserts only that
#                                       the dialog closed.
#   NO-TWO-CARDS-ONE-NAME               no two cards on the deck read the same
#                                       name. FIX ROUND 2: the tester made the
#                                       copy keep its parent's name — three
#                                       identical cards, the exact pair the
#                                       daemon's 409 exists to prevent — and
#                                       this rig said 7/7 green, because
#                                       SOURCE-STAYS-SENT name-checks the SOURCE
#                                       row and nothing ever looked at a copy's.
#   SOURCE-STAYS-SENT                   the filed program is never mutated.
#   LINEAGE-CHIP-READABLE               the ⧉ from chip is not clipped and names
#                                       the parent in full. (D3.)
#   INHERITED-GROUNDING-SAID-ON-SCREEN  the copy's chat header says the
#                                       grounding is inherited and may be stale,
#                                       not "grounded in <repo>".
#   CONTINUING-CHIP-ON-SCREEN           the copy's chat header says WHOSE
#                                       conversation the pane is holding. The
#                                       banner that said so is transient; one
#                                       refresh later the parent's history
#                                       reads as this program's own work.
#
# ZERO TOKENS. The only `claude`/`copilot` on PATH are logging shims that exit
# 1, and the journey driven here (list → duplicate → open) never takes a turn,
# so no worker is ever invoked. The run reports the shim log either way.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"
CHROME="${LCARS_CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
NODE="${LCARS_NODE_BIN:-node}"
PY="${LCARS_PYTHON_BIN:-python3}"

# THE CAPTAIN'S REAL PROGRAM NAME, and the room `_slug` puts it in. Verbatim
# out of `groutwork-holodeck/give-the-tile-editor-a-more-modern-ui-look-and`,
# 114 characters, because the defects this rig exists for only appear past the
# 48-character cap and the chip this rig measures is only as tall as the name
# is long. (His other real program's name is 124.)
SRC_NAME="Give the tile editor a more modern UI look and add a light/dark mode. I don't want to touch the tile canvas at all"
SRC_ROOM="give-the-tile-editor-a-more-modern-ui-look-and"
MISSION="lcars-20260807-001"

WORK="${LCARS_BROWSER_DUP_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-dup.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-dup.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-dup.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
skip() { printf '\033[33mSKIPPED\033[0m — %s\n' "$*"; exit 77; }

command -v "$NODE" >/dev/null 2>&1 || skip "no node on PATH (rig needs it to drive Chrome)"
[ -x "$CHROME" ] || skip "no Chrome at $CHROME (set \$LCARS_CHROME_BIN)"

# ── the planted archive: ONE SENT, LOCKED program with a real-length name ────
# Planted rather than driven, because what is being proven is what the DECK does
# with a room that already exists — the state the captain is actually in, with
# two programs already filed.
plant() {   # $1 = out dir → echoes the holodeck root
  local out="$1"
  local fixture="$out/fixture" root="$out/holo-root"
  local side="$root/fixture-holodeck"
  rm -rf "$fixture" "$root"
  mkdir -p "$fixture/.git/lcars/missions/$MISSION"
  cat >"$fixture/.git/lcars/config.json" <<EOF
{"lcarsVersion": "$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)",
 "repo": "acme/dup-drive", "testCommand": "true"}
EOF
  cat >"$fixture/.git/lcars/missions/$MISSION/state.json" <<EOF
{"id": "$MISSION", "type": "feature", "title": "Tile editor UI",
 "stage": "implement", "created": "2026-08-07T10:00:00Z", "model": "claude",
 "githubIssue": 261, "branch": "lcars/$MISSION", "base": "main"}
EOF
  mkdir -p "$side/$SRC_ROOM/attachments" "$side/nav-rail"
  cat >"$side/README.md" <<'MD'
# fixture-holodeck — planted by duplicate.sh. Not a captain's archive.
MD
  cat >"$side/$SRC_ROOM/transcript.md" <<TR
# $SRC_NAME

The holodeck's record of this program.

_Engine: \`claude\`_

_Sent to Align: mission \`$MISSION\` at 2026-08-07T12:00:00Z_ — this program was handed over and is READ-ONLY. The mission was briefed on the files exactly as they were at that moment.

## Turn 1 · 2026-08-07T09:00:00Z

**Captain:** Give the tile editor a more modern UI look.

**Holodeck:** Rebuilt the toolbar as a floating pill and moved the swatch grid to a 6px radius. The accent stays #2de3c7.

## Turn 2 · 2026-08-07T09:20:00Z

**Captain:** The rail has to collapse, and it has to remember.

**Holodeck:** Added a collapsed 56px state persisted to localStorage.
TR
  cat >"$side/$SRC_ROOM/concept.md" <<CN
# $SRC_NAME — what it must do

**Turn 1:** "give the tile editor a more modern UI look" — T1

## Decisions

- The rail is 56px collapsed and 216px expanded.
- The accent stays \`#2de3c7\`.
CN
  cat >"$side/$SRC_ROOM/basis.md" <<'BS'
# Design basis

## Colour

- `--ink` **#101318** (tokens.css)
- `--accent` **#2de3c7** (tokens.css)

No light theme — the project is dark-only today.
BS
  cat >"$side/$SRC_ROOM/mockup.html" <<'MK'
<!DOCTYPE html>
<!-- VISUAL REFERENCE ONLY — a rig fixture standing in for a model-written
     mockup. Not shipping code; it exists so the copied room has something
     REAL on disk. -->
<html><head><meta charset="utf-8"><title>Tile editor — mockup</title>
<style>body{margin:0;background:#0a0a0f;color:#e8ecf5;font:14px system-ui}
.hd{padding:10px 12px;background:#12121c;border-bottom:1px solid #23233a;font-weight:600}
.row{display:flex;gap:8px;align-items:center;padding:9px 10px;border-radius:6px;
     background:#12121c;margin:7px 12px;font-size:12px}
.sw{width:22px;height:22px;border-radius:5px;background:#2de3c7}</style></head>
<body><div class="hd">Tile editor — SENT</div>
<div class="row"><span class="sw"></span><span>Kitchen splashback</span></div>
</body></html>
MK
  printf 'PNGISH-FIXTURE-BYTES\n' >"$side/$SRC_ROOM/attachments/shot-1.png"
  # the derivation that must NOT travel (S172 trap 1) — planted so the copy is
  # made against a room that really has one.
  cat >"$side/$SRC_ROOM/handoff-changes.json" <<'HC'
{"fingerprint": "sha256:deadbeefdeadbeefdeadbeefdeadbeef",
 "generatedAt": "2026-08-07T11:59:00Z",
 "changes": [{"file": "src/TileEditor.tsx", "what": "toolbar becomes a pill"}]}
HC
  # a short, ordinary draft for contrast: a deck with only one card cannot show
  # that the chip tells two PARENTS apart.
  cat >"$side/nav-rail/transcript.md" <<'TR2'
# Nav rail

The holodeck's record of this program.

## Turn 1 · 2026-08-06T09:00:00Z

**Captain:** Draft a nav rail.

**Holodeck:** First pass is up.
TR2
  cat >"$side/nav-rail/mockup.html" <<'MK2'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Nav rail</title></head>
<body style="margin:0;background:#0a0a0f;color:#e8ecf5"><h1>Nav rail</h1></body></html>
MK2
  ( cd "$side" && git init -q . &&
    git -c user.email=h@l -c user.name=holo add -A &&
    git -c user.email=h@l -c user.name=holo commit -q --no-gpg-sign \
        -m "holodeck: sidecar created" ) >/dev/null 2>&1 ||
    skip "could not git init the planted sidecar at $side"
  printf '%s' "$root"
}

# ── one run: real daemon + real headed Chrome + the driver ──────────────────
DPID=""; CPID=""
reap() {
  [ -n "$CPID" ] && kill -9 "$CPID" 2>/dev/null
  # the viewscreen daemon ignores SIGTERM AND SIGINT — only -9 reaps it.
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  DPID=""; CPID=""
}
trap reap EXIT INT TERM

RC=0
run_once() {   # $1 = label, $2 = web dir, $3 = out dir
  local label="$1" web="$2" out="$3"
  mkdir -p "$out"
  local root; root="$(plant "$out")"

  # ── zero-spend shims. Both engines, both loud, both exit non-zero. ────────
  mkdir -p "$out/shim"
  local e
  for e in claude copilot; do
    cat >"$out/shim/$e" <<EOF
#!/usr/bin/env bash
echo "$e \$*" >>"$out/worker-shim.log"
echo "RIG: a worker was spawned by duplicate.sh. Investigate." >&2
exit 1
EOF
    chmod +x "$out/shim/$e"
  done
  : >"$out/worker-shim.log"

  say "── $label"
  note "web:      $web"
  note "sidecar:  $root/fixture-holodeck/$SRC_ROOM"

  ( cd "$web" && exec env -u LCARS_SERVE_PORT \
      PATH="$out/shim:$PATH" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
      LCARS_WORKER_BIN="$out/shim/claude" LCARS_GH_BIN="$out/shim/claude" \
      LCARS_HOLODECK_ROOT="$root" \
      "$PY" -m lcars_serve --port 0 --repo-root "$out/fixture" ) \
    >"$out/daemon.log" 2>&1 &
  DPID=$!
  local url="" i
  for i in $(seq 1 200); do
    url="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$out/daemon.log" | head -1)"
    [ -n "$url" ] && break
    kill -0 "$DPID" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$url" ]; then
    printf '\033[33m  the daemon never came up\033[0m\n'; sed -n '1,25p' "$out/daemon.log"
    reap; RC=77; return 77
  fi

  local profile="$out/chrome-profile"
  mkdir -p "$profile"; rm -f "$profile/DevToolsActivePort"
  "$CHROME" --user-data-dir="$profile" --remote-debugging-port=0 \
    --no-first-run --no-default-browser-check --no-service-autorun \
    --disable-background-networking --disable-sync --disable-extensions \
    --disable-component-update --disable-default-apps --disable-popup-blocking \
    --window-size=1600,1050 about:blank >"$out/chrome.log" 2>&1 &
  CPID=$!
  local dev="" p
  for i in $(seq 1 250); do
    if [ -f "$profile/DevToolsActivePort" ]; then
      p="$(head -1 "$profile/DevToolsActivePort")"
      if curl -s -m 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
        dev="$p"; break
      fi
    fi
    sleep 0.1
  done
  if [ -z "$dev" ]; then
    printf '\033[33m  Chrome devtools never answered\033[0m\n'; reap; RC=77; return 77
  fi

  cat >"$out/env.json" <<EOF
{"url": "$url", "devtools": $dev,
 "srcRoom": "$SRC_ROOM", "srcName": "$SRC_NAME", "mission": "$MISSION",
 "sidecar": "$root/fixture-holodeck"}
EOF
  "$NODE" "$HERE/duplicate-drive.js" "$out" >"$out/drive.out" 2>&1
  RC=$?
  cat "$out/drive.out"
  if [ -s "$out/worker-shim.log" ]; then
    printf '\033[31m  A WORKER WAS SPAWNED — this rig must spend nothing:\033[0m\n'
    sed -n '1,5p' "$out/worker-shim.log"
    [ "$RC" -eq 0 ] && RC=1
  fi
  reap
  return $RC
}

# ── the product ─────────────────────────────────────────────────────────────
product_run() {
  say "S172 — ⧉ Duplicate, in real headed Chrome, on a REAL-LENGTH program name"
  note "artifacts: $WORK"
  run_once "the product" "${WEB_UNDER_TEST:-$REPO/web}" "$WORK/product"
  local rc=$?
  printf '\n'
  case "$rc" in
    0) printf '\033[32mPROVEN\033[0m — the captain can duplicate a locked program whose name is his\n'
       printf '  whole idea sentence, twice — once from its CARD and once from the control\n'
       printf '  inside the LOCKED PROGRAM'"'"'S OWN CHAT PANE — into two rooms of their own\n'
       printf '  that really hold his mockup, concept doc and attachments; the filed one is\n'
       printf '  untouched; no two cards on the deck read the same name; and each card says\n'
       printf '  which program it came from in words that fit on the screen.\n'
       printf '  screenshots: %s/product/*.png — OPEN THEM AND LOOK.\n' "$WORK"
       printf '  measurements: %s/product/duplicate-check.json\n' "$WORK" ;;
    77) printf '\033[33mSKIPPED\033[0m — infrastructure, nothing proven.\n' ;;
    *) printf '\033[31mFAILED\033[0m — see %s/product/duplicate-check.json\n' "$WORK" ;;
  esac
  return $rc
}

# ── the red controls: a COPY of web/, each broken ONE way ───────────────────
# Every variant must fail, AND it must fail on the check it breaks. "The run was
# non-zero" is not a control going red: this rig's ancestor printed "every
# control went red" over four worthless proofs, all of which had failed on the
# harness's own precondition line.
# $2 is the variant ROOT: the daemon is served out of `$2/web`, and `$2/docs`
# carries the shared token stylesheet — `server.py` resolves `/lcars.css` two
# levels up from its own module, so a copy of web/ alone is served WITHOUT the
# palette and every measurement taken off it is a phantom. (The driver's
# stylesheet precondition caught exactly that, which is what it is for.)
make_variant() {   # $1 = name, $2 = variant root
  local name="$1" root="$2" dest="$2/web"
  rm -rf "$root"; mkdir -p "$dest" "$root/docs"
  cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$dest/" 2>/dev/null
  cp "$REPO/docs/lcars.css" "$root/docs/lcars.css" 2>/dev/null ||
    { printf '  no docs/lcars.css to copy\n'; return 1; }
  rm -rf "$dest/lcars_serve/__pycache__"
  local css="$dest/static/board.css" js="$dest/static/board.js"
  local acts="$dest/lcars_serve/actions.py"
  case "$name" in
    room-not-differentiated)
      # D1 VERBATIM — the room goes back to being slugged out of the DISPLAY
      # name, so on any name at the cap every candidate is the source's own room
      # and the blank-name road runs out of names with zero copies in existence.
      "$PY" - "$acts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''def _duplicate_room(name, n):
    """The room the `n`th copy of a program called `name` lives in."""
    return _room_with_marker(name, "copy" if n <= 1 else "copy-%d" % n)'''
new = '''def _duplicate_room(name, n):
    """RED CONTROL (duplicate.sh --calibrate): D1 verbatim."""
    return _slug("%s (copy)" % name if n <= 1 else "%s (copy %d)" % (name, n))'''
assert old in s, "the _duplicate_room the control patches has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    chip-clipped)
      # D3 VERBATIM — the shipped rule, restored. The chip keeps a perfect box
      # and a perfectly resolved colour and simply does not fit.
      printf '\n/* RED CONTROL (duplicate.sh --calibrate): D3 verbatim. */\n.prog .prow .pdup{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:14ch}\n' >>"$css"
      ;;
    no-duplicate-control)
      # the control gone from the card entirely — the S172 defect one step
      # further back, and the thing every other check here depends on.
      "$PY" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    prow.appendChild(applyWriteState(holoBtn("⧉ Duplicate", "small",
                                             function () {
      holoConfirmDuplicate(p);
    })));'''
assert old in s, "the ⧉ Duplicate control the control patches has moved"
open(p, "w").write(s.replace(old, "    /* RED CONTROL: no ⧉ Duplicate on the card. */"))
PY
      ;;
    second-copy-overwrites)
      # THE BLANK ROAD HANDS BACK THE FIRST COPY'S ROOM every time, so the
      # second copy is written straight over the first and the deck shows ONE.
      #
      # FIX ROUND 2 MOVED THIS CONTROL, and the move is a finding. It used to
      # break `_claim_room` alone ("the room is taken and it says yes") — and
      # after N1 that no longer reaches the deck: the name walk in front of the
      # claim now sees "X (copy)" is already a card, moves to "X (copy 2)", and
      # hands out a free room before the broken claim is ever asked. The variant
      # came back 9/9 GREEN on a product whose room claim was a lie. So the
      # break is taken at the ROAD, where the check's own claim lives: whatever
      # guards exist, two duplicates must not land in one room. (`_claim_room`
      # itself is still covered, headlessly and deterministically, by
      # `DuplicateRoomIsCLAIMEDNotJustCheckedTest` — this rig is not where a
      # race is proven.)
      "$PY" - "$acts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''        base = self._DUPLICATE_SUFFIX.sub("", str(source_name or "").strip())
        base = base or "Program"
        n = 1'''
new = '''        base = self._DUPLICATE_SUFFIX.sub("", str(source_name or "").strip())
        base = base or "Program"
        # RED CONTROL: every copy is given the FIRST copy's room, taken or not.
        os.makedirs(os.path.join(sidecar, _duplicate_room(base, 1)),
                    exist_ok=True)
        return "%s (copy)" % base, _duplicate_room(base, 1)
        n = 1'''
assert old in s, "_claim_duplicate_room has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    source-loses-its-lock)
      # the original MUTATED by the copy: its own record loses the hand-off
      # line, so the design a mission was briefed on stops reading as filed.
      "$PY" - "$acts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        self._mark_basis_inherited(new_dir, src_name)"
new = ('''        # RED CONTROL (duplicate.sh --calibrate): the SOURCE is mutated.
        try:
            _sp = os.path.join(src_dir, _TRANSCRIPT)
            with open(_sp) as _fh:
                _t = _fh.read()
            with open(_sp, "w") as _fh:
                _fh.write(_SENT_LINE.sub("", _t))
        except OSError:
            pass
''' + old)
assert old in s, "the duplicate road has been restructured"
open(p, "w").write(s.replace(old, new, 1))
PY
      ;;
    copy-drops-the-design)
      # FIX ROUND 2, PROBE A VERBATIM — the round-2 tester's own break, which
      # the committed rig passed 7/7. The copy road silently drops the design:
      # the new room holds `basis.md` and `transcript.md` and nothing else,
      # while the dialog goes on promising it "carries the mockup, the concept
      # doc, anything you pasted in".
      "$PY" - "$acts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''        return name in (self._HANDOFF_DERIVE_FILE,
                        self._HANDOFF_DERIVE_FILE + ".tmp")'''
new = '''        if name in ("mockup.html", "concept.md", "attachments"):
            return True     # RED CONTROL: the copy carries no design at all
        return name in (self._HANDOFF_DERIVE_FILE,
                        self._HANDOFF_DERIVE_FILE + ".tmp")'''
assert old in s, "the duplicate deny-list has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    copy-keeps-the-parents-name)
      # FIX ROUND 2, PROBE B VERBATIM — three cards on the deck all reading one
      # name, which is what the daemon's own 409 calls "a pair you cannot tell
      # apart". The committed rig passed this 7/7 as well.
      #
      # BROKEN AT THE WRITE, not at the naming walk. Patching the walk to hand
      # back the parent's name no longer reaches the deck at all: fix round 2's
      # name check refuses it there and the road 409s, so the variant went red
      # on somebody else's checks and proved nothing (`judge_control` caught
      # exactly that, which is what it is for). The name that reaches the CARD
      # is the one `_write_duplicate_record` puts in the copy's own record, so
      # that is where a product with no working name guard differs.
      "$PY" - "$acts" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''        if not self._write_duplicate_record(new_dir, new_name, src_room,
                                            src_name, mission, when):'''
new = '''        # RED CONTROL: the copy is recorded under its PARENT'S name.
        if not self._write_duplicate_record(new_dir, src_name, src_room,
                                            src_name, mission, when):'''
assert old in s, "the duplicate record write has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    no-continuing-chip)
      # D7's control: the chat header stops saying whose conversation the pane
      # is holding. The banner is transient, so after one refresh a duplicate's
      # inherited history reads as this program's own work.
      "$PY" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# ANCHORED ON THE CHIP ITSELF: the same guard opens the CARD's lineage chip a
# few hundred lines up, so the condition alone matches twice.
old = ("  if (p.duplicatedFrom && p.duplicatedFrom.room) {\n"
       "    var cont = el(\"span\", \"cont-chip\",")
new = ("  if (false) {   /* RED CONTROL */\n"
       "    var cont = el(\"span\", \"cont-chip\",")
assert s.count(old) == 1, "the chat header's lineage chip has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    lock-hatch-still-disabled)
      # FIX ROUND 3, THE DEFECT VERBATIM — S127's placeholder, restored exactly
      # as it shipped and exactly as it survived S172: the paragraph stops at
      # "read-only", and the hatch below it is greyed out saying the feature is
      # not built and he should start a new program under a different name.
      # This is what the captain opened his own locked program and found.
      "$PY" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    lock.appendChild(el("p", null,
      "⧉ Duplicate is the way on: it opens a NEW program carrying this one's "
      + "mockup, concept doc and whole conversation, editable from the first "
      + "turn — and this one stays exactly as it was handed over."));'''
assert old in s, "the lock band's way-on paragraph has been restructured"
s = s.replace(old, "    /* RED CONTROL: S127's pane, verbatim. */")
old2 = '''    lock.appendChild(applyWriteState(holoBtn(
      "⧉ Duplicate to keep designing", "small", function () {
        holoConfirmDuplicate(p);
      })));'''
new2 = '''    lock.appendChild(applyWriteState(holoBtn(
      "⧉ Duplicate to keep designing", "small", null,
      "Not built yet. To carry on from here, start a new program under a "
      + "different name — this one stays exactly as it was handed over.")));'''
assert old2 in s, "the lock band's ⧉ Duplicate control has been restructured"
open(p, "w").write(s.replace(old2, new2))
PY
      ;;
    lock-hatch-dead-click)
      # THE OTHER HALF, AND THE MORE FLATTERING FAILURE: the control is live,
      # painted and worded perfectly, and does NOTHING when clicked. Exactly the
      # shape `holoCtl`'s own contract forbids, and the shape a check that only
      # LOOKS at the pane would call proven.
      "$PY" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    lock.appendChild(applyWriteState(holoBtn(
      "⧉ Duplicate to keep designing", "small", function () {
        holoConfirmDuplicate(p);
      })));'''
new = '''    lock.appendChild(applyWriteState(holoBtn(
      "⧉ Duplicate to keep designing", "small", function () {
        /* RED CONTROL (duplicate.sh --calibrate): a live control that does
           nothing when clicked. */
      })));'''
assert old in s, "the lock band's ⧉ Duplicate control has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    chip-says-grounded)
      # THE ONE A HEADLESS TEST IS BLIND TO IN THE OTHER DIRECTION: the daemon
      # is perfect and says `basisInherited`, and the front end goes on printing
      # "grounded in <repo>" over a basis that came with a copy.
      "$PY" - "$js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''      p.basisInherited ? "▣ inherited grounding — may be stale"
        : "▣ grounded in " + holoRepoName(),'''
new = '''      "▣ grounded in " + holoRepoName(),   /* RED CONTROL */'''
assert old in s, "the grounding chip has been restructured"
open(p, "w").write(s.replace(old, new))
PY
      ;;
    *) return 1 ;;
  esac
}

# WHICH CHECK EACH CONTROL OWNS. A variant that fails on somebody else's check
# has not proven its own, and is reported as inconclusive rather than green.
control_signature() {   # $1 = variant → the check id it must turn red
  case "$1" in
    room-not-differentiated) echo "DUP-BLANK-NAME-WORKS" ;;
    chip-clipped)            echo "LINEAGE-CHIP-READABLE" ;;
    no-duplicate-control)    echo "DUP-CONTROL-ON-LOCKED-CARD" ;;
    lock-hatch-still-disabled) echo "LOCK-PANE-DUPLICATE-IS-LIVE" ;;
    lock-hatch-dead-click)   echo "LOCK-PANE-DUPLICATE-WORKS" ;;
    second-copy-overwrites)  echo "DUP-TWO-DISTINCT-ROOMS" ;;
    copy-drops-the-design)   echo "COPY-CARRIES-THE-SOURCES-FILES" ;;
    copy-keeps-the-parents-name) echo "NO-TWO-CARDS-ONE-NAME" ;;
    source-loses-its-lock)   echo "SOURCE-STAYS-SENT" ;;
    chip-says-grounded)      echo "INHERITED-GROUNDING-SAID-ON-SCREEN" ;;
    no-continuing-chip)      echo "CONTINUING-CHIP-ON-SCREEN" ;;
  esac
}

judge_control() {   # $1 = variant, $2 = its out dir → 0 if it went red for ITS reason
  "$PY" - "$(control_signature "$1")" "$2/duplicate-check.json" <<'PY'
import json, sys
want, path = sys.argv[1], sys.argv[2]
try:
    got = json.load(open(path))
except Exception as exc:
    print("      the control produced no measurements (%s)" % exc)
    sys.exit(1)
failed = [c["id"] for c in got.get("checks", []) if not c["ok"]]
if want not in failed:
    print("      it did NOT turn %s red. failed instead: %s" % (want, failed or "nothing"))
    sys.exit(1)
detail = [c["detail"] for c in got.get("checks", []) if c["id"] == want][0]
print("      %s went red: %s" % (want, detail[:150]))
sys.exit(0)
PY
}

VARIANTS="${LCARS_DUP_VARIANTS:-room-not-differentiated chip-clipped no-duplicate-control lock-hatch-still-disabled lock-hatch-dead-click second-copy-overwrites copy-drops-the-design copy-keeps-the-parents-name source-loses-its-lock chip-says-grounded no-continuing-chip}"

calibrate_run() {
  say "RED CONTROLS — can any of these checks actually go red?"
  note "artifacts: $WORK"
  local rc=0 v
  for v in $VARIANTS; do
    if ! make_variant "$v" "$WORK/variant-$v"; then
      printf '\n\033[33mCONTROL CANNOT RUN\033[0m — the "%s" patch did not apply.\n' "$v"
      printf '  the code it patches has been restructured; update %s.\n' "$0"
      return 77
    fi
    run_once "CONTROL: $v (must FAIL on $(control_signature "$v"))" \
             "$WORK/variant-$v/web" "$WORK/out-$v" >"$WORK/log-$v.txt" 2>&1
    local r=$?
    if [ "$r" -eq 77 ]; then
      printf '  \033[33m→ %s skipped (infrastructure) — nothing proven\033[0m\n' "$v"
      sed -n '1,15p' "$WORK/log-$v.txt"
      [ "$rc" -eq 0 ] && rc=77
    elif [ "$r" -eq 0 ]; then
      printf '  \033[31m→ %s PASSED a broken product. The check is decoration.\033[0m\n' "$v"
      sed -n '1,40p' "$WORK/log-$v.txt"
      rc=1
    elif judge_control "$v" "$WORK/out-$v"; then
      printf '  \033[32m→ %s went RED, on its own check\033[0m\n' "$v"
    else
      printf '  \033[31m→ %s failed for the WRONG REASON — inconclusive.\033[0m\n' "$v"
      rc=1
    fi
  done
  printf '\n'
  case "$rc" in
    0) printf '\033[32mCALIBRATED\033[0m — every control went red FOR ITS OWN CHECK. In particular\n'
       printf '  the two defects this round cured go red here: the room derived from the\n'
       printf '  display name (D1) and the chip clipped to 14ch (D3) — and so do the two\n'
       printf '  breaks the ROUND-2 TESTER made that this rig once passed 7/7: a copy that\n'
       printf '  carries no design, and a copy that keeps its parent'"'"'s name. And the one\n'
       printf '  the CAPTAIN found in a minute, which this rig once passed 9/9: S127'"'"'s\n'
       printf '  disabled hatch left standing in the locked program'"'"'s own chat pane.\n' ;;
    77) printf '\033[33mCONTROLS SKIPPED\033[0m — nothing proven.\n' ;;
    *) printf '\033[31mCONTROLS FAILED\033[0m — see above; logs in %s\n' "$WORK" ;;
  esac
  return $rc
}

case "$MODE" in
  product)               product_run; exit $? ;;
  --calibrate|calibrate) calibrate_run; exit $? ;;
  --all|all)
    product_run; P=$?
    printf '\n'
    calibrate_run; C=$?
    [ "$P" -eq 0 ] && [ "$C" -eq 0 ] && exit 0
    { [ "$P" -eq 77 ] || [ "$C" -eq 77 ]; } && exit 77
    exit 1 ;;
  *) printf 'usage: %s [--calibrate|--all]\n' "$0"; exit 2 ;;
esac
