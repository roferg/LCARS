#!/usr/bin/env python3
"""THE DECLARED JOURNEY — walk the flow, don't teleport (S220 part F).

WHY THIS EXISTS. On 2026-09-19 Number One looked at a six-screen build by
typing four addresses into the bar: it never clicked a control, never typed an
insight, never watched a value carry from one screen to the next. Everything
that only shows up while WALKING — a button on a screen no address was guessed
for, a month that changes between the card that offers it and the step that
collects it — was invisible to it, and it graded the build anyway.

Two runs of the same code on the same build then differed: one clicked, one
teleported. A walk left to the model's discretion is a LOTTERY, and a lottery
cannot be a proof. So the journey is DECLARED — built here, from the record —
and the driver executes it step by step.

THE RECORD, AND ONLY THE RECORD. Three sources, in this order:

  · the DRAWING's screen order — the screens the captain drew, in the order he
    drew them, and each screen's OWN forward control;
  · the PRD's own words — a criterion that says "the Preview button navigates
    to …" is the record naming a step, including steps for screens the drawing
    never drew;
  · the fields and gates the screens themselves carry — a free-text field is
    something a person fills, a lock/publish/submit control is a gate, and a
    gate is checked BOTH ways (it must refuse while the thing it waits for is
    blank, and open once it is filled).

Nothing here guesses at a flow. A mission whose record says nothing produces
an empty journey and the look is exactly what it was before.

Usage:
  xo-journey.py build --criteria <criteria.json> [--drawing <drawing-parts.json>]
                      [--drawing-html <the drawing itself>] [--prd <prd.md>]
                      --out <journey.json> [--criteria-out <criteria.json>]
  xo-journey.py carry --walk <walk.json> --out <observations-fragment.json>
"""

import html as html_mod
import json
import os
import re
import sys

# 12, not 10, since fix round 1 D6 added the whole-form fill: the real
# benchmark journey is 10 steps with it and the cap must not be what decides
# the gate never gets tried.
STEP_CAP = 12
TYPED_TEXT = "Number One typed this to see it carry"

FORWARD = re.compile(r"^(continue|start|next|go|open|begin|proceed|pull|create|"
                     r"add|new|enter|build|review|preview|publish|finish|done)\b", re.I)
BACKWARD = re.compile(r"^(cancel|back|discard|close|delete|remove|reset|undo|"
                      r"sign out|log out|toggle|theme|help|skip)\b", re.I)
GATE = re.compile(r"\b(lock|publish|submit|save|confirm|send|finish|complete|post)\b", re.I)
RETURN = re.compile(r"^(back|return|close|done|exit)\b", re.I)
SCREEN_ID = re.compile(r"^(?:screen[-_]?(.+)|(.+?)[-_]screen)$", re.I)
TYPEABLE = ("textarea", "input")
MONTH = re.compile(r"\b(january|february|march|april|may|june|july|august|"
                   r"september|october|november|december)\s+(20\d\d)\b", re.I)

# ── A KEY IS A CONTROL (S221 fix 7) ────────────────────────────────────────
#
# WHY THIS EXISTS. On 2026-09-20 this planner read a PRD that says, in plain
# English and twice, "walk the character around the village with the arrow
# keys" and "updates live as they walk" — and emitted `"steps": []`. It was not
# wrong by its own lights: all three of its sources are about CLICKING, and its
# whole vocabulary is buttons, forms, screens and gates. A canvas game has no
# named controls, no screens and no fields, so it correctly found nothing by a
# definition of "flow" that never imagined a keyboard. The walk that night
# happened because the model improvised, and a guarantee that depends on the
# model's willingness is not a guarantee: a lazier one grades a still frame and
# is correct by the machinery's lights.
#
# WHAT COUNTS AS THE RECORD NAMING A KEY. Both halves, in ONE sentence:
#   (a) a key NAMED from the closed list below — "the arrow keys", "ArrowUp",
#       "WASD", "F3", "the Enter key", "press Escape". Never a bare English
#       word: `Return`, `Space`, `Tab`, `Delete` and the single letters only
#       count next to the word "key" or a press verb, because they are ordinary
#       prose everywhere else.
#   (b) a RESPONSE verb tying the BUILD to that key in the same sentence —
#       walk, move, drive, steer, navigate, toggle, press, hold, respond,
#       switch, open, close, trigger.
#
# WHAT IT DELIBERATELY WILL NOT MATCH, and these are the rows the tests pin:
#   · a sentence that names a key and then DENIES the build responds to it.
#     This PRD's own "so you see it without pressing any key" is the trap, and
#     it is one `without pressing` away from inventing a walk out of a sentence
#     that says the opposite.
#   · anything under `## Out of Scope`. That section is about what NOT to
#     change — "leave its F3 toggle exactly as they are" names a key in a
#     sentence whose whole point is to stay away from it.
#   · a key mentioned with no response verb at all: "the keyboard shortcut is
#     documented in README" names nothing this can walk.
#
# Three rounds in this repo have been lost to a regex reading the captain's own
# prose (S147, S156, S188), and the captain writes PRDs ABOUT the things being
# parsed. So this is the narrowest rule that covers the case, both halves are
# required, and the misses are encoded as tests so a flattering number cannot
# drift into a looser one.

# The arrow keys and WASD, named as a set. These are MOVEMENT.
ARROWS_SET = re.compile(r"\barrow[\s-]?keys\b", re.I)
WASD_SET = re.compile(r"\b(wasd|w\s*/\s*a\s*/\s*s\s*/\s*d|w,\s*a,\s*s,\s*d)\b", re.I)
# One named arrow, spelled the way a key event spells it.
ARROW_ONE = re.compile(r"\bArrow(Up|Down|Left|Right)\b")
# A function key. Unambiguous enough to stand alone — but the response verb is
# still required, so "F3" in a spreadsheet sense cannot become a step.
FKEY = re.compile(r"\bF(1[0-2]|[1-9])\b")
# The word-like keys, which are ordinary English and therefore only count when
# the sentence says they are KEYS: "the Enter key", "press Escape", "hold Tab".
WORD_KEYS = "enter|return|escape|esc|tab|space|spacebar|backspace|delete|shift"
NAMED_KEY = re.compile(r"\b(?:the\s+)?(%s)\s+key\b" % WORD_KEYS, re.I)
PRESSED_KEY = re.compile(r"\b(?:press|presses|pressing|hit|hits|hold|holds|holding)\s+"
                         r"(?:the\s+|and\s+hold\s+)?(%s)\b" % WORD_KEYS, re.I)
# The build DOING something because of the key. Without one of these a sentence
# merely mentions a key.
RESPONDS = re.compile(r"\b(walk|walks|walking|move|moves|moving|drive|drives|driving|"
                      r"steer|steers|steering|navigat\w*|toggle\w*|press\w*|hold|holds|holding|"
                      r"respond\w*|switch\w*|open|opens|close|closes|trigger\w*|scroll\w*)\b", re.I)
# THE VETO. Any of these in the sentence and it is not a step, whatever else it
# says. `without pressing` is this very mission's own trap.
KEY_VETO = re.compile(r"\bwithout\s+(?:pressing|holding|touching|using|having)|"
                      r"\bno\s+need\s+to\s+press|"
                      r"\bdoes\s+not\s+(?:respond|require|need|use)|"
                      r"\bnever\s+(?:press|respond|move)|"
                      r"\bmust\s+not\b|\bdo\s+not\s+(?:add|change|touch)|"
                      r"\bleave\s+.{0,40}\bas\s+(?:they|it)\s+(?:are|is)\b|"
                      r"\bout\s+of\s+scope\b", re.I)
# The movement words — which keys get HELD (see key_steps).
MOVEMENT = re.compile(r"\b(walk\w*|mov\w*|driv\w*|steer\w*|run\w*|scroll\w*)\b", re.I)
SENTENCE = re.compile(r"[^.!?\n]+[.!?\n]?")
# A movement key is held long enough to travel: the example game moves at
# 128px/s, so 250ms is one 32px tile. A tap moves it ~2px and is
# indistinguishable from a dead key — which is the false DIDN'T-WORK this
# whole session exists to stop.
MOVE_HOLD_MS = 250
KEY_STEP_CAP = 3

