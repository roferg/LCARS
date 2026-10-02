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
                # RECORD, DO NOT INFER. The planner names the PRD requirement
                # this ticket criterion relates to, by its synthetic id (prd-N)
                # or its verbatim text, AND states which way round it is — it
                # DELIVERS that requirement (makes it true) or DELIBERATELY
                # REMOVES it (a deliberate omission the mission asked for). Both
                # are carried through untouched so the contradiction check reads
                # a DECLARED direction, not a polarity guessed from the prose.
                # The `direction` is the whole point of this design: nothing
                # anywhere reads English to decide whether a sentence asks FOR a
                # thing or for its ABSENCE — the machinery was beaten at that
                # twice in one day, so the planner records it and the check
                # reads the record. A malformed pair (a `serves` with no
                # readable `direction`) is caught in find_contradictions and
                # named there; it is NEVER defaulted to a direction here.
                if ac.get("serves"):
                    entry["serves"] = str(ac["serves"]).strip()
                    direction = str(ac.get("direction") or "").strip().lower()
                    if direction in ("delivers", "removes"):
                        entry["direction"] = direction
                # WHICH KIND OF QUESTION THIS IS, STAMPED AT BIRTH (captain's
                # ruling, 2026-09-24). A looks-question ("the header shows the
                # title") a picture settles; a works-question ("Save saves")
                # only an action settles. RECORD, DO NOT INFER: the planner
                # declares it here and the reviewer READS the stamp — nothing
                # downstream reads the criterion's prose to guess, the pattern
                # LCARS has lost three sessions to. Carried additive-key style:
                # a recognised value is kept, a bogus one is dropped, and an
                # unstamped criterion carries no `kind` key at all (a
                # notVisual criterion needs none — it is a works-question by
                # its own notVisual stamp, read at score time).
                kind = str(ac.get("kind") or "").strip().lower()
                if kind in ("looks", "works"):
                    entry["kind"] = kind
            else:
                continue
            if entry.get("text"):
                out.append(entry)
    return out



# ===========================================================================
# S239 — PRODUCT TYPES AND `reachVia`: HOW THIS CRITERION IS REACHED AT ALL.
# ===========================================================================
# THE MEASUREMENT THAT PUT THIS HERE. Canvas weekend, 26-29 Sep 2026, same
# product, 34 runs: Number One filed 0 of 31 bugs; the captain's buddy found all
# 31. Every one of the 16 recorded misses
# (lcars-dev/canvas-weekend-2026-09-26/evidence/number-one-misses.jsonl) is a
# REACH error, never a judgement error — "CLI argument handling and env-var
# behaviour had no test and no screen, so nothing looked at them". Its judgement
# and its honesty were fine wherever it could reach.
#
# So the contract now also records, before anything is looked at:
#
#   productTypes  — what kinds of surface this milestone HAS, each with the
#                   SOURCE that said so. A list of {"type", "source"}.
#   reachVia      — per criterion: cli | browser | workflow | test | none.
#                   A CLI criterion is reached by RUNNING THE CLI, not by
#                   looking for it on a page.
#
# RECORD, DO NOT INFER — the standing rule of this file, and the reason three
# earlier generations of prose-reading were deleted. Nothing below reads English
# to decide a type or a reach. Every source is a RECORDED declaration:
#
#   * the plan's `entrypoints[]` (S236) — `kind` is `cli` or `workflow` and the
#     planner wrote it;
#   * the PRD's own `PLAN RULE: CLI-only` line — a declared constraint LCARS
#     itself writes into the PRD, matched as the literal marker it is;
#   * each ticket's `changesScreenAppearance` — a declared boolean. `false` on
#     EVERY ticket is evidence AGAINST a web surface; it is deliberately NOT
#     read as evidence FOR a CLI (a workflow-only milestone changes no screen
#     either), which is why it only ever WITHHOLDS `web`;
#   * the mission's holodeck drawing, and `meta.mainLaunch` in state.json — the
#     launch contract's own record that there is a page to open.
#
# An EMPTY productTypes is an honest answer, not a bug: it says the record never
# declared a surface, every criterion then reads `reachVia` `test` or `none`, and
# the browser walk goes on exactly as it did before. Nothing here is subtracted
# from an older mission; `reachVia` and `productTypes` are ADDITIVE keys.
REACH_KINDS = ("cli", "browser", "workflow", "test", "none")
CLI_ONLY_MARKER = re.compile(r"PLAN\s+RULE\s*:\s*CLI-only", re.I)


def _tickets(doc):
    """The ticket list, in the three shapes plan_criteria already accepts."""
    if isinstance(doc, dict):
        for key in ("tickets", "plan", "items"):
            if isinstance(doc.get(key), list):
                return [t for t in doc[key] if isinstance(t, dict)]
    elif isinstance(doc, list):
        return [t for t in doc if isinstance(t, dict)]
    return []


