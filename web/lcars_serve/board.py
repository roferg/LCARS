"""The ONE adapter-neutral board data shape (ADR-003).

Both the LOCAL adapter (`.git/lcars` reader) and the GITHUB adapter (issues +
`lcars:*` labels reader) produce EXACTLY this shape; the renderer/front end
depends only on it and never on which adapter served it. Keeping the shape — and
the column-placement, pill-derivation and ticket-state logic that fills it — in
ONE module is what makes "view-only on Pages a configuration, not a rewrite".

Board shape:
    {
      "stages":  ["align", ..., "done"],          # pipeline order, source of column order
      "columns": { "<stage>": [missionCard, ...] },# every active mission in its column
      "missions":[ missionCard, ... ]              # flat list (column-independent)
    }

missionCard:
    {
      "id":       "lcars-...",        # mission id (dir name / state.id)
      "issue":    142 | None,         # GitHub issue number (None if unfiled)
      "title":    "...",
      "type":     "feature" | "bug",
      "stage":    "research",         # the COLUMN it belongs to (gate rule applied)
      "awaiting": bool,               # lcars:awaiting-human → AWAITING YOU state
      "paused":   bool,               # lcars:paused
      "question": "..." | None,       # pending gate question when awaiting
      "linked":   bool,               # child bug mission (lcars:linked) → pink card
      "pills": {
        "cost":           { "unit": "usd"|"premiumRequests", "low":.., "high":.., "label": "~$6.40" } | None,
        "reasoning":      { "level": "low"|"medium"|"high", "label": "REASON …" } | None,
        "implementation": { "level": "low"|"medium"|"high", "label": "IMPL …" } | None
      },
      "progress": { "wave":1, "wavesTotal":3, "ticketsDone":4, "ticketsTotal":7,
                    "label": "WAVE 1/3 · TICKET 4/7" } | None,
      "tickets": [ { "id":"t-001", "issue":201|None, "title":"…",
                     "state":"done"|"in-progress"|"flagged"|"pending" } ]
    }
"""

# Pipeline order — the column order. Mirrors LCARS_STAGE_LABELS in
# skills/lcars-init/lcars-common.sh. "done" is the terminal column: done
# missions DO render there (PRD §5.1, one column per Stage label), but are kept
# out of the active `missions` count (see assemble()).
STAGES = (
    "align", "research", "validate", "plan", "plan-review",
    "schedule", "implement", "verify", "done",
)

# Stage label aliases: the schedule.md/lcars stage key "plan-review" is also seen
# spelled "plan_review"/"review" in some surfaces; normalise to the label form.
_STAGE_ALIASES = {
    "planreview": "plan-review",
    "plan_review": "plan-review",
    "review": "plan-review",
}


def normalise_stage(stage):
    """Map any stage spelling to a canonical column key; unknown → 'align'."""
    if not stage:
        return "align"
    s = str(stage).strip().lower()
    s = _STAGE_ALIASES.get(s, s)
    return s if s in STAGES else "align"


# --- difficulty levels: low / med / high ------------------------------------
_LEVELS = {"low": "low", "medium": "medium", "med": "medium", "high": "high"}
# dot glyphs mirror the mockup's "●●○" / "●●●" idiom (low/med/high).
_LEVEL_DOTS = {"low": "●○○", "medium": "●●○",
               "high": "●●●"}


def _level(value):
    if value is None:
        return None
    return _LEVELS.get(str(value).strip().lower())


def difficulty_pill(kind, value):
    """kind is 'reasoning' or 'implementation'. Returns a pill dict or None."""
    lvl = _level(value)
    if lvl is None:
        return None
    label = {"reasoning": "REASON", "implementation": "IMPL"}[kind]
    return {"level": lvl, "label": "%s %s %s" % (label, _LEVEL_DOTS[lvl], lvl.upper())}


def cost_pill(cost):
    """Map an estimate.json `cost` block to a cost pill (engine-unit aware).

    Claude → usd {low,high}; legacy Copilot → premiumRequests {low,high};
    usage Copilot → usd via netUsd. Returns None for absent/unavailable cost.
    """
    if not isinstance(cost, dict):
        return None
    if cost.get("status") == "unavailable":
        return {"unit": cost.get("unit", "usd"), "low": None, "high": None,
                "label": "EST. UNAVAILABLE"}
    unit = cost.get("unit")
    if unit == "usd":
        band = cost.get("netUsd") or cost.get("usd") or {}
        low, high = band.get("low"), band.get("high")
        if low is None and high is None:
            return None
        return {"unit": "usd", "low": low, "high": high,
                "label": _usd_label(low, high)}
    if unit == "premiumRequests":
        band = cost.get("premiumRequests") or {}
        low, high = band.get("low"), band.get("high")
        if low is None and high is None:
            return None
        return {"unit": "premiumRequests", "low": low, "high": high,
                "label": _req_label(low, high)}
    return None


def _fmt_usd(v):
    return ("$%.2f" % float(v)).rstrip("0").rstrip(".") if "." in ("$%.2f" % float(v)) else "$%.2f" % float(v)


def _usd_label(low, high):
    if low is None:
        return "~$%.2f" % float(high)
    if high is None or low == high:
        return "~$%.2f" % float(low)
    return "$%.2f–$%.2f" % (float(low), float(high))


def _req_label(low, high):
    if low is None:
        return "~%g reqs" % float(high)
    if high is None or low == high:
        return "~%g reqs" % float(low)
    return "%g–%g reqs" % (float(low), float(high))


def pills_from_estimate(estimate):
    """Build the {cost, reasoning, implementation} pill set from estimate.json."""
    est = estimate or {}
    return {
        "cost": cost_pill(est.get("cost")),
        "reasoning": difficulty_pill("reasoning", est.get("reasoningCriticality")),
        "implementation": difficulty_pill("implementation", est.get("implCriticality")),
    }


def empty_board():
    return {"stages": list(STAGES),
            "columns": {s: [] for s in STAGES},
            "missions": []}


def assemble(cards):
    """Place a flat list of mission cards into columns by their `stage`.

    Every card lands in its Stage column — INCLUDING 'done' (PRD §5.1: nine
    columns, one per Stage label, and Done is the `lcars:done` Stage). But done
    missions stay OUT of the `missions` list: that list backs the front end's "N
    active missions" count, which must mean work still in flight, so adding the
    Done column must not inflate it. Cards keep their input order within a column
    (callers sort newest-first beforehand).

    NOTE (future enhancement): done missions are included unbounded here. If the
    Done column ever grows uncomfortably large, cap/paginate it at this seam —
    deliberately not built now (simple + PRD-faithful for this round).
    """
    board = empty_board()
    for c in cards:
        stage = normalise_stage(c.get("stage"))
        c["stage"] = stage
        board["columns"][stage].append(c)
        if stage != "done":
            board["missions"].append(c)
    return board
