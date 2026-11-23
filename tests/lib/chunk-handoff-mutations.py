"""Build broken variants and require S370's public-interface controls to fail."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BASE = "b89dbeab58918a5160e0ab3953a5207edd042e40"
ECH = "lcars-eeh/ech.sh"
FILE = "lcars-file/file.sh"
LOG = "lcars-log/log.sh"


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("mutation must replace exactly one site: " + repr(old))
    return text.replace(old, new)


def function(text, name):
    start = text.index("\n" + name + "() {") + 1
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def run(name, file, edit, test):
    with tempfile.TemporaryDirectory(prefix="s370-mutant-") as directory:
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
            ["bash", str(ROOT / "tests/chunk-handoff.test.sh"), "ChunkHandoff.test_" + test],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
        print("%s: %.1fs exit %s" % (name, time.monotonic() - start, result.returncode),
              flush=True)
        print(result.stdout, flush=True)
        if result.returncode != 1 or ("FAIL: test_" + test + " (") not in result.stdout:
            raise SystemExit("mutation proof failed: " + name)


old_ech = subprocess.run(
    ["git", "show", BASE + ":skills/" + ECH], cwd=ROOT,
    capture_output=True, text=True, check=True).stdout
seedless = "seedless_owner_can_receive_one_sibling_validator"
concurrent = "concurrent_real_filings_never_transfer_to_the_other_seat"
goal = "chunk_goal_travels_in_both_tier_briefs_and_the_sibling_brief"

run("seed-only validator lookup", ECH, lambda s: replace(
    s, function(s, "chunk_seats"), function(old_ech, "chunk_seats")), seedless)
run("shared-directory attribution window", ECH, lambda s: replace(
    s, function(s, "cmd_exec"), function(old_ech, "cmd_exec")), concurrent)
run("PRD producer omits its receipt", FILE, lambda s: replace(
    s, '  printf \'%s\\n\' "$ID" >>"$LCARS_FILING_RECEIPT" || die "cannot write the filing receipt for $ID."\nfi',
    "  :\nfi"), concurrent)
run("park producer omits its receipt", FILE, lambda s: replace(
    s, '    printf \'%s\\n\' "$ID" >>"$LCARS_FILING_RECEIPT" || die "cannot write the filing receipt for $ID."\n  fi',
    "    :\n  fi"), "real_park_receipt_assigns_only_the_new_mission")
run("batch producer omits its receipts", LOG, lambda s: replace(
    s, '    printf \'%s\\n\' "$id" >>"$LCARS_FILING_RECEIPT" || die "cannot write the filing receipt for $id."',
    "    :"), "real_log_batch_receipts_keep_every_bug_with_its_driver")
run("chunk goal ignored", ECH, lambda s: replace(
    s, '  if [ -n "$chunk_goal" ]; then\n    gsrc="chunk-goal"',
    '  if false; then\n    gsrc="chunk-goal"'), goal)
run("goal can forge a brief section", ECH, lambda s: replace(
    s, '    ggoal="$(inert "$chunk_goal")"', '    ggoal="$chunk_goal"'), goal)
run("goal snapshot loses the handed-off bytes", ECH, lambda s: replace(
    s, '    printf \'%s\' "$chunk_goal" >"$ddir/GOAL.md"',
    '    printf \'%s\' "wrong goal" >"$ddir/GOAL.md"'), goal)
run("validator ignores the handed-off goal", ECH, lambda s: replace(
    s, '    if [ "$(ap_j "delegates.$VAL_DRIVER.goalSource")" = chunk-goal ]; then',
    '    if false; then'), goal)
run("blank goal accepted", ECH, lambda s: replace(
    s, '    [ -n "$(tr -d \'[:space:]\' <"$goal_file")" ] \\\n      || die "delegate: goal file is empty: $goal_file"',
    "    :"), "invalid_chunk_goal_is_refused_before_any_mint_write")
run("ordinary mint output changed", ECH, lambda s: replace(
    s, '  say "MINTED: $did for $unit at tier $tier"',
    '  say "MINTED (broken): $did for $unit at tier $tier"'),
    "single_chunk_main_and_driver_match_pre_session_bytes")
print("11/11 broken variants rejected by their designated controls", flush=True)
