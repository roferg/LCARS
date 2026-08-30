#!/usr/bin/env python3
"""C1 — the ANSWER-FROM-THE-RECORD Align stand-in (S180 part C).

THE POINT OF THIS FILE. The capstone asks one question: *does the harness still
ask the captain for things whose answers are already in its own brief?* That is
only measurable if the thing standing in for the captain is INCAPABLE of
inventing an answer. A plausible-sounding stand-in would make the capstone pass
by fabrication, which is the exact failure the session exists to prevent.

So the stand-in never writes an answer. It only ever POINTS at one:

  tier 1 · RECORDED  a live `copilot -p` call picks the INDEX of one recorded
                     decision (or 0). The reply text we send is read off disk
                     from that entry — the model's own prose is discarded.
  tier 2 · QUOTED    no recorded decision fits, so the model returns verbatim
                     SPANS of the captain's own files. Every span is then
                     VERIFIED to appear byte-for-byte (whitespace-collapsed) in
                     the corpus; one span that does not verify collapses the
                     whole turn to NO-MATCH.
  NO-MATCH           the record does not settle it. Reachable, counted, and
                     fatal to a pre-Schedule run.

`closing:true` turns are handled DETERMINISTICALLY (empty answer → the daemon's
own proceed signal) and never reach the model, so "it's just a confirmation"
can never be a hole the matcher classifies its way out of.

CLI:
  python3 standin.py smoke [--record-dir DIR]   exercise the matcher cheaply
  python3 standin.py match --question "…"       one question, JSON to stdout
"""
import json, os, re, subprocess, sys

DEFAULT_RECORD_DIR = os.path.expanduser(
    "~/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002")

COPILOT_BIN = os.environ.get("LCARS_STANDIN_BIN", "copilot")
COPILOT_MODEL = os.environ.get("LCARS_STANDIN_MODEL", "claude-sonnet-4.5")
COPILOT_TIMEOUT = int(os.environ.get("LCARS_STANDIN_TIMEOUT", "300"))

# ── the record ──────────────────────────────────────────────────────────────

_RESOLVED = re.compile(r"^\s*-\s*RESOLVED with the captain:\s*(.+)$")
_ANSWERED = re.compile(r"^\s*ANSWERED by the captain:\s*(.+)$")


def _split_qa(body):
    """Split `<question> — <answer>` on the LAST separator that closes a question.

    The questions themselves contain em dashes ("Manual value entry — inline vs
    …? — Inline edit, autosaved"), so a first-match split silently truncates the
    question and hands the model half an answer. Prefer the last "? — ".
    """
    for sep in ("? — ", "? – ", "? — ", " — ", " – "):
        i = body.rfind(sep)
        if i != -1:
            cut = i + (1 if sep.startswith("?") else 0)
            off = len(sep) - (1 if sep.startswith("?") else 0)
            return body[:cut].strip(), body[cut + off:].strip()
    return body.strip(), ""


def load_record(record_dir):
    """→ {"entries":[{"n","question","answer","source"}], "corpus": str, "files":[…]}"""
    entries, corpus, files = [], [], []
    prd = os.path.join(record_dir, "prd.md")
    idea = os.path.join(record_dir, "idea.md")

    if os.path.exists(prd):
        files.append(prd)
        text = open(prd, encoding="utf-8", errors="replace").read()
        corpus.append(text)
        for line in text.splitlines():
            m = _RESOLVED.match(line)
            if not m:
                continue
            q, a = _split_qa(m.group(1))
            if q and a:
                entries.append({"question": q, "answer": a, "source": "prd.md"})

    if os.path.exists(idea):
        files.append(idea)
        text = open(idea, encoding="utf-8", errors="replace").read()
        corpus.append(text)
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = _ANSWERED.match(line)
            if not m:
                continue
            # walk back to this answer's "N. Q: …" block (may be wrapped)
            q, j = [], i - 1
            while j >= 0 and lines[j].strip() and not _ANSWERED.match(lines[j]):
                q.insert(0, lines[j].strip())
                if re.match(r"^\s*\d+\.\s*Q:", lines[j]):
                    break
                j -= 1
            qt = re.sub(r"^\s*\d+\.\s*Q:\s*", "", " ".join(q)).strip()
            if qt:
                entries.append({"question": qt, "answer": m.group(1).strip(),
                                "source": "idea.md"})

    # de-dup: idea.md re-states the first prd.md decisions verbatim
    seen, uniq = set(), []
    for e in entries:
        k = _norm(e["question"])[:120]
        if k in seen:
            continue
        seen.add(k)
        e["n"] = len(uniq) + 1
        uniq.append(e)
    return {"entries": uniq, "corpus": "\n".join(corpus), "files": files,
            "dir": record_dir}


