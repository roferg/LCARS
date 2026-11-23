"""Run S369's controls on deliberately broken builds, never on the source tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BASE = "108bbe45b857d65a444133734bfa03edec29ab27"
ECH = "lcars-eeh/ech.sh"
SELECTOR = "lcars-eeh/mission-selector.py"
LOG = "lcars-log/log.sh"


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("mutation must replace exactly one site: " + repr(old))
    return text.replace(old, new)


def function(text, name):
    start = text.index("\n" + name + "() {") + 1
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def in_function(text, name, old, new):
    original = function(text, name)
    return replace(text, original, replace(original, old, new))


def change(path, edit):
    path.write_text(edit(path.read_text()))


def run(name, edits, tests):
    with tempfile.TemporaryDirectory(prefix="s369-mutant-") as directory:
        skills = Path(directory) / "skills"
        shutil.copytree(ROOT / "skills", skills)
        for file, edit in edits:
            change(skills / file, edit)
        env = dict(os.environ, LCARS_TEST_SKILLS=str(skills))
        env.pop("LCARS_ECH_SCRIPT", None)
        start = time.monotonic()
        result = subprocess.run(
            ["bash", str(ROOT / "tests/mission-selector.test.sh"),
             *("MissionSelector.test_" + test for test in tests)],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
        killed = [test for test in tests if "FAIL: test_" + test + " (" in result.stdout]
        print("%s: %.1fs exit %s; %d/%d controls failed as required" %
              (name, time.monotonic() - start, result.returncode, len(killed), len(tests)),
              flush=True)
        for test in killed:
            print("  RED test_" + test, flush=True)
        if result.returncode != 1 or len(killed) != len(tests):
            print(result.stdout)
            raise SystemExit("mutation proof failed: " + name)


baseline = subprocess.run(
    ["git", "show", BASE + ":skills/" + ECH], cwd=ROOT,
    capture_output=True, text=True, check=True).stdout
run("pre-S369 ECH", [(ECH, lambda _: baseline)], [
    "beat_requires_one_real_delegate_key_before_any_write",
    "file_bug_resolves_the_in_scope_issue_before_bounding",
    "heartbeat_does_not_confuse_a_repo_path_prefix_with_this_repo",
    "in_scope_title_selector_reaches_the_same_parent",
    "only_a_whole_run_wide_question_parks_everything",
    "revalidate_reports_entries_without_word_or_line_splitting",
    "scope_entry_newline_does_not_authorize_its_sibling_fragment",
])
run("target re-resolves", [(SELECTOR, lambda s: replace(
    s, 'handoff = os.environ.get("LCARS_MISSION_RESOLUTION")', "handoff = None"))], [
    "target_consumes_the_gate_resolution_without_a_second_lookup",
])
run("unbound handoff", [(SELECTOR, lambda s: replace(
    s, 'raise ValueError("Mission resolution does not match this target\'s selector")',
    "return result"))], ["a_handoff_for_another_selector_is_not_reused"])
old_resolve_logs = subprocess.run(
    ["git", "show", BASE + ":skills/lcars-resolve-logs/resolve-logs.sh"],
    cwd=ROOT, capture_output=True, text=True, check=True).stdout
run("duplicate resolver", [
    ("lcars-resolve-logs/resolve-logs.sh", lambda _: old_resolve_logs),
], ["log_and_resolve_logs_share_a_decoded_title_selector"])
for name, guard, test in (
    ("driver bounded", '[ "$ECH_AS" != d1 ]', "driver_keeps_its_loose_exec_lookup"),
    ("main bounded", '[ -n "$ECH_AS" ]', "main_keeps_its_loose_exec_lookup"),
):
    run(name, [(ECH, lambda s, guard=guard: in_function(
        s, "cmd_exec", '  subech_exec_target_or_die "$script"',
        '  ' + guard + ' || die "mutant: ordinary seat bounded"\n'
        '  subech_exec_target_or_die "$script"'))], [test])
run("fresh scope narrowed", [(ECH, lambda s: in_function(
    s, "val_scope", "    print(json.dumps(scope))",
    '    print(json.dumps(scope))\nelse:\n    print("[]")'))], [
    "first_pass_can_file_against_its_whole_chunk",
])
run("empty scope widened", [(ECH, lambda s: in_function(
    s, "val_scope", 'if "recheckScope" in v:', 'if v.get("recheckScope"):'))], [
    "empty_recorded_scope_is_not_a_fresh_pass",
])
run("malformed scope widened", [(ECH, lambda s: in_function(
    s, "val_scope", 'if "recheckScope" in v:',
    'if isinstance(v.get("recheckScope"), list) and v["recheckScope"] '
    'and all(isinstance(m, str) and m for m in v["recheckScope"]):'))], [
    "bad_scope_shape_is_refused_instead_of_widened",
])
run("guess a resolution", [(SELECTOR, lambda s: replace(
    s, "    if not matches:\n",
    '    matches = matches[:1] or [dict(binding, id="bug-001", '
    'mission=json.loads((root / "bug-001/state.json").read_text()))]\n'
    "    if not matches:\n"))], [
    "narrowed_validator_refuses_empty_ambiguous_and_unknown_selectors",
])
run("scope gate skipped", [(ECH, lambda s: replace(
    s, "validator_recheck_or_die() {", "validator_recheck_or_die() {\n  return 0"))], [
    "out_of_scope_aliases_are_refused_on_both_filing_doors",
])
run("descendants refused", [(ECH, lambda s: in_function(
    s, "validator_recheck_or_die", '    cur="${cur%.}"', '    cur=""'))], [
    "narrowed_validator_can_file_below_its_own_finding",
])
run("act gate skipped", [(ECH, lambda s: replace(
    s, "validator_act_or_die() {", "validator_act_or_die() {\n  return 0"))], [
    "every_other_allowlisted_script_is_refused_to_a_validator",
])
run("ordinary file-bug broadened", [(ECH, lambda s: in_function(
    s, "cmd_file_bug", '  if [ -n "$scope" ]; then', '  if true; then'))], [
    "top_level_and_driver_file_bug_keep_the_exact_parent_precheck",
])
run("parent JSON unescaped", [(LOG, lambda s: replace(
    s,
    '''    printf '  "parentMission": %s,\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PARENT_ID")"''',
    '''    printf '  "parentMission": "%s",\\n' "$PARENT_ID"'''))], [
    "a_whole_newline_scope_entry_can_receive_a_valid_linked_child",
])
run("ancestry trims newlines", [(ECH, lambda s: in_function(
    s, "validator_recheck_or_die",
    '''    cur="$(mstate "$cur" parentMission; printf '.')"\n    cur="${cur%.}"''',
    '''    cur="$(mstate "$cur" parentMission)"'''))], [
    "ancestry_does_not_trim_a_newline_into_an_in_scope_parent",
])
for flag, test in (
    ("-qx", "a_dot_in_an_identifier_is_not_a_regular_expression"),
    ("-qxF", "a_newline_in_a_selector_is_not_several_patterns"),
):
    bad_scope = '''scope_has() {
  local lines
  lines="$("$PY" -c 'import json,sys; print("\\n".join(json.loads(sys.argv[1])))' "$1")"
  printf '%s\\n' "$lines" | grep FLAG -- "$2"
}
'''.replace("FLAG", flag)
    run("pattern equality " + flag, [(ECH, lambda s, body=bad_scope: replace(
        s, function(s, "scope_has"), body))], [test])
run("marker parsed inside repo identity", [(ECH, lambda s: replace(
    s, '    owned = line.removesuffix("\\n").endswith(marker + " " + cwd)',
    '    _, separator, identity = line.removesuffix("\\n").rpartition(marker + " ")\n'
    '    owned = bool(separator) and identity == cwd'))], [
    "heartbeat_identity_may_itself_contain_the_marker",
])
