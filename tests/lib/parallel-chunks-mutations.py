"""Build each broken S372 variant and require its public control to reject it."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
ECH = "lcars-eeh/ech.sh"
RUN = "lcars-run/run.sh"
CONTEXT = "lcars-eeh/parallel-chunks.py"


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("mutation must replace exactly one site: " + repr(old))
    return text.replace(old, new)


def within(text, function, old, new):
    start = text.index("\n" + function + "() {") + 1
    end = text.index("\n}\n", start) + 3
    return text[:start] + replace(text[start:end], old, new) + text[end:]


def run(name, file, edit, test, suite="parallel-chunks"):
    with tempfile.TemporaryDirectory(prefix="s372-mutant-") as directory:
        skills = Path(directory) / "skills"
        shutil.copytree(ROOT / "skills", skills)
        path = skills / file
        original = path.read_text()
        changed = edit(original)
        if changed == original:
            raise ValueError("mutation changed nothing: " + name)
        path.write_text(changed)
        env = dict(os.environ, LCARS_TEST_SKILLS=str(skills))
        start = time.monotonic()
        result = subprocess.run(
            ["python3", "tests/lib/cage.py", "900", "bash",
             "tests/" + suite + ".test.sh", test],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=930)
        print("%s: %.1fs exit %s" % (name, time.monotonic() - start, result.returncode),
              flush=True)
        # Assertion tracebacks can contain a whole brief; retain the failure
        # name and clocks without flooding a caged run with repeated briefs.
        for line in result.stdout.splitlines():
            if line.startswith(("ELAPSED", "FAIL:", "ERROR:", "Ran ", "FAILED",
                                "  COLLISION:", "  RECOVERY REFUSAL:")):
                print(line, flush=True)
        if result.returncode != 1 or ("FAIL: " + test.split(".")[-1] + " (") not in result.stdout:
            print(result.stdout, flush=True)
            raise SystemExit("mutation proof failed: " + name)


brief = "ParallelChunks.test_parallel_brief_names_shared_cap_and_bounded_wait"
wait = "ParallelChunks.test_capped_seat_gets_a_runnable_bounded_exit_not_a_poll"
collision = "ParallelChunks.test_concurrent_chunks_collide_and_recovery_names_integration_owner"

run("parallel handoff omitted", CONTEXT,
    lambda s: replace(s, 'print("yes" if len(units) > 1 else "no")', 'print("no")'), brief)
run("cap refusal has no wait route", ECH, lambda s: within(
    s, "cmd_drive", "exec --await --limit 600", "no wait route"), wait)
run("expired wait reports success", ECH, lambda s: within(
    s, "cmd_seat_await", "return 124", "return 0"), wait)
run("expiry invites more polling", ECH, lambda s: replace(
    s, "Do not restart the wait or poll; hand this block back to the main ECH.",
    "Restart the wait and keep polling."), wait)
run("free slot claims a reservation", ECH, lambda s: replace(
    s, "this does not reserve a slot.", "your slot is reserved."), wait)
run("conflict has no integration owner", RUN, lambda s: within(
    s, "drive_base_recheck", 'if [ "$parallel" = yes ]; then',
    'if [ "$parallel" = never ]; then'), collision)
run("conflict is not parked", RUN, lambda s: within(
    s, "drive_base_recheck", 'lcars_state_set "$STATE" awaitingHuman true',
    ": # broken variant: no human gate"), collision)
run("solo brief polluted by parallel contract", CONTEXT,
    lambda s: replace(s, 'print("yes" if len(units) > 1 else "no")', 'print("yes")'),
    "ChunkHandoff.test_single_chunk_main_and_driver_match_pre_session_bytes",
    suite="chunk-handoff")
print("8/8 broken variants rejected by their designated controls", flush=True)
