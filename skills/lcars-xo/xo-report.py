#!/usr/bin/env python3
"""xo-report.py — the First Officer's report: since you last looked, then
folded history, per mission. (Search over it is client-side, in board.js —
see `build_report`'s own docstring below.)

    python3 xo-report.py <missions-dir> <seen-file> [--mission <id>]
                          [--all] [--mark-seen] [--seen-entry <key>]
                          [--format json|text]  (default: text)

ONE BUILDER, TWO RENDERERS (S205 behaviour 6 — "CLI `lcars xo report` == API
split for the same fixture"). `xo.sh report` execs this file for `--format
text` and prints its stdout verbatim; the daemon's `GET /api/xo/report`
execs the very same file for `--format json` and serves its stdout as the
response body. Neither surface re-derives the split independently — both
read the SAME journal files through the SAME function
(`build_report` below), so they cannot drift the way two hand-written
implementations eventually do.

INFER-VS-RECORD (the #1 recurring defect class in this project). Nothing
here parses a human sentence to decide what an entry MEANS: every fact comes
straight off a record —
  * the entries come from each mission's own `number-one.jsonl` (one JSON
    object per line, written by `journal()` in xo.sh);
  * "new since you last looked" comes from comparing each entry's recorded
    `at` timestamp against the RECORDED `lastSeenAt` in `.git/lcars/
    xo-seen.json` — never from guessing at wording;
  * a mission's title/issue come straight off its own `state.json`.
Nothing is deleted, ever: `--mark-seen` only advances `lastSeenAt` and
`--seen-entry` only adds one key to a set, both of which move entries from
"since" to "history" on the NEXT read — the journal files themselves are
never touched by this script.
"""
import json
import os
import sys


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def _load_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        pass
    return out


def _mission_meta(mdir):
    st = _load_json(os.path.join(mdir, "state.json"))
    st = st if isinstance(st, dict) else {}
    mid = st.get("id")
    if not (isinstance(mid, str) and mid.strip()):
        mid = os.path.basename(mdir)
    title = st.get("title")
    if not (isinstance(title, str) and title.strip()):
        title = mid
    issue = st.get("githubIssue")
    if isinstance(issue, str) and issue.isdigit():
        issue = int(issue)
    if not isinstance(issue, int):
        issue = None
    # The mission's OWN recorded Number One block — its score and its status,
    # echoed, never re-derived from the journal's wording. The board's mission
    # header wears them as its chip.
    xo = st.get("numberOne")
    xo = xo if isinstance(xo, dict) else {}
    score = xo.get("score")
    score = score.strip().lower() if isinstance(score, str) and score.strip() else None
    status = xo.get("status")
    status = status.strip() if isinstance(status, str) and status.strip() else None
    return {"id": mid, "title": title, "issue": issue,
            "score": score, "xoStatus": status}


# ── S213: THE THREE RANKS ───────────────────────────────────────────────────
#
# The captain's complaint about the flat report was not that it was long. It
# was that an observation and a personal escalation carried IDENTICAL WEIGHT,
# so there was no way to tell news from machinery. Three ranks answer that:
#
#   needs-you  he has to do something, and nothing moves until he does
#   verdict    Number One reached a conclusion he should read
#   step       something the machine did on the way there — real, kept, folded
#
# IT IS A LOOKUP ON THE RECORDED `action`, NEVER A READING OF THE PROSE. This
# project has lost four rounds (S147, S156, S188, S212) to code that decided
# what a line MEANT by matching words a human also writes. Every action here is
# one `journal()` in xo.sh writes; an action nobody has classified ranks as a
# step, which is the safe direction — a step is kept and folded, never dropped.
NEEDS_YOU_ACTIONS = ("escalated", "overflow", "fix-did-not-hold")
VERDICT_ACTIONS = ("scored", "rescored", "score-overruled", "answered",
                   "stood-down", "silent")


def entry_rank(action):
    a = str(action or "")
    if a in NEEDS_YOU_ACTIONS:
        return "needs-you"
    if a in VERDICT_ACTIONS:
        return "verdict"
    return "step"