def entrypoints(plan_doc):
    """The plan's declared entrypoints, flattened, each remembering its ticket.

    S236's record: every entry carries `kind` (`workflow` or `cli`), `path`,
    `realRunTest` and `realRunProof`. Carried through UNTOUCHED — this is the
    record S239 runs and S240 audits, so nothing is normalised away.
    """
    out = []
    for t in _tickets(plan_doc):
        tid = str(t.get("id") or t.get("ticket") or "t")
        eps = t.get("entrypoints")
        if not isinstance(eps, list):
            continue
        for ep in eps:
            if not isinstance(ep, dict):
                continue
            kind = str(ep.get("kind") or "").strip().lower()
            if kind not in ("cli", "workflow"):
                continue
            row = {"kind": kind, "ticket": tid, "path": str(ep.get("path") or "").strip()}
            for k in ("realRunTest", "realRunProof"):
                if ep.get(k):
                    row[k] = str(ep[k]).strip()
            out.append(row)
    return out


def product_types(mission_dir, plan_doc, prd_text, has_draw):
    """[{"type": ..., "source": ...}] — every type with the record that said so."""
    found = []

    def add(kind, source):
        for row in found:
            if row["type"] == kind:
                if source not in row["source"]:
                    row["source"] = row["source"] + "; " + source
                return
        found.append({"type": kind, "source": source})

    for ep in entrypoints(plan_doc):
        add(ep["kind"], "the plan's entrypoints[]: kind=%s path=%s (ticket %s)"
            % (ep["kind"], ep["path"] or "(unnamed)", ep["ticket"]))

    if CLI_ONLY_MARKER.search(prd_text or ""):
        add("cli", "the PRD's own `PLAN RULE: CLI-only` line")

    # WEB IS WITHHELD, NOT GUESSED. `changesScreenAppearance: false` declared on
    # every ticket is the planner saying this milestone touches no screen; a
    # drawing or a recorded launch target is it saying there IS one.
    tickets = _tickets(plan_doc)
    stamped = [t for t in tickets if isinstance(t.get("changesScreenAppearance"), bool)]
    no_screen = bool(stamped) and all(
        t.get("changesScreenAppearance") is False for t in stamped)
    screen_ticket = next((t for t in stamped
                          if t.get("changesScreenAppearance") is True), None)
    if screen_ticket is not None:
        add("web", "ticket %s declares changesScreenAppearance: true"
            % (screen_ticket.get("id") or screen_ticket.get("ticket") or "?"))
    if has_draw and not no_screen:
        add("web", "the mission was handed a holodeck drawing")
    main_launch = ""
    try:
        st = json.loads(read(os.path.join(mission_dir, "state.json")) or "{}")
        meta = st.get("meta") if isinstance(st.get("meta"), dict) else {}
        main_launch = str((meta or {}).get("mainLaunch") or st.get("mainLaunch") or "").strip()
    except Exception:
        main_launch = ""
    if main_launch and not no_screen:
        add("web", "state.json records a launch target: %s" % main_launch)
    return found


def reach_for(crit, types, eps_by_ticket, served_by):
    """(reachVia, whyThatReach) for ONE criterion. Declarations win, in order.

    THE ONE RULE THIS ENFORCES: a reach the record does not support is never
    invented. With no `web` type recorded, nothing is ever `browser` — which is
    exactly the miss this session exists for (three missions running, a CLI
    product judged through a browser that had nothing of it to show).
    """
    kinds = [t["type"] for t in types]

    # 1. THE PLANNER MAY SAY IT OUTRIGHT.
    declared = str(crit.get("reachVia") or "").strip().lower()
    if declared in REACH_KINDS:
        return declared, "the planner declared reachVia: %s" % declared

    # 2. THE TICKET'S OWN ENTRYPOINTS. A criterion on a ticket that declares a
    #    workflow entrypoint is reached by RUNNING that workflow.
    tickets = [crit.get("ticket")] if crit.get("ticket") else []
    tickets += [t for t in served_by.get(str(crit.get("id") or ""), []) if t]
    for tid in tickets:
        for ep in eps_by_ticket.get(tid, []):
            return ep["kind"], ("ticket %s declares a %s entrypoint (%s)"
                                % (tid, ep["kind"], ep["path"] or "unnamed"))

    # 3. THE PROVENANCE STAMP THE PLANNER ALREADY WRITES.
    if crit.get("drawnAt") or crit.get("kind") == "looks" or crit.get("notDrawn"):
        if "web" in kinds:
            return "browser", "it is a looks-question and this milestone has a page"
    if crit.get("notVisual") is True:
        if "cli" in kinds:
            return "cli", "notVisual, and this milestone's surface is a CLI"
        if "workflow" in kinds:
            return "workflow", "notVisual, and this milestone's surface is a workflow"
        return "test", "notVisual, with no CLI, page or workflow recorded to run"

    # 4. THE MILESTONE'S ONE SURFACE, when it has only one.
    for kind, reach in (("web", "browser"), ("cli", "cli"), ("workflow", "workflow")):
        if kind in kinds:
            return reach, "the milestone's recorded surface is %s" % kind
    return "none", "nothing in the record says how this could be reached"

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


