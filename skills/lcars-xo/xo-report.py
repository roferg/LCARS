#!/usr/bin/env python3
"""xo-report.py — the First Officer's report: since you last looked, then
folded history, per mission. (Search over it is client-side, in board.js —
see `build_report`'s own docstring below.)

    python3 xo-report.py <missions-dir> <seen-file> [--mission <id>]
                          [--all] [--mark-seen]
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
Nothing is deleted, ever: `--mark-seen` only advances `lastSeenAt`, which
moves entries from "since" to "history" on the NEXT read — the journal
files themselves are never touched by this script.
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
    return {"id": mid, "title": title, "issue": issue}


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
        out.append({"id": meta["id"], "title": meta["title"],
                     "issue": meta["issue"], "entries": rows})
    return out


def read_seen(seen_path):
    doc = _load_json(seen_path)
    if isinstance(doc, dict):
        ts = doc.get("lastSeenAt")
        if isinstance(ts, str) and ts.strip():
            return ts.strip()
    return None


def write_seen(seen_path, ts):
    d = os.path.dirname(seen_path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = seen_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"lastSeenAt": ts}, fh)
        fh.write("\n")
    os.replace(tmp, seen_path)


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

    since = []
    history = []
    for m in missions:
        meta = {"id": m["id"], "title": m["title"], "issue": m["issue"]}
        newest_first = list(reversed(m["entries"]))
        rows = []
        for e in newest_first:
            row = dict(e)
            row["new"] = (last_seen_at is None) or \
                ((row.get("at") or "") > last_seen_at)
            row["missionTitle"] = meta["title"]
            row["missionIssue"] = meta["issue"]
            rows.append(row)
            if row["new"]:
                since.append(row)
        history.append({"id": meta["id"], "title": meta["title"],
                         "issue": meta["issue"], "entries": rows})

    since.sort(key=lambda r: (r.get("at") or ""), reverse=True)
    # Missions with the most recent activity first (folded newest-first).
    history.sort(
        key=lambda h: (h["entries"][0].get("at") if h["entries"] else ""),
        reverse=True)
    return {
        "lastSeenAt": last_seen_at,
        "since": {"count": len(since), "entries": since},
        "history": history,
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
              "[--all] [--mark-seen] [--format json|text]",
              file=sys.stderr)
        return 2
    missions_dir, seen_path = argv[1], argv[2]
    mission_filter = None
    show_all = False
    mark_seen = False
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
        elif a == "--format":
            j += 1
            fmt = rest[j] if j < len(rest) else "text"
        j += 1

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