# ── verbatim verification (tier 2's fence) ──────────────────────────────────

def _norm(s):
    return re.sub(r"\s+", " ", (s or "")).strip()


def verify_span(span, corpus):
    """True iff `span` occurs in `corpus` byte-for-byte, whitespace-collapsed."""
    s = _norm(span).strip("-•* ")
    if len(s) < 25:          # too short to be evidence of anything
        return False
    return s in _norm(corpus)


# ── the matcher ─────────────────────────────────────────────────────────────

_PROMPT = """You are matching a question to a RECORD of decisions a person \
already made. You are NOT answering the question and you MUST NOT compose an \
answer of your own.

=== THE RECORD — decisions the captain already made ===
{record}

=== THE QUESTION SOMEONE JUST ASKED HIM ===
{question}

=== YOUR JOB ===
Decide whether the record ALREADY SETTLES that question.

Reply with ONE json object and nothing else. Exactly one of these shapes:

  {{"match": <N>, "why": "<one short line>"}}
      N is the number of the ONE recorded decision that settles the asked
      question. Use this whenever a recorded decision answers it, even if the
      wording differs.

  {{"match": 0, "quotes": ["<verbatim span>", ...], "why": "<one short line>"}}
      No single recorded decision fits, BUT the captain's own written brief
      settles it. Each span MUST be copied CHARACTER FOR CHARACTER out of the
      SOURCE TEXT below — no paraphrase, no summary, no joining words of your
      own, no ellipses. 1 to 3 spans, each at least one full sentence. A span
      that is not an exact copy is a FAILURE and will be rejected.

  {{"match": 0, "quotes": [], "why": "<what is undecided>"}}
      THE RECORD DOES NOT SETTLE IT. Use this whenever the honest answer is "he
      never said". This is a NORMAL, EXPECTED, CORRECT reply — it is the whole
      reason you are being asked. Choosing a loosely-related decision, or
      quoting text that only touches the topic without deciding it, is WORSE
      than saying nothing. Do not stretch. Do not be helpful.

=== SOURCE TEXT (the only place a quote may come from) ===
{corpus}
"""


def _copilot(prompt):
    p = subprocess.run(
        [COPILOT_BIN, "-p", prompt, "--available-tools=", "--no-ask-user",
         "--disable-builtin-mcps", "--no-custom-instructions",
         "--model", COPILOT_MODEL],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL, timeout=COPILOT_TIMEOUT)
    return p.stdout.decode("utf-8", "replace")


def _extract_json(text):
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    for cand in (m.group(0), re.sub(r"```", "", m.group(0))):
        try:
            return json.loads(cand)
        except Exception:
            pass
    # last resort: the first balanced object
    depth, start = 0, None
    for i, ch in enumerate(text):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    return json.loads(text[start:i + 1])
                except Exception:
                    start = None
    return None


def render_record(rec):
    return "\n".join("%d. Q: %s\n   HIS ANSWER: %s"
                     % (e["n"], e["question"], e["answer"]) for e in rec["entries"])