# ===========================================================================
# THE TICKET-CRITERION CONTRADICTION CHECK — the ruling of 2026-09-25.
#
# A mission was written with a deliberate omission ("deliberately do not build
# the counter"). The planner turned it into a ticket whose acceptance criterion
# certified the counter's ABSENCE; the reviewer checked that ticket criterion,
# found the counter absent, and marked it MET. One line called the missing
# feature a fault (the PRD's own acceptance criterion asks FOR the counter) and
# another certified its absence as correct (the ticket line). The real case
# this exists to catch is exactly that: a MISSING feature quietly certified as
# correct by a ticket that drifted from the requirement it was supposed to
# deliver.
#
# This is decidable HERE, before a pixel is seen, because the contract already
# reads both the PRD's acceptance criteria and the plan's per-ticket criteria.
#
# RECORD, DO NOT INFER — and this time all the way down. The first cut of this
# check read the criterion's PROSE to decide polarity (did the sentence ask FOR
# a thing or for its ABSENCE), and it was beaten twice in one day: once by
# text-matching that guessed the wrong requirement (deleted), and once through a
# CORRECT link, because it classified a NEGATIVE requirement ("Saving is instant
# and never asks the player to name anything") as affirmative and downgraded a
# ticket that CORRECTLY delivered it. Reading English for polarity is the single
# most expensive recurring mistake in this codebase (S147, S156, S188, and this
# very detector twice) — every generation of it has eventually met a document it
# misread. So NOTHING here reads prose for polarity any more.
#
# INSTEAD THE PLANNER DECLARES. When a ticket criterion relates to a PRD
# requirement it names it with `serves` (a `prd-N` id or the requirement's
# verbatim text) AND states which way round it is with `direction`:
#
#     "delivers" — this criterion makes that requirement TRUE.
#     "removes"  — this criterion DELIBERATELY makes it false (an omission the
#                  mission asked for), certifying that the requirement is gone.
#
# A CONTRADICTION is a criterion the planner declared it `removes` against a
# requirement the PRD asks FOR — i.e. a resolved link to a PRIMARY PRD
# acceptance criterion. "Affirmative" is not read from prose here: a PRD
# acceptance criterion IS a stated goal by being on the acceptance list, and a
# ticket that declares it deliberately removes one is certifying a missing
# requirement. A `delivers`, whatever its wording, is never a contradiction —
# which is what stops the "never asks to name" false alarm, since a ticket that
# delivers that requirement declares `delivers`.
#
# There is NO text fallback and NO default. An unlinked criterion (no `serves`)
# is left UNJUDGED and COUNTED, so an unlinked plan reads as "not checked", never
# "clean". A criterion that DID name a requirement but gave no readable
# `direction` is a MALFORMED declaration: recorded by name so it is refused, not
# guessed. Refuse to judge what the planner did not state.
# ===========================================================================


def _norm(text):
    return " ".join(re.sub(r"[^a-z0-9]+", " ", str(text or "").lower()).split())


def _resolve_serves(serves, by_id, by_norm):
    """The primary requirement a `serves` reference names, or None.

    A `prd-N` id first, then the requirement's verbatim (normalised) text. This
    is reference RESOLUTION — a declared pointer looked up — not inference.
    """
    s = str(serves or "").strip()
    if not s:
        return None
    if s in by_id:
        return by_id[s]
    return by_norm.get(_norm(s))