def entry_key(mission_id, seq):
    """THE STABLE NAME OF ONE ENTRY, so ✓ Seen can mark exactly it.

    `<mission id>#<position in its own journal>`. The journal is append-only
    and nothing is ever removed from it (this file's oldest promise), so a
    position is a permanent name — unlike a timestamp, which two entries in
    the same second would share, and unlike a hash of the text, which would
    change if a renderer ever reformatted a line."""
    return "%s#%d" % (mission_id, seq)


def gather_missions(missions_dir, mission_filter=None):
    """Every mission carrying a `number-one.jsonl`, each with its entries in
    RECORDED (chronological) order. A mission with no journal at all is
    absent — there is nothing Number One has ever said about it."""
    out = []
    if not os.path.isdir(missions_dir):
        return out
    for name in sorted(os.listdir(missions_dir)):
        if mission_filter and name != mission_filter:
            continue
        mdir = os.path.join(missions_dir, name)
        if not os.path.isdir(mdir):
            continue
        entries = _load_jsonl(os.path.join(mdir, "number-one.jsonl"))
        if not entries:
            continue
        meta = _mission_meta(mdir)
        rows = []
        for e in entries:
            row = dict(e)
            row["mission"] = meta["id"]
            rows.append(row)
        rows.sort(key=lambda r: (r.get("at") or "", ))
        # THE KEY IS STAMPED AFTER THE SORT, so it names the entry's position
        # in the order every surface reads it in, and stays the same on every
        # read of the same journal.
        for seq, row in enumerate(rows):
            row["key"] = entry_key(meta["id"], seq)
            row["rank"] = entry_rank(row.get("action"))
        out.append({"id": meta["id"], "title": meta["title"],
                     "issue": meta["issue"], "entries": rows,
                     "score": meta["score"], "xoStatus": meta["xoStatus"]})
    return out


def read_seen(seen_path):
    doc = _load_json(seen_path)
    if isinstance(doc, dict):
        ts = doc.get("lastSeenAt")
        if isinstance(ts, str) and ts.strip():
            return ts.strip()
    return None


def read_seen_entries(seen_path):
    """The set of entry keys the captain has personally cleared (S213).

    A SECOND, FINER MARK BESIDE `lastSeenAt`, not a replacement for it. The
    wholesale "I have read the whole report" mark still moves one timestamp;
    this is "I have dealt with THIS one", and it has to name the one."""
    doc = _load_json(seen_path)
    if isinstance(doc, dict):
        keys = doc.get("seenEntries")
        if isinstance(keys, list):
            return set(k for k in keys if isinstance(k, str) and k.strip())
    return set()