# A criterion naming a control and what it leads to: the PRD's own step.
NAMED_ROUTE = re.compile(
    r"(?:the\s+)?[\"'“]?([A-Z][A-Za-z0-9 &'\-]{1,28}?)[\"'”]?\s+"
    r"(?:button|link|tab|control)\s+"
    r"(?:navigates?|opens?|goes|takes|shows|renders|enters|leads)")


def load(path, default=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        return default


def norm(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()


def low(s):
    return norm(s).lower()


# ── A REQUIREMENT NAMES A STEP WHEN NOBODY DREW ONE (Number One) ────────────
#
# WHY THIS EXISTS. Measured across six runs on 2026-09-23/24: the two missions
# with NO drawing attempted the LEAST work and both PASSED, while every defect
# found came from a mission that HAD a drawing. The walk planner reads the
# drawing to learn what screens and controls exist; with no drawing it had
# almost nothing to build steps from and collapsed to "I couldn't set it up".
#
# THE RULE. When there is no drawing to walk, a person promise that names
# something DOABLE — an ACTION verb performed on the build — becomes a real
# step, aimed at whatever the requirement names. "A player can pause the game"
# names an action (pause) and a target (the game): enough to click toward.
# A promise that names no action at all ("The header shows the project name")
# is display-only — there is nothing to DO — and stays an honest miss.
#
# The verbs are person-performed actions only. Bare display words (show, list,
# display, render, appear) are deliberately absent: a walk is about DOING, and
# a screen that merely shows something is checked by looking, not by acting.
ACTION_VERB = re.compile(
    r"\b(open|close|pause|resume|start|stop|play|walk|move|"
    r"add|create|delete|remove|clear|save|load|submit|send|post|"
    r"lock|unlock|preview|publish|confirm|cancel|select|choose|pick|"
    r"toggle|switch|enter|search|filter|sort|edit|update|rename|"
    r"drag|drop|press|click|tap|navigate|return|reveal|expand|collapse|"
    r"mark|complete|finish|reset|rest|assign|attach|upload|download)"
    r"(?:s|es)?\b", re.I)
# Where the object of the action ends: the prepositions and conjunctions that
# begin the NEXT clause, or any sentence punctuation.
OBJ_END = re.compile(r"\b(?:from|when|so|and|then|but|because|until|while|"
                     r"to|on|in|onto|into|over|with|after|before|if|that)\b|[.,;:!?\u2014]")


def requirement_steps(person):
    """Steps derived from the requirements when there is no drawing to walk.

    One step per person promise that names something DOABLE — an action verb on
    a target. The step is a CLICK aimed at what the requirement names (the verb
    itself, since buttons are usually labelled with it, and the object phrase),
    and it RECORDS, at birth, that it was derived from the requirement and which
    promise it serves. A promise with no action verb produces nothing here and
    stays an honest miss for the coverage pass to record.
    """
    out = []
    for c in person:
        text = norm(c.get("text"))
        m = ACTION_VERB.search(text)
        if not m:
            continue
        verb = low(m.group(1))
        rest = text[m.end():]
        obj = OBJ_END.split(rest, 1)[0]
        obj = re.sub(r"^\s*(?:the|a|an|their|his|her|its|your|this|that)\s+",
                     " ", obj, flags=re.I)
        obj = norm(obj)
        match = []
        if obj and low(obj) != verb:
            match.append(obj)
        match.append(verb)
        out.append({
            "do": "click", "match": match,
            "promiseId": str(c.get("id") or ""),
            "name": "do what the requirement says: %s" % (text[:80]),
            "expect": "the build lets me %s%s"
                      % (verb, (" the " + obj) if obj else ""),
            "why": "no drawing was given, so this step is derived from the "
                   "requirement: %s" % text[:120]})
    return out


TAGS = re.compile(r"<(button|a|textarea|input|select)\b([^>]*)>(.*?)</\1>|<(input)\b([^>]*?)/?>",
                  re.I | re.S)
SCREEN_TAG = re.compile(r"<[a-z][a-z0-9]*\b[^>]*\bid=[\"']((?:screen[-_][^\"']+)|(?:[^\"']+[-_]screen))[\"'][^>]*>",
                        re.I)


def strip_tags(s):
    # `&amp;` is not a label. A drawing writes "Pull data &amp; start" and the
    # button on the screen says "Pull data & start"; matching the first against
    # the second finds nothing, and the step reads "unreachable" about a button
    # that is right there.
    return norm(html_mod.unescape(re.sub(r"<[^>]+>", " ", s or "")))


def attr(blob, name):
    m = re.search(r"\b%s=[\"']([^\"']*)[\"']" % name, blob or "", re.I)
    return norm(html_mod.unescape(m.group(1))) if m else ""


def screens_from_html(path):
    """The drawing's screens IN THE ORDER IT DRAWS THEM, read from its source.

    WHY NOT FROM THE RENDERED DRAWING. A holodeck drawing stacks its screens in
    one file and hides all but the first (`display:none`), and a browser does
    not report an element it is not painting — so the rendered parts pass sees
    exactly ONE screen and the flow through the other five is invisible to it.
    The file itself says the order plainly, so it is read from there: every
    element whose id names a screen, in source order, and the controls written
    inside it.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            html = fh.read()
    except Exception:
        return []
    marks = [(m.start(), m.group(1)) for m in SCREEN_TAG.finditer(html)]
    if len(marks) < 2:
        return []
    out = []
    for i, (at, sid) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(html)
        chunk = html[at:end]
        parts = []
        for m in TAGS.finditer(chunk):
            tag = (m.group(1) or m.group(4) or "").lower()
            blob = m.group(2) or m.group(5) or ""
            inner = strip_tags(m.group(3) or "")
            name = attr(blob, "aria-label") or inner or attr(blob, "placeholder") or attr(blob, "value")
            parts.append({"name": name, "tag": tag,
                          "role": attr(blob, "role"),
                          "id": attr(blob, "id") or None,
                          "interactive": True,
                          "index": len(parts) + 1})
        m = SCREEN_ID.match(sid)
        heads = [strip_tags(h.group(1)) for h in
                 re.finditer(r"<h[1-3][^>]*>(.*?)</h[1-3]>", chunk, re.I | re.S)][:3]
        out.append({"id": sid, "name": norm((m.group(1) or m.group(2)) if m else sid),
                    "headings": [h for h in heads if h], "parts": parts})
    return out


def screens_of(drawing):
    """The drawing's screens, in the order it draws them, each with its parts.

    A drawing is ONE page with the screens stacked down it (that is how the
    holodeck draws them), so a screen is a container whose id says `screen-…`
    and its parts are the ones that follow it in DOM order until the next one.
    """
    parts = [p for p in (drawing or {}).get("parts") or [] if isinstance(p, dict)]
    marks = []
    for p in parts:
        m = SCREEN_ID.match(str(p.get("id") or ""))
        if m and p.get("container"):
            marks.append((int(p.get("index") or 0), m.group(1) or m.group(2), p))
    marks.sort()
    out = []
    for i, (idx, name, p) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else 10 ** 9
        members = [q for q in parts
                   if idx < int(q.get("index") or 0) < end]
        out.append({"id": p.get("id"), "name": norm(name), "parts": members})
    return out


def controls(members):
    return [p for p in members
            if p.get("interactive") and norm(p.get("name"))
            and str(p.get("tag") or "").lower() not in ("select", "textarea")
            and not (str(p.get("tag") or "").lower() == "input"
                     and str(p.get("role") or "") != "button")]


def forward_control(members, next_name, prd_text):
    best, best_score = None, -99
    for i, c in enumerate(controls(members)):
        name = norm(c.get("name"))
        score = 0
        if next_name and next_name.lower() in name.lower():
            score += 6
        if FORWARD.match(name):
            score += 4
        if BACKWARD.match(name):
            score -= 8
        # A GATE IS NOT A DOOR. "Publish board" and "Open the board" both say
        # "board" and both start with a forward verb, but one of them ENDS the
        # flow and the other continues it — and the gate already has two steps
        # of its own. Measured on the S220 fixture, where the tie sent the walk
        # into Publish and the second screen was never reached.
        if GATE.search(name):
            score -= 3
        if name.lower() in prd_text:
            score += 2
        score -= i * 0.01           # a tie goes to the one drawn first
        if score > best_score:
            best, best_score = c, score
    return best if best_score > 0 else None


def typeables(members):
    out = []
    for p in members:
        tag = str(p.get("tag") or "").lower()
        if tag == "textarea" or (tag == "input" and str(p.get("role") or "") != "button"):
            out.append(p)
    return out


def gate_control(members):
    for c in controls(members):
        if GATE.search(norm(c.get("name"))):
            return c
    return None


def prd_prose(path):
    """The PRD's own words, MINUS `## Out of Scope`.

    That section exists to say what not to change, so every key it names is a
    key to stay away from. Dropping it whole is cheaper and far safer than
    trying to read intent out of each of its sentences.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except Exception:
        return ""
    out, skipping = [], False
    for line in raw.splitlines():
        if line.lstrip().startswith("#"):
            skipping = bool(re.search(r"out\s+of\s+scope|non[- ]goals?", line, re.I))
        if not skipping:
            out.append(line)
    # UNWRAP THE PARAGRAPHS FIRST. A PRD is hard-wrapped at about eighty
    # columns, so "walk the character around the village with the" ends one
    # line and "arrow keys" begins the next — and a sentence splitter that
    # treats a newline as a full stop sees a verb with no key followed by a key
    # with no verb, and matches neither. Measured on this mission's own PRD:
    # unwrapped it found F3 and nothing else. A blank line, a bullet and a
    # heading are real boundaries and stay; a bare wrap is joined.
    joined, buf = [], []
    for line in out:
        st = line.strip()
        if not st or st.startswith(("-", "*", "#", "|", "```")) or re.match(r"^\d+[.)]\s", st):
            if buf:
                joined.append(" ".join(buf)); buf = []
            joined.append(line)
        else:
            buf.append(st)
    if buf:
        joined.append(" ".join(buf))
    return "\n".join(joined)


def key_steps(sentences):
    """Steps for the keys the RECORD names, and only those.

    One sentence at a time, because the veto has to sit next to the key it
    vetoes: read the whole document as one blob and "without pressing any key"
    is three paragraphs away from "with the arrow keys" and cancels nothing.
    """
    found, why = [], []
    for raw in sentences:
        sent = norm(raw)
        if not sent or not RESPONDS.search(sent) or KEY_VETO.search(sent):
            continue
        moving = bool(MOVEMENT.search(sent))
        keys = []
        # MOVEMENT SETS. "the arrow keys" is the record naming a way to walk,
        # so it becomes a walk on BOTH axes — one step is not enough to show a
        # readout tracks a player, since a column that moves and a row that
        # does not is exactly the half-working build this must catch.
        if ARROWS_SET.search(sent):
            keys += [("ArrowRight", True), ("ArrowDown", True)]
        if WASD_SET.search(sent):
            keys += [("d", True), ("s", True)]
        for m in ARROW_ONE.finditer(sent):
            keys.append(("Arrow" + m.group(1), True))
        for m in FKEY.finditer(sent):
            keys.append((m.group(0).upper(), False))
        for rx in (NAMED_KEY, PRESSED_KEY):
            for m in rx.finditer(sent):
                name = m.group(1).lower()
                keys.append(({"esc": "Escape", "return": "Enter",
                              "spacebar": "Space"}.get(name, name.title()), False))
        if not keys:
            continue
        for name, is_move in keys:
            # THE HOLD RULE. A key the record ties to MOVEMENT is held, because
            # a build that moves continuously moves ~2px on a tap and looks
            # broken. Everything else is a tap: holding Enter or F3 is not what
            # a person does and repeat-fires on some builds.
            hold = MOVE_HOLD_MS if (is_move and moving) else 0
            found.append({
                "do": "press", "pressKey": name, "hold": hold,
                "times": 3 if hold else 1, "match": [],
                "name": ("hold %s and watch what changes" % name) if hold
                        else ("press %s and watch what changes" % name),
                "expect": "the screen answers the key — whatever the record says "
                          "follows it is different afterwards",
                "why": "the record names this key: %s" % sent[:140]})
        why.append("the keys the record names")
    # De-duplicated on the key itself, longest hold wins, and capped so a
    # chatty record cannot fill the journey with keystrokes.
    best = {}
    for st in found:
        cur = best.get(st["pressKey"])
        if not cur or st["hold"] > cur["hold"]:
            best[st["pressKey"]] = st
    return list(best.values())[:KEY_STEP_CAP], (why[:1] if found else [])


# ── THE CRITERIA ARE THE FLOOR AND THE CEILING (S226) ──────────────────────
#
# WHY THIS EXISTS. On 2026-09-23 a single save-slot panel — one screen, no
# `screen-*` container — produced ONE walk step: the Escape key read out of the
# PRD prose. screens_of found nothing, so the whole fill/gate machinery never
# ran, and five of the six things the PRD says a PLAYER can do were never
# attempted. The grader then reported on all six as though it had. The walk was
# SCRAPED — whatever fell out of the sources is what got walked — and nothing
# asked the one question that matters: "did I attempt the things I am going to
# be graded on?"
#
# THE RULE. The person's own acceptance list is the FLOOR: every criterion a
# person could check gets an attempt, or a recorded reason it could not be set
# up. It is also the CEILING: an attempt is only ever made for a control a
# criterion NAMES, so this can never degenerate into clicking everything on the
# screen. A control nothing names is never touched. A criterion whose control
# is not on the screen is recorded WITH the reason — never papered over with a
# step that does nothing, which is the exact failure this project keeps undoing.

# The ubiquitous words a criterion and a step both use no matter WHAT they are
# about. Two steps that share only these have nothing real in common, so they
# are struck before the token overlap that links a criterion to the step that
# attempted it. Domain nouns ("panel", "slot", "save", "month") are kept —
# THEY are what makes a match mean something.
COV_STOP = set((
    "a an the of to and or in on for with while then this that they it its is are be "
    "does do not no if so as at by from into out up down over under can could will "
    "would should must may player players screen screens game games click clicks "
    "button buttons control controls field fields press presses pressing press's "
    "watch changes change record names name key keys different afterwards answers "
    "again still show shows shown make makes made says say said which what when who "
    "you your their them there here first second third row rows one two both either "
    "empty blank thing things something anything everything nothing"
).split())


def cov_toks(s):
    return set(t for t in re.findall(r"[a-z0-9]+", low(s))
               if len(t) >= 4 and t not in COV_STOP)


# The person's own promises — source `prd`/`journey`, MINUS the `journey-*`
# rows, which ARE the walk and would count the attempts as the promises. A
# `plan` (ticket) criterion is the contract, a `drawing` criterion is compared
# by pictures; neither is a thing a walk sets out to DO, so neither is here.
def is_person_promise(c):
    if not isinstance(c, dict):
        return False
    cid = str(c.get("id") or "")
    if cid.startswith("journey-"):
        return False
    src = low(c.get("source"))
    if src in ("plan", "drawing"):
        return False
    if src in ("prd", "journey"):
        return True
    # No source stamped (older contracts): a `prd-N` id is a promise; a
    # `part-…`/`t-…` id is not.
    if re.match(r"prd[-_]?\d", cid):
        return True
    return bool(c.get("primary")) and not cid.startswith(("part-", "t-"))


def clickables(parts):
    """Every named thing a person can CLICK — a button, a link, a role=button.
    Labels and fields are deliberately out: a person does not click a label,
    and a field is TYPED into, not clicked."""
    out = []
    for p in parts or []:
        if not isinstance(p, dict) or not p.get("interactive"):
            continue
        if not norm(p.get("name")):
            continue
        tag, role = low(p.get("tag")), low(p.get("role"))
        if tag in ("button", "a") or role == "button":
            out.append(p)
    return out


def all_parts(drawing, screens):
    """Every interactive part the record carries, flat — from the drawing's
    screens AND from the drawing-parts file (whose parts live under
    `pages[].parts`, not at the top). This is the SURFACE a criterion's control
    is looked for on; without it a one-screen panel has no controls at all."""
    parts = []
    for s in screens or []:
        parts += [p for p in (s.get("parts") or []) if isinstance(p, dict)]
    if isinstance(drawing, dict):
        parts += [p for p in (drawing.get("parts") or []) if isinstance(p, dict)]
        for pg in drawing.get("pages") or []:
            if isinstance(pg, dict):
                parts += [p for p in (pg.get("parts") or []) if isinstance(p, dict)]
    return parts


def names_control(text_low, ctrl):
    """Does this criterion NAME this control — as a whole phrase, on word
    boundaries? Substring would let "Lock slot" match inside "unlock slot" and
    send the Unlock criterion to the Lock gate; the boundary is what stops it."""
    nm = low(ctrl.get("name"))
    if not nm or len(nm) < 3:
        return False
    return re.search(r"\b%s\b" % re.escape(nm), text_low) is not None


def cannot_reason(text, surf_ctrls, has_surface=True):
    """The honest 'I couldn't set it up'.

    With a surface (a drawing), it names, where it can, the screen or control
    the criterion wanted and the surface does not have. With NO surface, a
    DOABLE requirement would already have become a step, so the only promises
    that reach here name nothing a walk can act on — and the reason says THAT,
    never "nothing on the drawing", because there was no drawing to blame."""
    if not has_surface:
        return ("I couldn't set it up: this criterion names nothing a walk can do — "
                "no action to take, only something to look at")
    m = re.search(r"\b(?:back|return)s?\b.*?\b(?:to\s+)?(?:the\s+)?"
                  r"([a-z][a-z ]{1,20}?)\s+screen\b", text, re.I)
    if m:
        return ("I couldn't set it up: no \u201c%s screen\u201d on the drawing to reach"
                % norm(m.group(1)))
    m = re.search(r"[\"\u201c]([A-Za-z][A-Za-z0-9 &'\-]{1,28})[\"\u201d]", text)
    if m:
        return ("I couldn't set it up: nothing on the drawing matches \u201c%s\u201d"
                % norm(m.group(1)))
    return ("I couldn't set it up: nothing on the drawing corresponds to this — "
            "no control to click and no field to fill")


def link_criterion(c, steps, surf_ctrls, has_surface=True):
    """The step that ATTEMPTED this promise, or the reason none could. A step
    STAMPED with this promise's id (a requirement-derived step) answers it
    outright. Otherwise a named gate is answered by its own phase (blank when
    the criterion is about a refusal, filled otherwise); a named plain control
    by the click that pressed it; anything else by the step whose words overlap
    it most (≥2 real words)."""
    t = low(c.get("text"))
    cid = str(c.get("id") or "")
    if cid:
        for s in steps:
            if s.get("promiseId") == cid:
                return s.get("key"), None
    neg = bool(re.search(r"\b(empty|blank|refus\w*|without|missing|invalid|"
                         r"required|reject\w*)\b", t))

    def gate_step(nm, phase):
        for s in steps:
            if s.get("do") == "gate" and low(" ".join(s.get("match") or [])) == low(nm):
                if s.get("phase") == phase:
                    return s
        for s in steps:               # the gate was tried, but not this phase
            if s.get("do") == "gate" and low(" ".join(s.get("match") or [])) == low(nm):
                return s
        return None

    for x in surf_ctrls:
        if GATE.search(norm(x.get("name"))) and names_control(t, x):
            s = gate_step(x.get("name"), "blank" if neg else "filled")
            if s:
                return s.get("key"), None
    for x in surf_ctrls:
        if GATE.search(norm(x.get("name"))) or not names_control(t, x):
            continue
        for s in steps:
            if s.get("do") == "click" and any(low(m) == low(x.get("name"))
                                              for m in s.get("match") or []):
                return s.get("key"), None
    ct = cov_toks(t)
    best, best_n = None, 0
    for s in steps:
        so = cov_toks(" ".join([s.get("name") or "", s.get("why") or "",
                                s.get("expect") or "", " ".join(s.get("match") or [])]))
        n = len(ct & so)
        if n > best_n:
            best, best_n = s, n
    if best is not None and best_n >= 2:
        return best.get("key"), None
    return None, cannot_reason(str(c.get("text") or ""), surf_ctrls, has_surface)


def build(criteria, drawing, html_screens=None, title="", prd=""):
    crit = [c for c in (criteria or {}).get("criteria") or [] if isinstance(c, dict)]
    prd_text = low(" ".join(str(c.get("text") or "") for c in crit))
    scr = html_screens or (screens_of(drawing) if drawing else [])
    # FOUR BUCKETS, IN THE ORDER A PERSON DOES THEM: walk to the last screen,
    # try the gate while it is still empty, do the work, take the side trips
    # the record describes, and only then finish the flow. The gate closes the
    # journey because locking a month is the last thing anyone does to it.
    walk_steps, gate_blank, fills, fill_all, routes, gate_filled = [], [], [], [], [], []
    keys = []
    named_clicks = []
    req_steps = []
    why_from, seen = [], set()

    def mk(bucket, step):
        k = (low(" ".join(step.get("match") or [])) + "|" + step["do"] + "|"
             + str(step.get("phase") or "") + "|" + str(step.get("pressKey") or ""))
        if k in seen:
            return
        seen.add(k)
        bucket.append(step)

    for i, s_ in enumerate(scr):
        nxt = scr[i + 1] if i + 1 < len(scr) else None
        if nxt:
            c = forward_control(s_["parts"], nxt["name"], prd_text)
            if c:
                name = norm(c.get("name"))
                mk(walk_steps, {"do": "click", "match": [name],
                                "name": 'from the %s screen, click "%s"' % (s_["name"], name),
                                "expect": "the %s screen" % nxt["name"],
                                "why": "the drawing draws %s before %s, and this is %s's own "
                                       "forward control" % (s_["id"], nxt["id"], s_["id"])})
                why_from.append("the drawing's screen order")
        else:
            # THE LAST DRAWN SCREEN is where the work is done: a person fills
            # what there is to fill and then tries the gate. The gate is tried
            # BEFORE the fields are filled as well as after, because "it stays
            # shut until its condition is met" is half the requirement and the
            # only half a filled-in form can ever show.
            g = gate_control(s_["parts"])
            fields = typeables(s_["parts"])[:2]
            if g and fields:
                gname = norm(g.get("name"))
                mk(gate_blank, {"do": "gate", "phase": "blank", "match": [gname],
                                "name": 'try "%s" with the field(s) still blank' % gname,
                                "expect": "it refuses while the %s is blank"
                                          % (norm(fields[0].get("name"))[:40] or "field"),
                                "why": "a gate that opens on an empty form is the fault a "
                                       "filled form can never show"})
                why_from.append("the screen's own gate")
            for f in fields:
                fname = norm(f.get("name"))
                mk(fills, {"do": "type", "match": [fname] if fname else [], "text": TYPED_TEXT,
                           "name": 'type into "%s"' % (fname[:40] or "the first empty field"),
                           "expect": "what I typed shows on this screen and the next",
                           "why": "it is a field a person fills, drawn on %s" % s_["id"]})
                why_from.append("the fields the screens carry")
            if g and fields:
                # FILL THE WHOLE FORM, NOT TWO OF IT (fix round 1, D6). The
                # drawing names a field or two; the real builder asks for
                # nineteen. Typing into two of nineteen and then calling the
                # gate's "filled" phase means the phase never ran: the gate
                # refused for the same reason it refused when the form was
                # blank, and the two steps came back byte-identical while the
                # record claimed both had been taken. So one step fills every
                # field the screen still wants, and says by name which ones it
                # could not.
                mk(fill_all, {"do": "type-all", "match": [], "text": TYPED_TEXT,
                              "name": "fill every field this screen still wants",
                              "expect": "no empty field is left before the gate is tried",
                              "why": "the gate's filled phase says nothing while the form "
                                     "is still mostly empty"})
                why_from.append("the fields the screens carry")
            if g:
                gname = norm(g.get("name"))
                mk(gate_filled, {"do": "gate", "phase": "filled", "match": [gname],
                                 "name": 'click "%s" now everything is filled' % gname,
                                 "expect": "it opens and the flow completes",
                                 "why": "the end of the flow is part of the flow"})

    # THE PRD'S OWN STEPS — including screens the drawing never drew. This is
    # the only way a control on an undrawn screen is ever reached: on the real
    # benchmark the preview screen is drawn nowhere, and the broken button on
    # it was invisible to every look that only walked the drawing.
    for c in crit:
        text = norm(c.get("text"))
        for m in NAMED_ROUTE.finditer(text):
            name = norm(m.group(1))
            # "The builder's 'Preview" — a sentence hands back an article, a
            # possessive and half a quote mark. What is wanted is the LABEL.
            name = re.sub(r"^(the|a|an)\s+", "", name, flags=re.I)
            name = re.sub(r"^\S+'s\s+", "", name)
            name = name.split("'")[-1].strip()
            if not name or len(name) < 3 or low(name) in ("the", "this", "that", "a"):
                continue
            # NOBODY WALKING A FLOW THROWS THEIR WORK AWAY. Discard, cancel,
            # delete and their family are real controls with real routes, and
            # taking one mid-walk ends the walk — so they are not steps.
            if BACKWARD.match(name):
                continue
            # The gate already has two steps of its own, both ways round; the
            # PRD naming it a third time is the same control, not a new step.
            if GATE.search(name):
                continue
            mk(routes, {"do": "click", "match": [name],
                        "name": 'click "%s", the way the PRD describes it' % name,
                        "expect": "the screen it says that leads to",
                        "why": "the record says so: %s" % text[:120]})
            why_from.append("the PRD's own steps")
            if re.search(r"\b(back|return)\b", text, re.I):
                mk(routes, {"do": "click", "match": ["back", "return", "close"],
                            "name": "come back the way the record says you can",
                            "expect": "the screen I left",
                            "why": "the record says there is a way back from there"})

    # ── THE KEYS THE RECORD NAMES (S221 fix 7) ──────────────────────────
    # Every criterion as its own sentence, plus the PRD's prose when the caller
    # passed it — the Goal is where the captain says how the build is USED
    # ("walk the character around the village with the arrow keys"), and none
    # of that survives into the acceptance criteria this planner used to read.
    sentences = [c.get("text") or "" for c in crit]
    if prd:
        sentences += SENTENCE.findall(prd)
    ks, kwhy = key_steps(sentences)
    for st in ks:
        mk(keys, st)
    why_from.extend(kwhy)

    # ── THE FLOOR: every person promise gets an ATTEMPT (S226) ──────────
    # What the scraper found above is whatever fell out of the sources. Now the
    # person's own acceptance list is made the floor: a promise the walk does
    # not yet attempt, whose control IS on the surface, is turned into one; a
    # promise whose control is NOT there is left for the coverage pass to record
    # with its reason. Nothing here is invented for a control no criterion names
    # — that is the ceiling, and it is why the loops are driven BY the criteria.
    person = [c for c in crit if is_person_promise(c)]
    surface = all_parts(drawing, scr)
    surf_ctrls = clickables(surface)
    surf_fields = typeables(surface)

    tried_gates = set(low(" ".join(s.get("match") or [])) for s in gate_blank + gate_filled)
    for c in person:
        t = low(c.get("text"))
        g = next((x for x in surf_ctrls
                  if GATE.search(norm(x.get("name"))) and names_control(t, x)), None)
        if not g or low(g.get("name")) in tried_gates:
            continue
        tried_gates.add(low(g.get("name")))
        gname = norm(g.get("name"))
        if surf_fields:
            mk(gate_blank, {"do": "gate", "phase": "blank", "match": [gname],
                            "name": 'try "%s" with the field(s) still blank' % gname,
                            "expect": "it refuses while the %s is blank"
                                      % (norm(surf_fields[0].get("name"))[:40] or "field"),
                            "why": "a person is promised this refuses on an empty form: %s"
                                   % norm(c.get("text"))[:110]})
            for f in surf_fields[:2]:
                fname = norm(f.get("name"))
                mk(fills, {"do": "type", "match": [fname] if fname else [], "text": TYPED_TEXT,
                           "name": 'type into "%s"' % (fname[:40] or "the first empty field"),
                           "expect": "what I typed shows on this screen",
                           "why": "the promise says a person fills this before the gate"})
            mk(fill_all, {"do": "type-all", "match": [], "text": TYPED_TEXT,
                          "name": "fill every field this screen still wants",
                          "expect": "no empty field is left before the gate is tried",
                          "why": "the gate's filled phase says nothing while the form is empty"})
        mk(gate_filled, {"do": "gate", "phase": "filled", "match": [gname],
                         "name": 'click "%s" now everything is filled' % gname,
                         "expect": "it opens and the promise holds",
                         "why": "a person is promised this locks once filled: %s"
                                % norm(c.get("text"))[:110]})

    # THE PLAIN BUTTONS A PROMISE NAMES, and only those. A control already
    # walked (a forward click, a PRD route) is not clicked twice; a gate has its
    # own two steps; a control no criterion names is never touched at all.
    already = set()
    for s in walk_steps + routes + named_clicks:
        for m in s.get("match") or []:
            already.add(low(m))
    for c in person:
        t = low(c.get("text"))
        for x in surf_ctrls:
            nm = norm(x.get("name"))
            if not nm or GATE.search(nm) or low(nm) in already:
                continue
            if not names_control(t, x):
                continue
            already.add(low(nm))
            mk(named_clicks, {"do": "click", "match": [nm], "bornOf": "named-click",
                              "name": 'click "%s", which a person is promised they can' % nm,
                              "expect": "the screen answers the control",
                              "why": "a person is promised this: %s" % norm(c.get("text"))[:120]})

    # ── NO DRAWING? DERIVE THE STEPS FROM THE REQUIREMENTS (Number One) ──
    # Everything above needs a SURFACE — screens, controls, fields the drawing
    # drew. With no drawing there is none, and the scraper collapses to an empty
    # journey while every promise reads "I couldn't set it up". So when the
    # record carries no surface at all, each person promise that names something
    # DOABLE becomes a real step aimed at what the requirement names, stamped at
    # birth with the promise it serves. A drawing, when present, still wins:
    # this fires only when there is nothing drawn to walk.
    has_surface = bool(surface)
    if not has_surface:
        for st in requirement_steps(person):
            mk(req_steps, st)
            why_from.append("the requirements themselves, with no drawing to walk")

    # WHERE A STEP CAME FROM IS A RECORD, STAMPED HERE AT BIRTH — never inferred
    # later by re-reading its text. The bucket that produced a step IS its
    # source: the drawing's screens/controls/fields on one side, the
    # requirements' own words on the other.
    for st in (walk_steps + gate_blank + fills + fill_all + gate_filled
               + named_clicks):
        st.setdefault("derivedFrom", "drawing")
    for st in routes + keys + req_steps:
        st.setdefault("derivedFrom", "requirement")

    # THE WAY IN (measured, 2026-09-19). The drawing's first screen is not
    # necessarily the app's front door: on the real benchmark the front door is
    # a scorecard and the drawn flow lives behind a nav item, so every step of
    # the first walk came back "no such control" from a page that simply was
    # not the drawing's first screen. These are the names to CLICK to get
    # there — the first screen's own headings and the mission's title, both
    # read from the record — and the driver tries them before giving up on the
    # first step. It is never an address: finding the door is part of the walk.
    entry = []
    for h in (scr[0].get("headings") if scr else []) or []:
        if h and h not in entry:
            entry.append(h)
    for t in (title or "").split("—")[:1]:
        t = norm(t)
        if t and t not in entry:
            entry.append(t)

    # THE ORDER OF THE WALK. Where the drawing gives a click-driven journey, the
    # keys go AFTER it so a keystroke cannot push its last step past the cap.
    # Where there is NO such journey — a one-screen panel opened BY a key, like
    # the save panel Escape reveals — the key must go FIRST, or the fills and
    # the gate run against a panel that was never opened.
    if walk_steps:
        ordered = (walk_steps + gate_blank + fills + routes + named_clicks
                   + keys + fill_all + gate_filled + req_steps)
    else:
        ordered = (keys + gate_blank + fills + routes + named_clicks
                   + req_steps + fill_all + gate_filled)
    steps = ordered[:STEP_CAP]
    for i, st in enumerate(steps):
        st["key"] = st.get("key") or ("j%d" % (i + 1))

    # ── THE REACH BEYOND THE BROWSER (S239) ──────────────────────────────
    # Built from the SAME record, aimed at the criteria whose `reachVia` says a
    # browser was never going to reach them. Executed by xo-run.py, not by
    # xo-drive.js, which is why it rides in its own list.
    reach, reach_skipped = reach_steps(criteria, prd)
    for i, st in enumerate(reach):
        st["key"] = st.get("key") or ("r%d" % (i + 1))
    reach_by_crit = {}
    for st in reach:
        if st.get("for"):
            reach_by_crit.setdefault(st["for"], st)

    # ── THE COVERAGE: attempted N of M, and which step (or why none) ─────
    # Emitted as DATA for the report to render. Each person promise is paired
    # with the walk step that attempted it, or the honest reason it could not
    # be turned into an attempt. This is the number the captain asked to SEE.
    cov_rows = []
    for c in person:
        key, reason = link_criterion(c, steps, surf_ctrls, has_surface)
        row = {"id": str(c.get("id") or ""),
               "text": norm(c.get("text")),
               "attempted": bool(key),
               "step": key,
               "reason": reason}
        # S239: a criterion a BROWSER could not reach may still have been
        # reached — by running the CLI, the workflow, or by reading what the
        # build produced. The reach step that claims it says so here, and
        # `checkedBy` on the row records WHICH instrument it was.
        rst = reach_by_crit.get(row["id"])
        if rst is not None and not row["attempted"]:
            row["attempted"] = True
            row["step"] = rst["key"]
            row["checkedBy"] = {"run": "cli", "workflow": "workflow",
                                "read": "test"}.get(rst["do"], rst["do"])
            row["reason"] = ("reached by %s, not by a browser: %s (%s)"
                             % (row["checkedBy"], rst["why"], rst["fromChecklist"]))
        cov_rows.append(row)
    coverage = {"group": "can a person do what it promises",
                "attempted": sum(1 for r in cov_rows if r["attempted"]),
                "total": len(cov_rows),
                "criteria": cov_rows}

    src = []
    for w in why_from:
        if w not in src:
            src.append(w)
    for st in reach:
        lbl = "the %s live-check checklist" % st["fromChecklist"].split("#")[0]
        if lbl not in src:
            src.append(lbl)
    out = {"source": src or ["nothing in the record described a flow"],
           "typedText": TYPED_TEXT, "entry": entry, "steps": steps,
           "coverage": coverage}
    # ADDITIVE KEYS, always present so a reader never has to guess whether a
    # look predates S239: an empty list says "nothing beyond the browser".
    out["reachSteps"] = reach
    out["reachUninstantiated"] = reach_skipped
    return out



# ===========================================================================
# S239 — THE WALK BEYOND THE BROWSER. Declared steps, HARNESS-executed.
# ===========================================================================
# THE MEASUREMENT. Canvas weekend, 34 runs: Number One filed 0 of 31 bugs. All
# 16 of its recorded misses were REACH errors — "CLI argument handling and
# env-var behaviour had no test and no screen, so nothing looked at them",
# "nothing ran the workflow", "the tests stub the transport, so the URL a real
# call goes to is never asserted". Its judgement was never the problem.
#
# THE FENCE THIS KEEPS. The worker role stays `repo-read`: it never gets a
# shell. S168 ("read roles have no shell") and S222 ("a model left to walk
# freely is a LOTTERY, and a lottery is not a proof") are both still law. So
# reach arrives the SAME way the browser walk did: the step is DECLARED here,
# from the record, and the HARNESS (`xo-run.py`) executes it.
#
# THREE NEW KINDS, and they live in their own list:
#
#   reachSteps  {"do": "run",      argv, cwd, env, expect, for, evidence}
#               {"do": "workflow", file, job, expect, for, evidence}
#               {"do": "read",     path, expect, for, evidence}
#
# WHY A SEPARATE LIST AND NOT `steps`. `steps` is the contract between this file
# and `xo-drive.js`, which executes every entry in it inside headless Chrome. A
# `run` step in there would be handed to a browser. The browser walk is
# UNCHANGED, by ruling (*What we are NOT changing*), so the kinds the harness
# executes ride beside it instead of inside it.
#
# THE TEMPLATES ARE NOT WRITTEN HERE. They are lifted from the live-check
# checklists (`skills/lcars-run/live-check/<type>.md`) — the SAME files the buddy
# follows in prose, which is why they must stay in lockstep (the README says so,
# and `tests/live-check.test.sh` asserts it). One source, two readers. Forking
# them here would give Number One a second, quietly different checklist.
#
# AN ITEM WHOSE PLACEHOLDERS THE RECORD CANNOT FILL IS NOT GUESSED. It is
# recorded in `reachUninstantiated` with the reason — "ours to fix" (S225),
# never a step built out of a `<placeholder>` nobody substituted.
LIVE_CHECK_DIR = os.environ.get("LCARS_LIVE_CHECK_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lcars-run", "live-check")

# The interpreters a declared entrypoint PATH needs in front of it. Mechanical
# and recorded: a `.py` path is run by python3 because that is how CI runs it,
# not because anything read the file.
INTERPRETERS = {".py": "python3", ".js": "node", ".rb": "ruby", ".sh": "bash"}

_FENCE = re.compile(r"```(run|workflow|read):\n(.*?)```", re.S)


def checklist_items(ptype, directory=None):
    """The fenced templates of one checklist, in item order.

    Each row: {"item": "cli#1", "n": "01", "kind": "run", "template": {...}}.
    `n` comes from the template's OWN `evidence` name, because the README makes
    that the item number ("an evidence file nobody can trace back to an item is
    not evidence").
    """
    path = os.path.join(directory or LIVE_CHECK_DIR, "%s.md" % ptype)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return []
    rows = []
    for kind, body in _FENCE.findall(text):
        try:
            tpl = json.loads(body)
        except Exception:
            continue
        ev = str(tpl.get("evidence") or "")
        base = os.path.basename(ev)
        m = re.match(r"(\d+)-", base)
        n = m.group(1) if m else "%02d" % (len(rows) + 1)
        rows.append({"item": "%s#%d" % (ptype, int(n)), "n": n, "kind": kind,
                     "template": tpl, "evidence": base})
    return rows


def cli_argv0(path):
    """The argv prefix that RUNS a declared entrypoint path."""
    ext = os.path.splitext(path or "")[1].lower()
    interp = INTERPRETERS.get(ext)
    return ([interp, path] if interp else ["./" + path.lstrip("./")]) if path else []


def subcommand_shapes(prd_text, crit_text, entry_path):
    """The subcommands the RECORD names, each with WHETHER THE RECORD GIVES IT
    A VALUE: [{"verb": "file", "takesValue": True}, …], in the order named.

    Not prose: a backticked `notes add "<title>"` in the PRD's acceptance
    criteria IS the captain writing the invocation down — and the fact that he
    wrote an argument after `add` and none after `list` is part of what he wrote
    down. That one bit is what tells a bad-input step which subcommand TAKES
    input (S239 fix round 1, D2): feeding `""` to a verb that takes no argument
    exits 0, which the readout then records as a failed `exitNonZero` and the
    console prints as `FAILED … (cli)` about a command that works.

    A record that writes every invocation BARE therefore returns every shape
    `takesValue: False`, and that is the honest answer — it says the record did
    not say. The caller must REFUSE the step, not guess (S239 fix round 2).
    """
    stem = os.path.splitext(os.path.basename(entry_path or ""))[0]
    if not stem:
        return []
    out = []
    for span in re.findall(r"`([^`]{2,120})`", (prd_text or "") + "\n" + (crit_text or "")):
        words = span.replace('"', " ").replace("'", " ").split()
        if len(words) < 2:
            continue
        head = os.path.splitext(os.path.basename(words[0]))[0]
        if head != stem:
            continue
        cand = words[1]
        if not re.match(r"^[a-z][a-z0-9-]*$", cand):
            continue
        takes = len(words) > 2
        for row in out:
            if row["verb"] == cand:
                # One invocation naming a value is enough: `notes add` and
                # `notes add "<title>"` are the same verb, and it takes one.
                row["takesValue"] = row["takesValue"] or takes
                break
        else:
            out.append({"verb": cand, "takesValue": takes})
    return out


def subcommands(prd_text, crit_text, entry_path):
    """Just the verbs the record names, in the order it names them."""
    return [r["verb"] for r in subcommand_shapes(prd_text, crit_text, entry_path)]


def reach_steps(contract, prd_text=""):
    """(reachSteps, uninstantiated) — the harness-executed walk, from the record.

    Everything here is RECORDED: the product types and each criterion's
    `reachVia` come from criteria.json (S239, xo-criteria.py), the entrypoint
    paths come from the plan's `entrypoints[]` (S236), and the step shapes come
    from the live-check checklists. Nothing is inferred from prose except the
    product's OWN backticked invocation lines, and that is read as the record it
    is, not parsed for meaning.
    """
    contract = contract if isinstance(contract, dict) else {}
    crit = [c for c in (contract.get("criteria") or []) if isinstance(c, dict)]
    types = [t.get("type") for t in (contract.get("productTypes") or [])
             if isinstance(t, dict)]
    eps = [e for e in (contract.get("entrypoints") or []) if isinstance(e, dict)]
    crit_text = " ".join(str(c.get("text") or "") for c in crit)

    # WHO EACH STEP IS FOR. The criteria of that reach, primary first, handed
    # out one per step. A step claims ONE criterion and never the group: over-
    # claiming coverage is the dishonesty this whole arc exists to remove.
    pools = {}
    for reach in ("cli", "workflow", "browser", "test", "none"):
        pool = [str(c.get("id")) for c in crit
                if c.get("reachVia") == reach and c.get("primary")]
        pool += [str(c.get("id")) for c in crit
                 if c.get("reachVia") == reach and not c.get("primary")]
        pools[reach] = pool
    used = {k: 0 for k in pools}

    def claim(reach):
        pool = pools.get(reach) or []
        if not pool:
            return ""
        i = used[reach] % len(pool)
        used[reach] += 1
        return pool[i]

    steps, skipped = [], []

    def place(value, subs):
        """Substitute the placeholders the record CAN fill; report the rest."""
        if isinstance(value, list):
            out, missing = [], []
            for v in value:
                r, m = place(v, subs)
                missing.extend(m)
                if r is not None:
                    out.append(r)
            return out, missing
        if not isinstance(value, str):
            return value, []
        if value == "":
            return value, []
        m = re.fullmatch(r"<(.+)>", value)
        if not m:
            return value, []
        key = m.group(1)
        for want, got in subs.items():
            if key == want or key.startswith(want):
                return got, []
        return None, [key]

    # ---- the CLI checklist -------------------------------------------------
    cli_ep = next((e for e in eps if e.get("kind") == "cli" and e.get("path")), None)
    if "cli" in types:
        if not cli_ep:
            skipped.append({"item": "cli#*", "why": "the plan recorded no `cli` "
                            "entrypoint path, so there is nothing to run"})
        else:
            shapes = subcommand_shapes(prd_text, crit_text, cli_ep["path"])
            verbs = [r["verb"] for r in shapes]
            argv0 = cli_argv0(cli_ep["path"])
            # WHICH VERB EACH ITEM WANTS, FROM THE ITEM'S OWN INTENT (S239 fix
            # round 1, D2). Both `<subcommand>` (item 2, bad input) and
            # `<the-main-verb>` (item 3, the happy path) used to be filled with
            # verbs[0] — whichever subcommand the record happened to name first.
            # A record that names its LISTING verb first then got `list ""` as
            # its bad input (exit 0, recorded as a FAILED exitNonZero about a
            # command that works) and `list <value>` as its happy path, which
            # never filed anything for the list to show. Both items want the
            # verb that TAKES the input; the read-back wants the one that does
            # not. The record says which is which.
            #
            # AND WHERE THE RECORD DOES NOT SAY IT, THE STEP IS NOT BUILT (S239
            # fix round 2). Round 1 fell back to `verbs[0]` whenever no backtick
            # wrote a value after its verb — which is the ORDINARY way a PRD is
            # written (prose for the behaviour, a bare invocation in the
            # backticks), so on the record that bred the bug the fallback WAS the
            # pre-fix behaviour verbatim and the console went on printing
            # `FAILED 02-bad-input.txt (cli)` about a command that works. There
            # is no honest cleverer guess here: inferring a fact from the
            # captain's wording has cost this project three whole sessions
            # (S147, S156, S188). So a silent record instantiates NOTHING that
            # needs the missing fact; the item joins `reachUninstantiated` with
            # a reason naming what the record failed to say, exactly as cli#4-8
            # and web#4-6 already do. An honest "I could not build this step"
            # beats a FAILED about working software.
            acting = next((r["verb"] for r in shapes if r["takesValue"]), "")
            # The read-back must not be the verb the acting step already ran.
            # Round 1 left that out, so a record naming its acting verb first
            # with no value resolved BOTH to it and the read-back ran the acting
            # verb with no argument — a false FAILED the fix itself created.
            reading = next((r["verb"] for r in shapes
                            if not r["takesValue"] and r["verb"] != acting), "")
            subs = {"cli": None, "worktree": "<worktree>",
                    "throwaway-home": "<throwaway-home>"}
            if verbs:
                subs["realistic-value"] = TYPED_TEXT
            if acting:
                subs["subcommand"] = acting
                subs["the-main-verb"] = acting
            # What the record would have to write for the refused items to
            # instantiate. Named, so the gap is the captain's to close in one
            # edit rather than a mystery.
            silent = ("the record never says which subcommand TAKES the input: "
                      "every backticked invocation of `%s` is written bare, with "
                      "no value after the verb, so which one to feed cannot be "
                      "read — only guessed. Write one of them with its argument "
                      "(e.g. `%s <the-verb> \"<a value>\"`) and this item builds."
                      % (os.path.basename(cli_ep["path"]),
                         os.path.basename(cli_ep["path"])))
            for row in checklist_items("cli"):
                if row["kind"] != "run":
                    continue
                tpl = row["template"]
                argv, missing = place(tpl.get("argv") or [], subs)
                # `<cli>` is argv[0] and expands to the WHOLE run prefix.
                argv = argv0 + [a for a in argv if a is not None]
                if missing:
                    names = sorted(set(missing))
                    rest = [k for k in names
                            if k not in ("subcommand", "the-main-verb")]
                    bits = []
                    if len(rest) < len(names):
                        bits.append(silent)
                    if rest:
                        bits.append("the record does not name: " + ", ".join(rest))
                    skipped.append({"item": row["item"], "evidence": row["evidence"],
                                    "why": " ".join(bits)})
                    continue
                for_id = claim("cli")
                steps.append({"do": "run", "argv": argv,
                              "cwd": tpl.get("cwd") or "<worktree>",
                              "env": tpl.get("env") or {"HOME": "<throwaway-home>"},
                              "expect": tpl.get("expect") or {},
                              "for": for_id or "", "evidence": row["evidence"],
                              "fromChecklist": row["item"],
                              "derivedFrom": "the cli live-check checklist",
                              "why": "a CLI criterion is reached by RUNNING the CLI"})
                # THE HAPPY PATH IS DONE WHEN THE EFFECT IS READ BACK (S239 fix
                # round 1, D2). Item 3 is "create, then list, then whatever the
                # PRD says the user does next" — one `run` template can only
                # carry the create, so the list that reads it back is its own
                # step, right behind it, in the SAME worktree and the SAME
                # throwaway HOME. Without it the happy path proved only that a
                # command exited 0. The item is identified by its own template
                # (the one that asks for a realistic value), never by a number.
                if reading and "<realistic-value>" in (tpl.get("argv") or []):
                    stem = os.path.splitext(row["evidence"])[0]
                    steps.append({"do": "run", "argv": argv0 + [reading],
                                  "cwd": tpl.get("cwd") or "<worktree>",
                                  "env": tpl.get("env") or {"HOME": "<throwaway-home>"},
                                  "expect": {
                                      "exit": 0,
                                      "listsWhatWasJustFiled": TYPED_TEXT,
                                      "note": "the step before this one filed that "
                                              "value; a happy path is not done "
                                              "until the effect is read back"},
                                  "for": claim("cli") or for_id or "",
                                  "evidence": "%s-readback.txt" % stem,
                                  "fromChecklist": row["item"],
                                  "derivedFrom": "the cli live-check checklist, "
                                                 "item 3's \"create, then list\"",
                                  "why": "a success message is not the thing it "
                                         "claims; the list is"})

    # ---- the WORKFLOW checklist -------------------------------------------
    wf_eps = [e for e in eps if e.get("kind") == "workflow" and e.get("path")]
    if "workflow" in types:
        if not wf_eps:
            skipped.append({"item": "workflow#*", "why": "the plan recorded no "
                            "`workflow` entrypoint path, so there is nothing to run"})
        wf_tpl = next((r for r in checklist_items("workflow") if r["kind"] == "workflow"),
                      None)
        read_tpl = next((r for r in checklist_items("workflow")
                         if r["kind"] == "read" and r["n"] == "01"), None)
        if read_tpl and wf_eps:
            steps.append({"do": "read",
                          "path": ".github/workflows",
                          "expect": read_tpl["template"].get("expect") or {},
                          "for": claim("workflow") or "",
                          "evidence": read_tpl["evidence"],
                          "fromChecklist": read_tpl["item"],
                          "derivedFrom": "the workflow live-check checklist",
                          "why": "the workflows the build actually ships"})
        for ep in wf_eps:
            if not wf_tpl:
                break
            steps.append({"do": "workflow", "file": ep["path"],
                          "job": wf_tpl["template"].get("job") or "",
                          "expect": wf_tpl["template"].get("expect") or {},
                          "for": claim("workflow") or "",
                          "evidence": wf_tpl["evidence"],
                          "fromChecklist": wf_tpl["item"],
                          "derivedFrom": "the plan's workflow entrypoint",
                          "why": "nothing ran the workflow on the modelled "
                                 "weekend, and three breaks were visible only "
                                 "to the real runner"})

    # ---- the WEB checklist's non-browser halves ---------------------------
    # The browser items stay with xo-drive.js, UNCHANGED. What the web checklist
    # adds here is the READ of what was produced — "a screenshot is looked at,
    # not merely produced" has a sibling: an artifact is READ, not assumed.
    if "web" in types:
        for row in checklist_items("web"):
            if row["kind"] != "read":
                continue
            skipped.append({"item": row["item"], "evidence": row["evidence"],
                            "why": "the record does not name the rendered page "
                                   "or deployed artifact to read"})

    return steps[:STEP_CAP], skipped

def journey_criteria(journey):
    """One requirement per step (part F): each step is its own row, so a step
    that could not be taken reads as "couldn't check" BY NAME instead of
    vanishing into a paragraph about the app in general."""
    rows = []
    for s in journey.get("steps") or []:
        rows.append({
            "id": "journey-%s" % s["key"],
            "text": "Walking the flow: %s — %s." % (s["name"], s.get("expect") or "it works"),
            "source": "journey",
            "primary": True,
            "journeyStep": s["key"],
            "notDrawn": True,
        })
    return rows


def apply_criteria(contract, journey):
    rows = journey_criteria(journey)
    cov = journey.get("coverage")
    if cov:
        contract["personCoverage"] = cov
    if not rows:
        return contract, 0
    have = set(str(c.get("id")) for c in contract.get("criteria") or [])
    rows = [r for r in rows if r["id"] not in have]
    contract["criteria"] = (contract.get("criteria") or []) + rows
    contract["journeySteps"] = len(journey.get("steps") or [])
    return contract, len(rows)


# ── did the state carry? (part F) ──────────────────────────────────────────

def months(text):
    return set("%s %s" % (m.group(1).title(), m.group(2)) for m in MONTH.finditer(text or ""))


def carry(walk):
    """What a person notices only because they WALKED: a value that was on the
    screen they came from and is different on the screen they arrived at.

    Two carried values, both generic, neither of them about any one app: a
    month the person was offered, and the text the walk itself typed. Findings
    are EVIDENCE — they name what was seen on each screen and leave the verdict
    where it belongs.
    """
    out = []
    steps = [s for s in (walk or {}).get("steps") or [] if isinstance(s, dict)]
    # WHERE A FINDING CAME FROM IS STAMPED BY WHOEVER FOUND IT (S224 fix round
    # 3). Everything this function produces was noticed by WALKING — a value
    # that changed between two screens, a gate that opened on a blank form — and
    # nothing on the captain's acceptance list can name one of those, because
    # his list describes screens and these are the seams between them. So the
    # fact travels ON the finding, stamped here at birth, instead of being read
    # back later out of which fields happen to be missing. xo-score.py routes on
    # this flag and on nothing else: the round that inferred it from an absent
    # `part` was wrong about a measurement a drawn part DOES answer for.
    for i, s in enumerate(steps):
        if s.get("status") != "done":
            continue
        before, after = str(s.get("textBefore") or ""), str(s.get("textAfter") or "")
        if s.get("do") in ("click", "gate") and before and after:
            was, now = months(before), months(after)
            gone = sorted(was - now)
            new = sorted(now - was)
            if gone and new:
                out.append({
                    "says": "%s became %s after I clicked \"%s\" — the month did not carry "
                            "from one screen to the next" % (gone[0], new[0],
                                                             s.get("matched") or s.get("name")),
                    "screen": s.get("urlAfter") or "",
                    "kind": "carried-value",
                    "from": s.get("urlBefore") or "",
                    "shot": s.get("shot") or "",
                })
        if s.get("do") == "type" and s.get("readBack"):
            typed = str(s.get("typed") or "")
            later = " ".join(str(t.get("textAfter") or "") for t in steps[i + 1:i + 3])
            if typed and later and typed.lower() not in later.lower():
                out.append({
                    "says": "what I typed into \"%s\" does not show on the screen after it — "
                            "I typed \"%s\" and the next screen does not carry it"
                            % (s.get("matched") or "the field", typed[:60]),
                    "screen": s.get("urlAfter") or "",
                    "kind": "carried-value",
                    "shot": s.get("shot") or "",
                })
    # A GATE THAT OPENS ON A BLANK FORM. The step asked for it both ways; this
    # is the half a filled form can never show.
    for s in steps:
        if s.get("do") == "gate" and s.get("phase") == "blank":
            # "IT LET ME THROUGH" IS A MOVE, NOT A MURMUR. A gate that REFUSES
            # usually says so on the same screen ("Add a note first."), and the
            # screen's text changes when it does — so a text change is the
            # weakest possible evidence of passing, and reading it as one would
            # cry wolf over a gate doing exactly its job. Going somewhere else
            # is the fact that means it opened.
            went = str(s.get("urlAfter") or "") != str(s.get("urlBefore") or "")
            if s.get("status") == "done" and went:
                out.append({
                    "says": "the \"%s\" gate let me through with the field still blank — "
                            "it should refuse until it is filled" % (s.get("matched") or s.get("name")),
                    "screen": s.get("urlAfter") or "",
                    "kind": "gate",
                    "shot": s.get("shot") or "",
                })
    for o in out:
        o["fromWalk"] = True
    return {"observations": out}


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__.split("Usage:")[-1])
        return 2
    cmd = argv[1]

    def opt(name, default=None):
        try:
            return argv[argv.index("--" + name) + 1]
        except (ValueError, IndexError):
            return default

    if cmd == "build":
        criteria = load(opt("criteria"), {}) or {}
        drawing = load(opt("drawing"), None)
        html = opt("drawing-html")
        j = build(criteria, drawing, screens_from_html(html) if html else [],
                  title=opt("title", ""), prd=prd_prose(opt("prd", "")))
        out = opt("out")
        if out:
            os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
            with open(out, "w", encoding="utf-8") as fh:
                json.dump(j, fh, indent=2)
                fh.write("\n")
        cout = opt("criteria-out")
        added = 0
        if cout:
            contract, added = apply_criteria(criteria, j)
            with open(cout, "w", encoding="utf-8") as fh:
                json.dump(contract, fh, indent=2)
                fh.write("\n")
        n = len(j["steps"])
        nreach = len(j.get("reachSteps") or [])
        rsuffix = ("" if not nreach else
                   " — and %d step(s) the harness runs outside a browser" % nreach)
        cov = j.get("coverage") or {}
        csuffix = ("" if not cov.get("total")
                   else " — attempted %d of %d a person can check"
                        % (cov.get("attempted", 0), cov.get("total", 0)))
        if not n:
            print("nothing in the record described a flow to walk"
                  + csuffix + rsuffix)
        else:
            print("%d step(s) to walk, from %s%s%s%s"
                  % (n, "; ".join(j["source"]),
                     (" — %d of them its own requirement" % added) if added else "",
                     csuffix, rsuffix))
        return 0

    if cmd == "carry":
        w = load(opt("walk"), {}) or {}
        frag = carry(w)
        out = opt("out")
        if out:
            os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
            with open(out, "w", encoding="utf-8") as fh:
                json.dump(frag, fh, indent=2)
                fh.write("\n")
        print("%d thing(s) did not carry from one screen to the next"
              % len(frag["observations"]))
        return 0

    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