def match(question, rec, closing=False):
    """Match one asked question against the record.

    Returns a dict that is BOTH the reply decision and the audit row:
      {"class": recorded|quoted|nomatch|closing|error, "entry": n|None,
       "answer": <text to send>, "why": …, "raw": <model reply>}
    The `answer` is NEVER model prose: it is a recorded entry's text, verified
    verbatim spans of the captain's files, or "" (proceed).
    """
    row = {"question": question, "class": None, "entry": None, "answer": "",
           "why": "", "raw": "", "quotes": [], "rejectedQuotes": []}
    if closing:
        row.update(cls="closing", why="closing turn — deterministic proceed")
        row["class"] = "closing"
        return row
    prompt = _PROMPT.format(record=render_record(rec), question=question,
                            corpus=rec["corpus"])
    try:
        raw = _copilot(prompt)
    except Exception as e:                      # noqa: BLE001
        row["class"], row["why"] = "error", "matcher call failed: %s" % e
        return row
    row["raw"] = raw[-4000:]
    d = _extract_json(raw)
    if not isinstance(d, dict):
        row["class"], row["why"] = "error", "matcher returned no parseable JSON"
        return row
    row["why"] = str(d.get("why", ""))[:400]
    try:
        n = int(d.get("match") or 0)
    except Exception:
        n = 0
    if n:
        hit = next((e for e in rec["entries"] if e["n"] == n), None)
        if hit:
            row.update(**{"class": "recorded", "entry": n,
                          "answer": hit["answer"]})
            return row
        row["why"] = "matcher named entry %d, which does not exist — %s" % (n, row["why"])
    quotes = d.get("quotes") or []
    if isinstance(quotes, str):
        quotes = [quotes]
    good = [q for q in quotes if verify_span(q, rec["corpus"])]
    bad = [q for q in quotes if q not in good]
    row["quotes"], row["rejectedQuotes"] = good, bad
    if good and not bad:
        row["class"] = "quoted"
        row["answer"] = " ".join(_norm(q) for q in good)
        return row
    row["class"] = "nomatch"
    if bad:
        row["why"] = ("matcher offered %d span(s) that are NOT in the captain's "
                      "files — rejected as fabrication. %s" % (len(bad), row["why"]))
    return row


# ── logging ─────────────────────────────────────────────────────────────────

class Log:
    """Every turn, on disk, in both machine and captain-readable form.

    "zero human answers" is a CLAIM. This file is the only thing that makes it
    checkable, so it records what was asked, what class it fell in, which
    recorded decision was pointed at, and the exact text that was sent back.
    """

    def __init__(self, out, append=False):
        self.jsonl = os.path.join(out, "standin-log.jsonl")
        self.txt = os.path.join(out, "standin-log.txt")
        self.rows = []
        if append:
            return          # a later phase writing into the SAME run's evidence
        open(self.jsonl, "w").close()
        open(self.txt, "w").write("STAND-IN TURN LOG — answers come from the "
                                  "record or not at all\n" + "=" * 72 + "\n")

    def add(self, turn, row, where="align"):
        row = dict(row, turn=turn, where=where)
        self.rows.append(row)
        with open(self.jsonl, "a") as f:
            f.write(json.dumps(row) + "\n")
        with open(self.txt, "a") as f:
            f.write("\n[%s turn %d] %s\n" % (where, turn, row["class"].upper()))
            f.write("  ASKED : %s\n" % _norm(row["question"])[:600])
            if row.get("entry"):
                f.write("  MATCH : recorded decision #%s\n" % row["entry"])
            if row.get("quotes"):
                f.write("  QUOTES: %d verbatim span(s) verified in the record\n"
                        % len(row["quotes"]))
            if row.get("rejectedQuotes"):
                f.write("  ✗ REJECTED %d span(s) NOT found verbatim: %s\n"
                        % (len(row["rejectedQuotes"]),
                           " | ".join(_norm(q)[:120] for q in row["rejectedQuotes"])))
            if row.get("why"):
                f.write("  WHY   : %s\n" % _norm(row["why"])[:400])
            f.write("  SENT  : %s\n" % (_norm(row["answer"])[:600]
                                        or "(empty — proceed)"))

    def counts(self):
        c = {"recorded": 0, "quoted": 0, "nomatch": 0, "closing": 0, "error": 0}
        for r in self.rows:
            c[r["class"]] = c.get(r["class"], 0) + 1
        c["turns"] = len(self.rows)
        # a human answer = a turn the record could not cover
        c["humanAnswers"] = c["nomatch"] + c["error"]
        return c

    def nomatch_questions(self):
        return [_norm(r["question"]) for r in self.rows
                if r["class"] in ("nomatch", "error")]


