#!/usr/bin/env bash
# Preview only. Optional availability reads use the repository's gh seam.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIR/ruleset.json" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def die(message):
    print(f'ruleset dry-run: {message}', file=sys.stderr)
    raise SystemExit(1)


if any(arg in ('--apply', '--run', '--owner-opt-in') for arg in sys.argv[2:]):
    die("applying is the owner's decision; this tool is preview-only and refuses all apply/run requests, even with opt-in")

parser = argparse.ArgumentParser(description='Validate and preview a ruleset; never apply it.')
parser.add_argument('--ruleset', default=sys.argv[1], help='JSON body to validate')
parser.add_argument('--repo', default='roferg/LCARS', help='OWNER/REPO (default: roferg/LCARS)')
parser.add_argument('--dry-run', action='store_true', help='explicitly select the default preview-only mode')
parser.add_argument('--check-availability', action='store_true', help='optional read-only GET using LCARS_GH_BIN (default: gh)')
args = parser.parse_args(sys.argv[2:])
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+', args.repo) or args.repo.split('/')[1] in ('.', '..'):
    die('invalid repository; use OWNER/REPO')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def keys(value, required, optional=()):
    require(isinstance(value, dict), 'expected an object')
    require(set(required) <= set(value), f'missing required keys: {sorted(set(required) - set(value))}')
    require(set(value) <= set(required) | set(optional), 'unexpected keys in ruleset object')


try:
    body = Path(args.ruleset).read_text()
    data = json.loads(body)
    keys(data, ('name', 'target', 'enforcement', 'bypass_actors', 'conditions', 'rules'))
    require(isinstance(data['name'], str) and data['name'].strip(), 'name must be a nonempty string')
    require(data['target'] == 'branch', 'target must be branch')
    require(data['enforcement'] == 'active', 'enforcement must be active')
    require(data['bypass_actors'] == [], 'the contract permits no bypass actors')
    require(data['conditions'] == {'ref_name': {'include': ['~DEFAULT_BRANCH'], 'exclude': []}},
            'conditions must target only the default branch')
    require(isinstance(data['rules'], list) and len(data['rules']) == 2,
            'expected pull_request and required_status_checks rules')
    rules = {}
    for rule in data['rules']:
        keys(rule, ('type', 'parameters'))
        require(isinstance(rule['type'], str) and rule['type'] not in rules, 'invalid or duplicate rule type')
        rules[rule['type']] = rule['parameters']
    require(set(rules) == {'pull_request', 'required_status_checks'}, 'required rules are missing')
    pr = rules['pull_request']
    booleans = ('dismiss_stale_reviews_on_push', 'require_code_owner_review',
                'require_last_push_approval', 'required_review_thread_resolution')
    keys(pr, (*booleans, 'required_approving_review_count'))
    for field in booleans:
        require(type(pr[field]) is bool, f'{field} must be boolean')
    require(type(pr['required_approving_review_count']) is int and
            0 <= pr['required_approving_review_count'] <= 10,
            'required_approving_review_count must be an integer from 0 to 10')
    checks = rules['required_status_checks']
    keys(checks, ('required_status_checks', 'strict_required_status_checks_policy'))
    require(type(checks['strict_required_status_checks_policy']) is bool,
            'strict_required_status_checks_policy must be boolean')
    require(isinstance(checks['required_status_checks'], list) and checks['required_status_checks'],
            'at least one required status check is needed')
    for check in checks['required_status_checks']:
        keys(check, ('context',), ('integration_id',))
        require(isinstance(check['context'], str) and check['context'].strip(),
                'check context must be a nonempty string')
        if 'integration_id' in check:
            require(type(check['integration_id']) is int and check['integration_id'] > 0,
                    'integration_id must be a positive integer')
except (OSError, UnicodeError, ValueError) as error:
    die(f'invalid ruleset: {error}')

if args.check_availability:
    try:
        probe = subprocess.run([os.environ.get('LCARS_GH_BIN', 'gh'), 'api', '--method', 'GET',
                                f'repos/{args.repo}/rulesets'], text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        die(f'availability read failed: {error}')
    if probe.returncode:
        detail = probe.stderr + probe.stdout
        if '403' in detail and 'Upgrade to GitHub Pro or make this repository public' in detail:
            print('Expected private-plan limitation; live protection cannot be verified yet.', file=sys.stderr)
            print(detail.rstrip(), file=sys.stderr)
        else:
            die(f'availability read failed: {detail.strip()}')
    else:
        print('Read-only ruleset endpoint is available; enforcement is NOT verified.', file=sys.stderr)

print("DRY RUN - nothing sent; applying is the owner's decision.")
print('Method: POST')
print(f'Endpoint: repos/{args.repo}/rulesets')
print('Body:')
sys.stdout.write(body)
if not body.endswith('\n'):
    print()
PY