def _write_seen_doc(seen_path, doc):
    d = os.path.dirname(seen_path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = seen_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
        fh.write("\n")
    os.replace(tmp, seen_path)


def write_seen(seen_path, ts):
    """Advance the wholesale mark, KEEPING the per-entry set. A captain who
    marks the whole report read has not un-dealt-with anything he had already
    dealt with individually."""
    doc = _load_json(seen_path)
    doc = doc if isinstance(doc, dict) else {}
    doc["lastSeenAt"] = ts
    _write_seen_doc(seen_path, doc)


def mark_entry_seen(seen_path, key):
    """✓ Seen on ONE entry.

    SEEN MEANS "I HAVE DEALT WITH THIS", NEVER "THIS IS GONE". This adds a key
    to a set and does nothing else: no journal file is opened, nothing is
    rewritten, nothing is removed. The entry keeps its place in `history`
    forever — the next `build_report` simply stops calling it new."""
    key = str(key or "").strip()
    if not key:
        return False
    doc = _load_json(seen_path)
    doc = doc if isinstance(doc, dict) else {}
    keys = doc.get("seenEntries")
    keys = [k for k in keys if isinstance(k, str)] if isinstance(keys, list) else []
    if key not in keys:
        keys.append(key)
    doc["seenEntries"] = keys
    _write_seen_doc(seen_path, doc)
    return True


def build_report(missions_dir, seen_path, mission_filter=None):
    """{"lastSeenAt": str|None, "since": {"count", "entries"},
        "history": [{"id","title","issue","entries"}]}

    `entries` are ALWAYS newest-first (the display order — "History (…),
    newest first"). Every entry carries `new` (bool), `mission`, `missionTitle`
    and `missionIssue` so a flat "since" list is self-describing without a
    second lookup. NOTHING is ever dropped from `history` — an entry that is
    "new" still appears there too (S205 behaviour 4: "Seen moves them to
    history … nothing deleted").

    SEARCH IS NOT DONE HERE, DELIBERATELY (the IMPLEMENTOR BRIEF's own
    words: "search is client-side over the payload"). This returns the whole
    since/history payload; board.js filters what it already fetched, so a
    second, independent search implementation can never disagree with the
    first about what "matches" means.
    """
    missions = gather_missions(missions_dir, mission_filter)
    last_seen_at = read_seen(seen_path)
    seen_keys = read_seen_entries(seen_path)

    since = []
    history = []
    grouped = []
    total = 0
    for m in missions:
        meta = {"id": m["id"], "title": m["title"], "issue": m["issue"]}
        newest_first = list(reversed(m["entries"]))
        rows = []
        for e in newest_first:
            row = dict(e)
            # NEW = past the wholesale mark AND not personally cleared. Two
            # marks, one answer; either one having been made is enough to
            # take an entry out of the news.
            fresh = (last_seen_at is None) or \
                ((row.get("at") or "") > last_seen_at)
            row["new"] = bool(fresh) and row.get("key") not in seen_keys
            row["missionTitle"] = meta["title"]
            row["missionIssue"] = meta["issue"]
            rows.append(row)
            total += 1
            if row["new"]:
                since.append(row)
        history.append({"id": meta["id"], "title": meta["title"],
                         "issue": meta["issue"], "entries": rows})
        grouped.append(_group_one_mission(m, rows))

    since.sort(key=lambda r: (r.get("at") or ""), reverse=True)
    # Missions with the most recent activity first (folded newest-first).
    history.sort(
        key=lambda h: (h["entries"][0].get("at") if h["entries"] else ""),
        reverse=True)
    # C11 — THE CAPTAIN'S RULING, 2026-09-17. A needs-you ITEM does not float
    # out of its block; its MISSION sorts first, block intact. His reason, and
    # it is the whole design: the grouping stays pure, and he sees the item AND
    # the context it happened in. Within each half, newest news first (C4).
    grouped.sort(key=lambda g: (0 if g["needsYou"] else (1 if g["newCount"] else 2),
                                 _invert(g["newestAt"])))
    return {
        "lastSeenAt": last_seen_at,
        "since": {"count": len(since), "entries": since},
        "history": history,
        "missions": grouped,
        "counts": {
            "needs": len([e for e in since if e.get("rank") == "needs-you"]),
            "verdicts": len([e for e in since if e.get("rank") == "verdict"]),
            "all": len(since),
        },
        # What the History line says: "N already seen, kept for good." It is
        # the entries this report is STILL CARRYING and no longer calling new
        # — never a count of anything deleted, because nothing ever is.
        "seenCount": total - len(since),
    }


class _invert(object):
    """Sort a string DESCENDING inside an otherwise ascending key."""

    __slots__ = ("v",)

    def __init__(self, v):
        self.v = v or ""

    def __lt__(self, other):
        return self.v > other.v

    def __eq__(self, other):
        return self.v == other.v


def _group_one_mission(mission, rows_newest_first):
    """One mission's block for the grouped view, or None when it has no news.

    LIFECYCLE STEPS FOLD UNDER THE VERDICT THEY LED TO. Walking the journal in
    the order it was written, the steps that happened before a conclusion are
    the steps that produced it, so they hang off it — `⌄ 6 steps it took to get
    there` — rather than competing with it for the captain's eye. Steps with no
    conclusion after them yet are not news and do not put a mission on the
    board; the mission shows up when Number One has something to SAY.
    """
    oldest_first = list(reversed(rows_newest_first))
    pending = []
    tops = []
    for row in oldest_first:
        if row.get("rank") == "step":
            pending.append(row)
            continue
        entry = dict(row)
        entry["steps"] = pending
        pending = []
        tops.append(entry)
    new_tops = [t for t in tops if t.get("new")]
    new_tops.reverse()  # newest first, the display order
    needs = any(t.get("rank") == "needs-you" for t in new_tops) \
        or mission.get("xoStatus") == "escalated"
    # EVERY mission with a journal gets a block, INCLUDING one with nothing new.
    # C6: clearing a mission's last entry DIMS it and re-tags it — it does not
    # make it disappear. A mission that vanishes the moment you deal with it
    # takes its context with it, and the captain's question about the quiet
    # ones was "does it stay out of my way WITHOUT VANISHING". `newCount: 0`
    # is what the board dims on; the newest timestamp is kept either way so a
    # quiet block still sorts sensibly among its peers.
    newest_at = max([t.get("at") or "" for t in (new_tops or tops)] or [""])
    return {
        "id": mission["id"],
        "title": mission["title"],
        "issue": mission["issue"],
        "score": mission.get("score"),
        "xoStatus": mission.get("xoStatus"),
        "needsYou": bool(needs),
        "newCount": len(new_tops),
        "newestAt": newest_at,
        "entries": new_tops,
    }


# --- text rendering (the CLI's own voice) -----------------------------------
def _fmt_entry(e, with_mission=True):
    who = ""
    if with_mission:
        issue = "#%s" % e.get("missionIssue") if e.get("missionIssue") else e.get("mission")
        who = "%s (%s) — " % (e.get("missionTitle") or e.get("mission"), issue)
    detail_bits = []
    for k in ("detail", "why", "note", "summary", "url", "score", "round"):
        v = e.get(k)
        if isinstance(v, str) and v.strip():
            detail_bits.append(v.strip())
            break
    detail = (" — " + detail_bits[0]) if detail_bits else ""
    indent = "  " if with_mission else "    "
    return "%s%s  %s%s%s" % (indent, e.get("at") or "?", who,
                              e.get("action") or "?", detail)


def render_text(report, show_all):
    lines = []
    since = report["since"]
    lines.append("Since you last looked (%d):" % since["count"])
    if since["count"] == 0:
        lines.append("  Nothing new.")
    else:
        for e in since["entries"]:
            lines.append(_fmt_entry(e))
    lines.append("")
    lines.append("History:")
    any_hist = False
    for m in report["history"]:
        if not m["entries"]:
            continue
        any_hist = True
        issue = "#%s" % m["issue"] if m["issue"] else m["id"]
        lines.append("  %s (%s)" % (m["title"] or m["id"], issue))
        rows = m["entries"] if show_all else m["entries"][:10]
        for e in rows:
            lines.append(_fmt_entry(e, with_mission=False))
        if not show_all and len(m["entries"]) > len(rows):
            lines.append("    … %d more (use --all to see every entry)"
                          % (len(m["entries"]) - len(rows)))
    if not any_hist:
        lines.append("  (no history yet)")
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) < 3:
        print("usage: xo-report.py <missions-dir> <seen-file> [--mission <id>] "
              "[--all] [--mark-seen] [--seen-entry <key>] [--format json|text]",
              file=sys.stderr)
        return 2
    missions_dir, seen_path = argv[1], argv[2]
    mission_filter = None
    show_all = False
    mark_seen = False
    seen_entry = None
    fmt = "text"
    rest = argv[3:]
    j = 0
    while j < len(rest):
        a = rest[j]
        if a == "--mission":
            j += 1
            mission_filter = rest[j] if j < len(rest) else None
        elif a == "--all":
            show_all = True
        elif a == "--mark-seen":
            mark_seen = True
        elif a == "--seen-entry":
            j += 1
            seen_entry = rest[j] if j < len(rest) else None
        elif a == "--format":
            j += 1
            fmt = rest[j] if j < len(rest) else "text"
        j += 1

    # ONE ENTRY, MARKED BEFORE THE REPORT IS BUILT, so the answer this call
    # returns is the board AFTER the click — the caller never has to ask twice
    # to find out what changed.
    if seen_entry:
        mark_entry_seen(seen_path, seen_entry)

    report = build_report(missions_dir, seen_path, mission_filter)

    if mark_seen:
        # Advance to NOW, not to the newest entry's timestamp: a captain who
        # opens the report and sees nothing new yet should not have a LATER
        # entry (posted a second after they opened it) silently swallowed —
        # "seen" means "as of the moment I looked", never "as of the last
        # thing I saw".
        import datetime
        now = datetime.datetime.now(datetime.timezone.utc) \
            .strftime("%Y-%m-%dT%H:%M:%SZ")
        write_seen(seen_path, now)
        report["markedSeenAt"] = now

    if fmt == "json":
        json.dump(report, sys.stdout)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_text(report, show_all))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
