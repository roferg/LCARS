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
      "running":  bool,               # a LIVE `run drive` driver holds the mission
                                      #   lock (S67 BUG-A). LOCAL adapter only;
                                      #   github adapter omits/false (can't see it).
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


# --- active run time (UX-24) -------------------------------------------------
# Event types that OPEN a human-wait / paused interval (time the captain owns,
# not the run) and the types that CLOSE it. A `gate` raises an awaiting-human
# wait (research>20, validate scope, plan-review standoff, implement flagged,
# AND the verify review gate); `paused` halts the run. Both are reopened/closed
# by the run resuming: respond/resume don't emit their own event, so the close
# is the NEXT `stage_start` (the resumed run) — or `resumed` for an explicit
# resume. An interval still open at the end (currently parked / paused) is
# excluded up to `now`.
_WAIT_OPEN = ("gate", "paused")
_WAIT_CLOSE = ("stage_start", "resumed", "stage_done")


def active_seconds(events, now=None):
    """Seconds of ACTIVE (non-human-wait, non-paused) run time for a mission.

    Wall-clock from the first `stage_start` to the last event (or `now` if an
    interval is still open at the end), MINUS every awaiting-human / paused
    interval. Returns an int; 0 before any stage_start. `now` is injected by the
    caller (and the tests) so the result is deterministic and never reads the
    real clock here.

    Adapter-neutral: the github adapter, lacking event timing, passes no events
    and gets 0 (ADR-006 — non-crashing, not necessarily exact).
    """
    rows = []
    for ev in (events or []):
        if not isinstance(ev, dict):
            continue
        ts = ev.get("ts")
        typ = ev.get("type")
        if not isinstance(ts, (int, float)) or not typ:
            continue
        rows.append((ts, typ))
    if not rows:
        return 0
    rows.sort(key=lambda r: r[0])

    start = None
    for ts, typ in rows:
        if typ == "stage_start":
            start = ts
            break
    if start is None:
        return 0

    last_ts = rows[-1][0]

    # Pass 1: build the human-wait / paused intervals. A wait OPENS at the first
    # _WAIT_OPEN seen while not already waiting, and CLOSES at the next
    # _WAIT_CLOSE. Consecutive gate events (the driver re-emits `gate` each pass
    # while still awaiting) collapse into the one open interval. `open_at` left
    # set after the pass means the mission is STILL parked / paused at the end.
    intervals = []
    open_at = None
    for ts, typ in rows:
        if open_at is None:
            if typ in _WAIT_OPEN:
                open_at = ts
        else:
            if typ in _WAIT_CLOSE:
                intervals.append((open_at, ts))
                open_at = None

    # The wall-clock end of the span. A CLOSED run (no open interval) ends at the
    # last event. An OPEN interval (currently parked at a gate / paused) runs to
    # `now` — that open human-wait is then excluded up to now, so it never counts.
    if open_at is not None and now is not None and now > last_ts:
        end = now
        intervals.append((open_at, end))
    else:
        end = last_ts
        if open_at is not None:
            intervals.append((open_at, end))

    excluded = 0
    for lo, hi in intervals:
        lo = max(lo, start)
        hi = min(hi, end)
        if hi > lo:
            excluded += hi - lo

    active = (end - start) - excluded
    if active < 0:
        active = 0
    return int(active)


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
    usage Copilot → usd. Returns None for absent/unavailable cost.

    UX-15: for Copilot usage billing the estimate carries BOTH `usd` (GROSS) and
    `netUsd` (after includedCreditsUsd, often $0). The pill must show the GROSS
    range — matching the Claude pill, which is gross — so a real, non-zero
    estimate never renders as a misleading bare $0 "after credits". We therefore
    prefer `usd` (gross) and only fall back to `netUsd` when gross is absent.
    """
    if not isinstance(cost, dict):
        return None
    if cost.get("status") == "unavailable":
        return {"unit": cost.get("unit", "usd"), "low": None, "high": None,
                "label": "EST. UNAVAILABLE"}
    unit = cost.get("unit")
    if unit == "usd":
        # GROSS first (cost.usd); netUsd only as a fallback when gross is absent.
        band = cost.get("usd") or cost.get("netUsd") or {}
        low, high = band.get("low"), band.get("high")
        if low is None and high is None:
            return None
        pill = {"unit": "usd", "low": low, "high": high,
                "label": _usd_label(low, high)}
        # Keep net available to the front end (not shown on the pill) so a later
        # "after credits" affordance needs no schema change.
        net = cost.get("netUsd")
        if isinstance(net, dict):
            pill["netLow"], pill["netHigh"] = net.get("low"), net.get("high")
        return pill
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


# --- S113: ACTUAL usage (display-only, sibling of estimate.json) --------------
# S112 appends one usage record per cold-worker spawn to `$MISSION_DIR/usage.json`
# (JSONL). Each record carries a code-computed cost (`costUsd`/`cost`), a
# `billingUnit` ("usd"|"premiumRequests" — the unit the card renders, matching
# the estimate pill's unit rules), `premiumRequests` (copilot-legacy), token
# counts, and a `source` ("session-transcript"|"session-state"|"unavailable").
# This is DISPLAY-ONLY: we never mutate usage.json / estimate.json and never feed
# actuals back into the estimator.


def sum_usage(records):
    """Sum usage.json (JSONL) records into per-mission totals.

    MIRRORS run.sh `cmd_usage` (the `run.sh usage <mission>` subcommand) so the
    pill and the CLI agree: sum `costUsd` (float), `premiumRequests` (int), and
    input/output tokens (int). `unit` is the records' `billingUnit` (first one
    seen; one mission == one engine, so they agree). ANY record marked
    `source":"unavailable"` flags the totals `partial` — an honest "we could not
    read every stage's usage" marker, never a silently-wrong total.

    Returns None when there are NO records at all (no usage → no actual pill →
    the no-usage render stays byte-identical). Crash-proof: malformed rows are
    skipped, never raised.
    """
    rows = [r for r in (records or []) if isinstance(r, dict)]
    if not rows:
        return None
    tot = {"records": 0, "inputTokens": 0, "outputTokens": 0,
           "usd": 0.0, "premiumRequests": 0, "partial": False, "unit": None}
    for d in rows:
        tot["records"] += 1
        for k in ("inputTokens", "outputTokens", "premiumRequests"):
            try:
                tot[k] += int(d.get(k, 0) or 0)
            except (TypeError, ValueError):
                pass
        try:
            tot["usd"] += float(d.get("costUsd", 0) or 0)
        except (TypeError, ValueError):
            pass
        if d.get("source") == "unavailable":
            tot["partial"] = True
        bu = d.get("billingUnit")
        if bu and tot["unit"] is None:
            tot["unit"] = bu
    if tot["unit"] is None:
        tot["unit"] = "usd"
    return tot


def actual_pill(totals):
    """Render summed usage TOTALS (from sum_usage) as an ACTUAL cost pill.

    Same billing-unit rules as `cost_pill` (reusing `_usd_label`/`_req_label`) so
    the EST and ACTUAL pills read in the SAME unit: claude / copilot-usage → usd;
    copilot-legacy → premiumRequests ("reqs"). The pill carries a single `value`
    (actuals are a point, not a band). When any stage's usage was `unavailable`
    the totals are `partial`, and the pill is marked honestly ("· partial" label
    suffix + a `partial:true` flag the front end can style).

    Returns None when `totals` is falsy / has no records (no actual to show).
    """
    if not isinstance(totals, dict) or not totals.get("records"):
        return None
    partial = bool(totals.get("partial"))
    unit = totals.get("unit") or "usd"
    if unit == "premiumRequests":
        value = totals.get("premiumRequests") or 0
        label = _req_label(value, None)
    else:
        unit = "usd"
        value = totals.get("usd") or 0.0
        label = _usd_label(value, None)
    if partial:
        label = label + " · partial"
    return {"unit": unit, "value": value, "label": label, "partial": partial}


# --- S70-B: per-stage model mix (Launch panel) ------------------------------
# The estimator persists a per-stage model map in estimate.json under `models`,
# keyed by the stage camelCase key, with a logical tier value ("opus"/"sonnet").
# `rationale` is a SINGLE top-level field (one "why" for the whole mix), so the
# same rationale text rides every row's `why`. Display labels mirror the issue
# body's table (render_estimate_issue() in run.sh — the source of truth).
_MODEL_STAGE_ORDER = ("research", "validate", "plan", "planReview",
                      "implement", "verify")
_MODEL_STAGE_LABELS = {
    "research": "Research", "validate": "Validate", "plan": "Plan",
    "planReview": "Plan Review", "implement": "Implement", "verify": "Verify",
}


# The per-(cli, tier) alias defaults — the SHAPE-layer mirror of run.sh's
# `alias_for_tier`. copilot is OPUS-SAFE by default (its create-tool cannot
# overwrite on a non-opus tier, so Implement breaks); claude's tiers pass through.
# Kept beside effective_tier so the two move together.
DEFAULT_MODEL_ALIASES = {
    "claude":  {"sonnet": "sonnet",           "opus": "opus"},
    "copilot": {"sonnet": "claude-opus-4.8",  "opus": "claude-opus-4.8"},
}


def effective_tier(cli, tier, model_aliases=None):
    """The tier that will ACTUALLY run for (cli, logical tier) — the viewport's
    mirror of run.sh's `effective_tier_for_cli` (S147 round 2).

    The board used to hard-code "copilot ⇒ opus". That was right for the default
    but became a DIVERGENCE the moment the CLI learned to honour a repo's
    `modelAliases.<cli>.<tier>` override: the same mission then read Sonnet in
    the terminal and Opus on the board. The UI is a viewport, never a
    reimplementation, so resolve exactly the way the harness does — take the
    repo's alias override when present, fall back to the shipped default, and
    classify the resulting model string back to a tier.
    """
    tier = str(tier or "").strip().lower()
    cli = str(cli or "").strip().lower()
    override = ((model_aliases or {}).get(cli) or {}).get(tier)
    alias = override if isinstance(override, str) and override.strip() else \
        (DEFAULT_MODEL_ALIASES.get(cli) or {}).get(tier)
    if not alias:
        return tier            # unknown cli/tier: nothing better to claim
    a = alias.strip().lower()
    if "opus" in a:
        return "opus"
    if "sonnet" in a:
        return "sonnet"
    if "haiku" in a:
        return "haiku"
    return tier


def model_mix_from_estimate(estimate, engine=None, model_aliases=None):
    """Build `[{stage, tier, why}]` from estimate.json. None when absent.

    Returns None (not []) when there is no `models` map, so the front end shows
    its graceful note rather than an empty table.

    Mission-log-grounding round: the mix is driven PURELY by what the estimate
    actually carries — one row per stage present in the `models` map. A logged
    bug now walks the FULL pipeline (Research grounding → Validate → …), so the
    estimator scores all six stages and this shows all six rows including
    Research + Validate. A genuinely fast-tracked bug (legacy/none) whose
    estimate.json omits research/validate from `models` naturally shows only the
    stages it runs — no is_bug special-case needed, and it can never regress into
    empty Research/Validate rows because absent keys add no row. This removed the
    old S74 bug-skip filter (which dropped Research/Validate even when the
    estimate carried them) now that a logged bug genuinely runs those stages.

    `engine` (S78 CHANGE 4): per-engine model resolution AT THE SHAPE LAYER. A
    COPILOT mission is OPUS-SAFE (its create-tool can't overwrite on a non-opus
    tier → Implement breaks), so the DISPLAYED mix must show `opus` on EVERY row
    — mirroring the harness's alias_for_tier copilot default. A CLAUDE mission
    (or an unknown engine) keeps the estimate's per-stage tiers. Adapter-neutral
    (ADR-006): this is the render shape only; resolution by engine basename, no
    coupling to the write layer.
    """
    est = estimate or {}
    models = est.get("models")
    if not isinstance(models, dict) or not models:
        return None
    why = est.get("rationale") or None
    # Engine selection by basename (mirrors _session_args / alias_for_tier): the
    # value may be a bare id ("copilot") or a path ("/usr/bin/copilot").
    _eng = str(engine or "").replace("\\", "/").rsplit("/", 1)[-1].lower()
    _cli = "copilot" if "copilot" in _eng else "claude"

    def _tier(val):
        # S147 round 2: resolve through the SAME policy the harness uses (alias
        # defaults + the repo's modelAliases override) instead of hard-coding
        # "copilot ⇒ opus", so the board and the CLI can never disagree.
        return effective_tier(_cli, val, model_aliases)

    rows = []
    # Keep the canonical stage order; tolerate extra/missing keys gracefully.
    seen = set()
    for key in _MODEL_STAGE_ORDER:
        if key in models and models[key]:
            rows.append({"stage": _MODEL_STAGE_LABELS.get(key, key),
                         "tier": _tier(models[key]),
                         "why": why})
            seen.add(key)
    for key, val in models.items():
        if key not in seen and val:
            rows.append({"stage": _MODEL_STAGE_LABELS.get(key, key),
                         "tier": _tier(val), "why": why})
    return rows or None


def empty_meta():
    """The board-level identity block (S70-A). Always present in the shape so the
    front end can render "which repo am I attached to" unconditionally.

    meta = {
      "repo":    "<owner/name> or directory basename",  # never None
      "adapter": "local" | "github",
      "mode":    "read-write" | "read-only",            # write layer active?
    }
    """
    return {"repo": "", "adapter": "local", "mode": "read-only"}


def empty_board():
    return {"stages": list(STAGES),
            "columns": {s: [] for s in STAGES},
            "missions": [],
            "meta": empty_meta()}


def assemble(cards, meta=None):
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
    if isinstance(meta, dict):
        board["meta"].update({k: v for k, v in meta.items() if v is not None})
    for c in cards:
        stage = normalise_stage(c.get("stage"))
        c["stage"] = stage
        board["columns"][stage].append(c)
        if stage != "done":
            board["missions"].append(c)
    return board
