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
                      [--drawing-html <the drawing itself>]
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


def build(criteria, drawing, html_screens=None, title=""):
    crit = [c for c in (criteria or {}).get("criteria") or [] if isinstance(c, dict)]
    prd_text = low(" ".join(str(c.get("text") or "") for c in crit))
    scr = html_screens or (screens_of(drawing) if drawing else [])
    # FOUR BUCKETS, IN THE ORDER A PERSON DOES THEM: walk to the last screen,
    # try the gate while it is still empty, do the work, take the side trips
    # the record describes, and only then finish the flow. The gate closes the
    # journey because locking a month is the last thing anyone does to it.
    walk_steps, gate_blank, fills, fill_all, routes, gate_filled = [], [], [], [], [], []
    why_from, seen = [], set()

    def mk(bucket, step):
        k = low(" ".join(step.get("match") or [])) + "|" + step["do"] + "|" + str(step.get("phase") or "")
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
    # The whole-form fill sits directly before the gate it exists to make
    # meaningful, after the side trips that may have navigated away.
    steps = (walk_steps + gate_blank + fills + routes + fill_all + gate_filled)[:STEP_CAP]
    for i, st in enumerate(steps):
        st["key"] = st.get("key") or ("j%d" % (i + 1))
    src = []
    for w in why_from:
        if w not in src:
            src.append(w)
    return {"source": src or ["nothing in the record described a flow"],
            "typedText": TYPED_TEXT, "entry": entry, "steps": steps}


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
                  title=opt("title", ""))
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
        if not n:
            print("nothing in the record described a flow to walk")
        else:
            print("%d step(s) to walk, from %s%s"
                  % (n, "; ".join(j["source"]),
                     (" — %d of them its own requirement" % added) if added else ""))
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
