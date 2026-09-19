#!/usr/bin/env python3
"""xo-criteria.py — build the CONTRACT, before anything is looked at.

    python3 xo-criteria.py <mission-dir> <out-file>

THE ORDER IS THE POINT. The criteria list is written from the PRD and the plan
BEFORE the app is launched and before a single pixel is seen. A judge that
writes its checklist after looking writes a checklist of what it happened to
notice; this one is a contract the look is measured against. (Contract-before-
checking — the research lesson S203 is built on.)

What goes in it:

  * THE PRD's acceptance criteria — `primary: true`. These are the stated goal,
    and a contradicted one is what makes a score LOW rather than MEDIUM.
  * THE PLAN's per-ticket acceptance criteria, each carrying its own provenance
    field exactly as the planner declared it (`drawnAt` / `notDrawn` /
    `notVisual`, run.sh's mockup contract block). That field is the instruction
    for WHERE to look: `drawnAt` names a place in the drawing, `notDrawn` says
    it is visible but undrawn, `notVisual` says there is nothing to see.
  * THE DRAWING's place names — the `id=` vocabulary of the mockup, the same
    list `mission_mockup_place_names` publishes to the planner. The driver takes
    one clipped shot per name, so these are literally what gets photographed.

Nothing here judges anything. It reads three files and writes one.
"""
import json
import os
import re
import sys


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def prd_criteria(text):
    """The acceptance criteria out of prd.md.

    A PRD is prose written by a grill, not a schema, so this looks for the
    section a human would look for: a heading that says acceptance criteria (or
    success criteria), then the list under it, stopping at the next heading.
    A PRD with no such section yields NOTHING rather than a guess — an empty
    primary list is an honest answer and the plan's criteria still carry the
    look.

    A SECTION CAN START AT A BOLD LABEL TOO (S216). A grill as often writes
    `**Acceptance Criteria:**` on a line of its own as it writes a `##`
    heading — the captain's real MBR PRDs use exactly that form — and a reader
    that knew only headings read ZERO criteria from them, which scored a real
    build against an empty list. A line that is nothing but a bold label (colon
    inside or outside the stars, or none) opens or closes a section exactly as
    a heading does. A bold phrase INSIDE a list item is content, not a label.
    """
    out = []
    lines = text.splitlines()
    in_sec = False
    # A BULLET WRAPPED ONTO THE NEXT LINE IS ONE CRITERION (S216 fix round 1,
    # D4). Read line by line, "returns a Pixi colour number for the" became the
    # whole requirement. A non-blank, non-bullet line straight after an item is
    # that item's continuation; a blank line ends it.
    open_item = False
    for ln in lines:
        if open_item and ln.strip() and not re.match(r"^\s*(?:[-*+]|\d+[.)])\s+", ln) \
                and not re.match(r"^\s{0,3}(#{1,6}\s|\*\*)", ln):
            out[-1] = out[-1] + " " + ln.strip()
            continue
        open_item = False
        label = re.match(r"^\s{0,3}\*\*([^*]+?)\*\*(.*)$", ln)
        if label:
            rest = label.group(2).strip()
            # `**Label**`, `**Label:**` or `**Label**:` — optionally with text
            # after a colon (`**Type:** feature`). Bold prose is not a label.
            if not (rest == "" or rest.startswith(":")
                    or label.group(1).rstrip().endswith(":")):
                label = None
        if re.match(r"^\s{0,3}#{1,6}\s", ln) or label:
            head = (label.group(1) if label else ln).lower()
            in_sec = bool(re.search(r"(acceptance|success)\s+criteri", head))
            continue
        if not in_sec:
            continue
        m = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(.*)$", ln)
        if m:
            item = m.group(1).strip()
            # A markdown checkbox is a criterion, not a state; strip the box.
            item = re.sub(r"^\[[ xX]\]\s*", "", item).strip()
            if item:
                out.append(item)
                open_item = True
    return out


