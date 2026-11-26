---
name: lcars-usage
description: >-
  Read the captain's Claude account allowance and gate another session with
  GO, HOLD, ASK or UNKNOWN. Reports the five-hour and weekly windows as a
  human line or normalized JSON, with a bounded credential read and request.
  Use when the captain runs `lcars usage`, asks how much Claude allowance is
  left, or needs an allowance gate before starting another session.
---

# lcars usage

The bundled `usage.sh` is the allowance reader. Run it and show the captain
its output verbatim; do not rebuild the credential or endpoint logic.
It needs Bash, Python 3 and curl. By default it reads Claude Code's OAuth
credentials from the macOS Keychain; it never refreshes them.

## Run it

The CLI-neutral ECH launcher reaches this skill by its physical sibling path
under either the Claude Code skill farm or the Copilot plugin mount:

```bash
lcars-ech usage read
lcars-ech usage read --json
lcars-ech usage gate --json --fresh
lcars-ech usage config
lcars-ech usage help
```

These are pass-throughs to `usage.sh read`, `gate`, `config` and `help`.
They work from any cwd, including outside a Git repo; allowance is an account
property, not a Mission record. No per-repo LCARS initialization is required.

## Verdicts and overrides

`read --json` returns `source`, `readAt`, `fiveHour`, `weekly` and `note`.
Each window has `pct` (0-100 or null) and `resetsAt` (epoch seconds or null).
`gate --json` adds the verdict, exit code, reason, stale age and thresholds.
Without `--json`, each verb prints one human line.

| Exit | Verdict | Meaning |
| --- | --- | --- |
| 0 | GO | The readable allowance permits another session. |
| 2 | HOLD | The five-hour limit refuses another session. |
| 3 | ASK | Ask the captain before starting another session. |
| 4 | UNKNOWN | A required allowance could not be read; never treat as GO. |
| 64 | Usage error | Invalid arguments, clock or destination; no verdict. |

The shipped `usage.json` sets five-hour GO at 70%, grace up to 80% when
resetting in under 45 minutes, and weekly ASK at 95%. HOLD outranks ASK,
which outranks GO. A plan that affirmatively reports no five-hour window
gates on the weekly number alone; an unreadable required number is UNKNOWN.
`config` prints the actual thresholds in force.

Manual overrides require a **pair** of percentages, never just one:

```bash
lcars-ech usage gate --five-hour 60 --weekly 10
lcars-ech usage gate --five-hour 78 --weekly 10 --five-hour-resets-in 20
```

`--five-hour-resets-in` is optional, accepts 0-600 minutes, and requires the
complete pair. Overrides make no credential or network read.

## Reads and hardening

- One endpoint request at most, with a five-second timeout and no retry loop.
  The ordinary cache lasts 180 seconds. `--fresh` bypasses that initial cache
  once and writes the answer back; it does not bypass validation or disable
  degraded reads. A failed request may use a cache or statusLine snapshot up
  to 15 minutes old; stale cached numbers are labeled. Otherwise: UNKNOWN.
- The bearer may only ever be sent to `https://api.anthropic.com` by the
  built-in request path. A different scheme or host, lookalike host, or URL
  containing whitespace or control characters exits 64 before a request is
  built. This assumes a trusted curl binary: `CHAIN_CURL_BIN` still receives
  the credential header file and could replay it elsewhere. That test seam is
  not an escalation; its caller can already read the credentials.
- `CLAUDE_CODE_OAUTH_TOKEN` overrides the Keychain. Otherwise the bounded
  Keychain read defaults to five seconds; expired credentials require signing
  in to Claude Code. The reader never refreshes or caches the token.
- The Authorization header travels in a mode-0600 file in a private temp
  directory, not curl's argv. It is removed on return and by exit cleanup.
  The bearer is not printed or stored in the usage cache.

## Configuration and test seams

`CHAIN_CONFIG` selects a thresholds file; the default is `usage.json` beside
the product script. `CHAIN_CACHE_DIR` selects the cache and optional
`statusline.json` snapshot directory (default `~/.cache/lcars/usage`).

For offline tests, inject `CHAIN_CURL_BIN` and `CHAIN_KEYCHAIN_CMD`.
`CHAIN_KEYCHAIN_TIMEOUT` bounds the credential read, `CHAIN_NOW` pins epoch
seconds, and `CHAIN_USAGE_URL` may select another path on the allowed host.
These existing names and all verbs and flags remain compatible with the
session-chain caller.