# ── CLI ─────────────────────────────────────────────────────────────────────

# Questions the record MUST cover (paraphrased on purpose — a matcher that only
# works on verbatim text proves nothing about a live grill) and questions it
# MUST NOT. The negative controls are the ones that matter: they are what makes
# a green capstone mean anything.
SMOKE_UNRECORDED = [
    "Which CI provider should run the build for this, GitHub Actions or CircleCI?",
    "How many days do you want to spend on this, and what is the deadline?",
    "Should the MBR builder ship with an audit log of who changed each KPI value, "
    "and how long should those records be retained?",
]


def _smoke(rec):
    ok = fail = 0
    print("RECORD: %d decisions from %s"
          % (len(rec["entries"]), ", ".join(os.path.basename(f) for f in rec["files"])))
    print("=" * 72)
    print("\nA. RECORDED questions — each must match its own entry")
    for e in rec["entries"]:
        r = match(e["question"], rec)
        hit = r["class"] == "recorded" and r["entry"] == e["n"]
        soft = r["class"] in ("recorded", "quoted")
        print("  %s #%-2d %s" % ("PASS" if hit else ("soft" if soft else "FAIL"),
                                 e["n"], _norm(e["question"])[:78]))
        if not hit:
            print("       → class=%s entry=%s why=%s"
                  % (r["class"], r["entry"], _norm(r["why"])[:120]))
        ok, fail = (ok + 1, fail) if soft else (ok, fail + 1)

    print("\nB. NEGATIVE CONTROLS — each MUST come back NO-MATCH")
    for q in SMOKE_UNRECORDED:
        r = match(q, rec)
        good = r["class"] == "nomatch"
        print("  %s %s" % ("PASS" if good else "FAIL ***", _norm(q)[:78]))
        if not good:
            print("       → class=%s entry=%s answer=%s"
                  % (r["class"], r["entry"], _norm(r["answer"])[:140]))
        ok, fail = (ok + 1, fail) if good else (ok, fail + 1)

    print("\nC. FABRICATION FENCE — a made-up 'verbatim' span must be rejected")
    fake = ("The captain decided the MBR builder will be rewritten in Rust and "
            "deployed to Kubernetes every Friday afternoon.")
    if verify_span(fake, rec["corpus"]):
        print("  FAIL *** an invented span verified against the corpus"); fail += 1
    else:
        print("  PASS invented span rejected"); ok += 1
    real = next(iter(re.findall(r"^- .{60,200}$", rec["corpus"], re.M)), None)
    if real and verify_span(real, rec["corpus"]):
        print("  PASS a real span still verifies"); ok += 1
    elif real:
        print("  FAIL *** a real span failed to verify: %r" % real[:80]); fail += 1

    print("\n" + "=" * 72)
    print("SMOKE: %d pass, %d fail" % (ok, fail))
    return 0 if fail == 0 else 1


def main(argv):
    sub = argv[1] if len(argv) > 1 else ""
    rd = DEFAULT_RECORD_DIR
    if "--record-dir" in argv:
        rd = argv[argv.index("--record-dir") + 1]
    rec = load_record(rd)
    if not rec["entries"]:
        print("NO RECORD FOUND under %s — nothing to answer from." % rd, file=sys.stderr)
        return 2
    if sub == "record":
        print(json.dumps(rec["entries"], indent=2))
        return 0
    if sub == "smoke":
        return _smoke(rec)
    if sub == "match":
        q = argv[argv.index("--question") + 1]
        print(json.dumps(match(q, rec), indent=2))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