def plan_criteria(doc):
    """Per-ticket acceptance criteria, with their provenance field intact."""
    out = []
    tickets = []
    if isinstance(doc, dict):
        for key in ("tickets", "plan", "items"):
            if isinstance(doc.get(key), list):
                tickets = doc[key]
                break
    elif isinstance(doc, list):
        tickets = doc
    for t in tickets:
        if not isinstance(t, dict):
            continue
        tid = str(t.get("id") or t.get("ticket") or "t")
        acs = t.get("acceptanceCriteria")
        if not isinstance(acs, list):
            continue
        for i, ac in enumerate(acs, 1):
            entry = {"id": "%s-ac%d" % (tid, i), "source": "plan", "ticket": tid,
                     "primary": False}
            if isinstance(ac, str):
                entry["text"] = ac
            elif isinstance(ac, dict):
                entry["text"] = str(ac.get("text") or "").strip()
                # ABSENT, not null (the additive-keys invariant): a criterion
                # that made no provenance claim carries no provenance key.
                if ac.get("drawnAt"):
                    entry["drawnAt"] = str(ac["drawnAt"])
                elif ac.get("notDrawn"):
                    entry["notDrawn"] = str(ac["notDrawn"])
                elif ac.get("notVisual"):
                    entry["notVisual"] = True
            else:
                continue
            if entry.get("text"):
                out.append(entry)
    return out


def has_drawing(mission_dir):
    """Whether this mission was ever handed a holodeck drawing at all — S210.

    `placeNames` being empty is ambiguous: a drawing with no `id=` attributes
    would also produce an empty list, and that mission DID have a drawing (a
    bad one). `hasDrawing` is the plain fact underneath both cases — is there
    an attached mockup at all — and it is what lets xo-score.py tell the
    difference between "nothing in the drawing named this place" and "there is
    no drawing to check anything against."
    """
    adir = os.path.join(mission_dir, "attachments")
    if not os.path.isdir(adir):
        return False
    return any(fn.lower().endswith((".html", ".htm")) for fn in os.listdir(adir))


# The IMAGE extensions of `lcars_attach_kind` (skills/lcars-init/
# lcars-common.sh) — the one classification every surface uses. Extension-only
# for the same reason it is there: LCARS staged these files itself.
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".heic")


def pictures(mission_dir):
    """The image attachments this mission carries, by name — S217.

    A RECORD OF WHAT IS ON DISK, NOT A GUESS AT WHAT IT WAS FOR. Nothing at
    filing records whether a picture was meant as THE design or as context, so
    this list does not claim either; it lets xo-score.py say the one thing
    that is a fact either way: when there is no drawing and there IS a picture,
    the build was not checked against a drawing, and the picture could not
    stand in for one (S214/S215 measured it falling through both guards).
    """
    adir = os.path.join(mission_dir, "attachments")
    if not os.path.isdir(adir):
        return []
    return sorted(fn for fn in os.listdir(adir) if fn.lower().endswith(IMAGE_EXTS))


def place_names(mission_dir):
    """The `id=` vocabulary of every drawing this mission carries.

    Derived from the mockup, not published by the holodeck — the captain's
    ruling, and the same derivation `mission_mockup_place_names` does in
    run.sh. Sorted and deduped so two runs produce the same contract.
    """
    names = set()
    adir = os.path.join(mission_dir, "attachments")
    if not os.path.isdir(adir):
        return []
    for fn in sorted(os.listdir(adir)):
        if not fn.lower().endswith((".html", ".htm")):
            continue
        body = read(os.path.join(adir, fn))
        for m in re.finditer(r'\bid\s*=\s*["\']([A-Za-z][\w:.-]*)["\']', body):
            names.add(m.group(1))
    return sorted(names)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: xo-criteria.py <mission-dir> <out-file>\n")
        return 2
    mdir, out = sys.argv[1], sys.argv[2]

    criteria = []
    for i, text in enumerate(prd_criteria(read(os.path.join(mdir, "prd.md"))), 1):
        criteria.append({"id": "prd-%d" % i, "text": text, "source": "prd",
                         "primary": True})

    plan_path = os.path.join(mdir, "plan.json")
    if os.path.exists(plan_path):
        try:
            criteria.extend(plan_criteria(json.loads(read(plan_path))))
        except Exception:
            pass

    doc = {
        "mission": os.path.basename(os.path.abspath(mdir)),
        "builtBeforeLaunch": True,
        "hasDrawing": has_drawing(mdir),
        "placeNames": place_names(mdir),
        "pictures": pictures(mdir),
        "criteria": criteria,
    }
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("%d criteria (%d primary), %d place names" % (
        len(criteria), sum(1 for c in criteria if c.get("primary")),
        len(doc["placeNames"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