def find_contradictions(criteria):
    """Ticket criteria the planner DECLARED remove the requirement they serve.

    A contradiction is a plan (ticket) criterion whose `direction` the planner
    declared `removes` against a resolved PRIMARY PRD requirement — the ticket
    certifies that a stated goal is deliberately gone. Nothing reads the
    criterion's prose; the direction is the planner's own record.

    Returns (contradictions, marks, unlinked, malformed):
      * `marks`     maps a ticket-criterion id to the prd-id it contradicts, so
                    the caller can stamp the offending criterion.
      * `unlinked`  counts ticket criteria that named no requirement (unjudged).
      * `malformed` lists ticket criteria that DID name a requirement but gave
                    no readable `direction`, each with the field to add — a
                    declaration refused, never silently defaulted.
    """
    primaries = [c for c in criteria
                 if isinstance(c, dict) and c.get("primary") and c.get("text")]
    by_id = {r["id"]: r for r in primaries}
    by_norm = {_norm(r["text"]): r for r in primaries}

    contradictions = []
    marks = {}
    unlinked = 0
    malformed = []
    for c in criteria:
        if not isinstance(c, dict) or c.get("source") != "plan":
            continue
        serves = str(c.get("serves") or "").strip()
        # An unlinked ticket criterion is one the planner named no requirement
        # for. Counted so an unlinked plan reads as "not checked", never "clean".
        if not serves:
            unlinked += 1
            continue
        direction = str(c.get("direction") or "").strip().lower()
        # NAMED A REQUIREMENT BUT DID NOT SAY WHICH WAY ROUND — a malformed
        # declaration. Refused by name (the id and the field to add), never
        # defaulted to delivers or removes: a guessed direction is exactly the
        # inference this design removed.
        if direction not in ("delivers", "removes"):
            malformed.append({
                "id": c["id"], "ticket": c.get("ticket"),
                "serves": serves,
                "problem": ('names a requirement with "serves" but declares no '
                            'readable "direction" — add "direction": "delivers" '
                            '(this criterion makes that requirement true) or '
                            '"direction": "removes" (it deliberately removes it)'),
            })
            continue
        target = _resolve_serves(serves, by_id, by_norm)
        if target is None:
            # A serves that resolves to no PRIMARY requirement: nothing to
            # contradict. Counted as unlinked (the plan reads "not checked"),
            # not guessed at.
            unlinked += 1
            continue
        if direction != "removes":
            continue
        req = target
        marks[c["id"]] = req["id"]
        contradictions.append({
            "requirement": {"id": req["id"], "text": req["text"]},
            "ticketCriterion": {"id": c["id"], "ticket": c.get("ticket"),
                                "text": c.get("text") or ""},
            "direction": ("the ticket criterion declares it deliberately "
                          "REMOVES what requirement %s asks for" % req["id"]),
            "via": "declaration",
        })
    return contradictions, marks, unlinked, malformed


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
    plan_doc = None
    if os.path.exists(plan_path):
        try:
            plan_doc = json.loads(read(plan_path))
            criteria.extend(plan_criteria(plan_doc))
        except Exception:
            plan_doc = None

    contradictions, marks, unlinked, malformed = find_contradictions(criteria)
    for c in criteria:
        if isinstance(c, dict) and c.get("id") in marks:
            c["contradictsRequirement"] = marks[c["id"]]

    # S239 — HOW EACH OF THESE IS REACHED, decided from the record before the
    # look. `served_by` lets a PRD requirement inherit the reach of the ticket
    # that declared it `delivers`: the PRD says WHAT, the ticket says WHERE.
    prd_text = read(os.path.join(mdir, "prd.md"))
    has_draw = has_drawing(mdir)
    ptypes = product_types(mdir, plan_doc, prd_text, has_draw)
    eps = entrypoints(plan_doc)
    eps_by_ticket = {}
    for ep in eps:
        eps_by_ticket.setdefault(ep["ticket"], []).append(ep)
    by_id = {str(c.get("id")): c for c in criteria if isinstance(c, dict)}
    by_norm = {}
    for c in criteria:
        if isinstance(c, dict) and c.get("text"):
            by_norm.setdefault(_norm(c["text"]), c)
    served_by = {}
    for c in criteria:
        if not isinstance(c, dict) or not c.get("serves") or not c.get("ticket"):
            continue
        target = _resolve_serves(c["serves"], by_id, by_norm)
        if target:
            served_by.setdefault(str(target.get("id") or ""), []).append(c["ticket"])
    for c in criteria:
        if not isinstance(c, dict):
            continue
        reach, why = reach_for(c, ptypes, eps_by_ticket, served_by)
        c["reachVia"] = reach
        c["reachViaFrom"] = why

    doc = {
        "mission": os.path.basename(os.path.abspath(mdir)),
        "builtBeforeLaunch": True,
        "productTypes": ptypes,
        "entrypoints": eps,
        "hasDrawing": has_draw,
        "placeNames": place_names(mdir),
        "pictures": pictures(mdir),
        "criteria": criteria,
        "contradictions": contradictions,
        "unlinkedTicketCriteria": unlinked,
        "malformedDeclarations": malformed,
    }
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("%d criteria (%d primary), reached via %s, %d place names, "
          "%d contradiction%s, "
          "%d ticket criteri%s carried no link (not checked), "
          "%d malformed declaration%s" % (
        len(criteria), sum(1 for c in criteria if c.get("primary")),
        ("/".join(sorted({c.get("reachVia") or "?" for c in criteria}))
         or "nothing the record names"),
        len(doc["placeNames"]), len(contradictions),
        "" if len(contradictions) == 1 else "s",
        unlinked, "on" if unlinked == 1 else "a",
        len(malformed), "" if len(malformed) == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
