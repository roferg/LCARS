"""Build broken variants and run the same public controls against each one."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
ECH = "lcars-eeh/ech.sh"
DOC = "lcars-eeh/DELEGATION.md"
HCM = "lcars-eeh/HOLOGRAM-COMMAND-MODE.md"


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("expected exactly one mutation site: " + repr(old))
    return text.replace(old, new)


def run(name, file, edit, test):
    with tempfile.TemporaryDirectory(prefix="s373-mutant-") as directory:
        skills = Path(directory) / "skills"
        shutil.copytree(ROOT / "skills", skills)
        path = skills / file
        path.write_text(edit(path.read_text()))
        env = dict(os.environ, LCARS_TEST_SKILLS=str(skills))
        start = time.monotonic()
        result = subprocess.run(
            ["python3", str(ROOT / "tests/lib/cage.py"), "900",
             "bash", str(ROOT / "tests/chunking-decision.test.sh"),
             "ChunkingDecision.test_" + test],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=930)
        print("%s: %.1fs exit %s" % (name, time.monotonic() - start, result.returncode),
              flush=True)
        print(result.stdout, flush=True)
        if result.returncode != 1 or ("FAIL: test_" + test + " (") not in result.stdout:
            raise SystemExit("mutation proof failed: " + name)


pair = "pair_records_split_and_single_slice_before_real_filing"
checkpoint = "next_stops_at_the_decision_before_offering_file"
triggers = "only_the_five_declared_triggers_and_explicit_one_chunk_are_accepted"
reason = "reason_is_required_for_both_answers_and_refusals_write_nothing"
count = "count_is_positive_and_invalid_arguments_terminate_without_writing"
late = "decision_is_not_backfilled_after_a_mission_exists"
docs = "docs_put_the_decision_before_filing_and_define_the_axes"
baseline = "single_chunk_without_validator_is_byte_identical_from_the_base"

# Each variant runs only its designated control; a failure elsewhere cannot count.
def selected_run(name, file, old, new, test):
    run(name, file, lambda text: replace(text, old, new), test)


selected_run("record silently forces every answer to one chunk", ECH,
             'entry = {"chunks": a.chunks,', 'entry = {"chunks": 1,', pair)
selected_run("record silently forces every answer to split", ECH,
             'entry = {"chunks": a.chunks,', 'entry = {"chunks": 2,', pair)
selected_run("pre-filing history silently overwritten", ECH,
             'ledger = d.setdefault("chunkingLedger", {})',
             'd["chunkingLedger"] = ledger = {}', pair)
selected_run("pre-filing checkpoint skipped", ECH,
             '  if [ "$chunking_needed" = yes ]; then',
             '  if false; then', checkpoint)
selected_run("size-as-proxy admitted as a trigger", ECH,
             '"parallelism", "independence", "none"), required=True)',
             '"parallelism", "independence", "size", "none"), required=True)', triggers)
for trigger in ("not-estimable", "unit-of-work", "module-boundary",
                "parallelism", "independence"):
    selected_run("declared trigger removed: " + trigger, ECH,
                 '"' + trigger + '",', "", triggers)
selected_run("one-chunk reason silently discarded", ECH,
             '"why": a.why,', '"why": a.why if a.chunks > 1 else "",', pair)
selected_run("missing reason accepted", ECH,
             'p.add_argument("--why", required=True)',
             'p.add_argument("--why", default="an invented reason")', reason)
selected_run("blank and multiline reasons accepted", ECH,
             'if not a.why.strip() or a.why.splitlines() != [a.why]:',
             'if False:', reason)
selected_run("zero chunks accepted", ECH,
             'if a.chunks < 1:', 'if a.chunks < 0:', count)
selected_run("late decision backfilled", ECH,
             'if any(os.path.basename(os.path.dirname(path)) not in baseline for path in\n'
             '       glob.glob(os.path.join(missions, "*", "state.json"))):',
             'if False:', late)
selected_run("new run forgets its existing Missions", ECH,
             '"chunkingBaseline": sorted(os.path.basename(os.path.dirname(p)) for p in\n'
             '                             glob.glob(os.path.join(missions, "*", "state.json"))),',
             '"chunkingBaseline": [],',
             "new_run_still_decides_when_the_repo_has_older_missions")
selected_run("document omits the spike trigger", DOC,
             '**NOT ESTIMABLE**:', '**UNCERTAIN**:', docs)
selected_run("filing playbook never asks for a decision", HCM,
             '**CHUNKING DECISION FIRST,', '**Decomposition FIRST,', docs)
selected_run("ordinary driving-seat mint changes", ECH,
             '  say "MINTED: $did for $unit at tier $tier"',
             '  say "MINTED (broken): $did for $unit at tier $tier"', baseline)
selected_run("legacy main ECH unexpectedly demands a decision", ECH,
             '"chunkingBaseline" in d and not d.get("chunking")',
             'not d.get("chunking")',
             "legacy_main_ech_next_is_unchanged_without_a_decision")
print("20/20 broken variants rejected by their designated controls", flush=True)
