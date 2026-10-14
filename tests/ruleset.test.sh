#!/usr/bin/env bash
# Local-only ruleset preparation tests; every gh invocation uses a recorder.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RULESET = Path('.github/ruleset.json')
APPLIER = '.github/ruleset-dry-run.sh'


class RulesetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='.ruleset-test-', dir='tests')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.record = self.root / 'calls.jsonl'
        self.gh = self.root / 'gh'
        self.gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['GH_RECORD'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if os.environ.get('GH_RESPONSE') == '403':
    print('gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)', file=sys.stderr)
    sys.exit(1)
if os.environ.get('GH_RESPONSE') == '401':
    print('gh: Bad credentials (HTTP 401)', file=sys.stderr)
    sys.exit(1)
print('[]')
''')
        self.gh.chmod(0o755)
        self.env = dict(os.environ, LCARS_GH_BIN=str(self.gh.resolve()),
                        GH_RECORD=str(self.record.resolve()))

    def calls(self):
        if not self.record.exists():
            return []
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def assert_no_mutations(self):
        for args in self.calls():
            self.assertEqual(args[:3], ['api', '--method', 'GET'], args)
            self.assertFalse(any(arg in ('-f', '-F', '--field', '--raw-field', '--input')
                                 for arg in args), args)

    def run_applier(self, *args):
        result = subprocess.run(['bash', APPLIER, *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assert_no_mutations()
        return result

    def ruleset(self):
        return json.loads(RULESET.read_text())

    def invalid(self, data):
        file = self.root / 'invalid.json'
        file.write_text(data if isinstance(data, str) else json.dumps(data))
        result = self.run_applier('--ruleset', str(file))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('invalid ruleset', result.stderr)
        self.assertNotIn('Method: POST', result.stdout)
        self.assertEqual(self.calls(), [])

    def test_api_keys_and_default_branch_contract(self):
        data = self.ruleset()
        self.assertEqual(set(data), {'name', 'target', 'enforcement', 'bypass_actors',
                                     'conditions', 'rules'})
        self.assertTrue(data['name'])
        self.assertEqual(data['target'], 'branch')
        self.assertEqual(data['enforcement'], 'active')
        self.assertEqual(data['bypass_actors'], [])
        self.assertEqual(data['conditions'], {'ref_name': {
            'include': ['~DEFAULT_BRANCH'], 'exclude': []}})
        rules = {rule['type']: rule['parameters'] for rule in data['rules']}
        self.assertEqual(set(rules), {'pull_request', 'required_status_checks'})
        self.assertEqual(rules['pull_request'], {
            'dismiss_stale_reviews_on_push': False,
            'require_code_owner_review': False,
            'require_last_push_approval': False,
            'required_approving_review_count': 0,
            'required_review_thread_resolution': False})
        checks = rules['required_status_checks']
        self.assertIs(checks['strict_required_status_checks_policy'], False)
        # S283 filled the placeholder in. S282 shipped the ruleset with
        # `PLACEHOLDER-lcars-ci-required` precisely BECAUSE no CI job existed
        # yet to name; the context is now the real job id in
        # .github/workflows/ci.yml, and these two must not drift apart — a
        # required check naming a job that does not exist blocks every PR
        # forever.
        self.assertEqual(checks['required_status_checks'], [
            {'context': 'fast-suites'}])

    def test_required_check_names_a_job_that_actually_exists(self):
        """The required context must name a REAL job in ci.yml.

        A required status check naming a job that does not exist blocks every
        pull request forever, and nothing else in this repo couples the two
        files. Parsed without PyYAML (not in the runner's stdlib): find the
        `jobs:` block and collect its two-space-indented keys.
        """
        import pathlib, re as _re
        ruleset = json.loads(pathlib.Path(".github/ruleset.json").read_text())
        contexts = [c["context"] for r in ruleset["rules"]
                    if r["type"] == "required_status_checks"
                    for c in r["parameters"]["required_status_checks"]]
        wf = pathlib.Path(".github/workflows/ci.yml")
        self.assertTrue(wf.exists(), ".github/workflows/ci.yml is missing")
        lines = wf.read_text().splitlines()
        start = next(i for i, l in enumerate(lines) if l.rstrip() == "jobs:")
        jobs = []
        for l in lines[start + 1:]:
            if l.strip() and not l.startswith(" "):
                break
            m = _re.match(r"^  ([A-Za-z0-9_-]+):\s*$", l)
            if m:
                jobs.append(m.group(1))
        self.assertTrue(jobs, "no jobs parsed out of ci.yml")
        for ctx in contexts:
            self.assertIn(ctx, jobs,
                          f"required check {ctx!r} names no job in ci.yml (jobs: {jobs})")

    def test_default_is_dry_run_and_sends_nothing(self):
        result = self.run_applier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DRY RUN', result.stdout)
        self.assertIn('Method: POST\nEndpoint: repos/roferg/LCARS/rulesets\nBody:\n', result.stdout)
        self.assertEqual(json.loads(result.stdout.split('Body:\n', 1)[1]), self.ruleset())
        self.assertEqual(self.calls(), [])

    def test_explicit_dry_run_shows_exact_custom_endpoint_and_body(self):
        result = self.run_applier('--dry-run', '--repo', 'example/project')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Endpoint: repos/example/project/rulesets', result.stdout)
        self.assertEqual(json.loads(result.stdout.split('Body:\n', 1)[1]), self.ruleset())
        self.assertEqual(self.calls(), [])

    def test_apply_without_opt_in_is_refused_with_zero_calls(self):
        result = self.run_applier('--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owner's decision", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_run_request_is_refused_with_zero_calls(self):
        result = self.run_applier('--run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owner's decision", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_even_owner_opt_in_cannot_mutate(self):
        result = self.run_applier('--apply', '--owner-opt-in')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('preview-only', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_apply_refuses_before_read_only_probe(self):
        result = self.run_applier('--check-availability', '--apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_json_is_rejected_locally(self):
        self.invalid('{')

    def test_missing_api_key_is_rejected_locally(self):
        data = self.ruleset()
        del data['enforcement']
        self.invalid(data)

    def test_missing_rule_parameter_is_rejected_locally(self):
        data = self.ruleset()
        del data['rules'][0]['parameters']['require_last_push_approval']
        self.invalid(data)

    def test_wrong_parameter_type_is_rejected_locally(self):
        data = self.ruleset()
        data['rules'][0]['parameters']['required_approving_review_count'] = False
        self.invalid(data)

    def test_missing_required_check_is_rejected_locally(self):
        data = self.ruleset()
        data['rules'][1]['parameters']['required_status_checks'] = []
        self.invalid(data)

    def test_unknown_comment_key_is_not_sent_to_api(self):
        data = self.ruleset()
        data['comment'] = 'not an API field'
        self.invalid(data)

    def test_invalid_repository_is_rejected_with_zero_calls(self):
        result = self.run_applier('--repo', '../settings', '--check-availability')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid repository', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_optional_availability_probe_uses_only_injected_get(self):
        result = self.run_applier('--check-availability')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [['api', '--method', 'GET',
                                        'repos/roferg/LCARS/rulesets']])

    def test_private_plan_403_is_expected_not_a_failure(self):
        self.env['GH_RESPONSE'] = '403'
        result = self.run_applier('--check-availability')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Expected private-plan limitation', result.stderr)
        self.assertIn('HTTP 403', result.stderr)
        self.assertIn('DRY RUN', result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_other_probe_error_is_explicit_and_not_success(self):
        self.env['GH_RESPONSE'] = '401'
        result = self.run_applier('--check-availability')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Bad credentials (HTTP 401)', result.stderr)
        self.assertNotIn('Method: POST', result.stdout)


suite = unittest.defaultTestLoader.loadTestsFromTestCase(RulesetTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
print(f'ruleset: {result.testsRun - len(result.failures) - len(result.errors)} passed, '
      f'{len(result.failures) + len(result.errors)} failed')
raise SystemExit(not result.wasSuccessful())
PY
