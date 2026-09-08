# S188 tester drives — the issue as a handoff document

Built by the Session 188 TESTER sub-agent (captain stand-in), NOT by the
implementor. Every drive runs the REAL verbs (`file.sh`, `feedback.sh`,
`run.sh`) over real fixture repos; `gh` is a byte-exact argv-and-body-recording
stub and BOTH worker CLIs (`claude`, `copilot`) are PATH shims behind a spend
fuse. **Zero model tokens.** Nothing here touches github.com.

Run any of them directly: `bash tests/drives/s188/<drive>.sh`.

| drive | what it proves |
| --- | --- |
| `handoff-e2e.sh` | the captain's whole road: file → bounce ×2 → re-grill → Verify entry, with the recorded bodies to read |
| `lane-parity.sh` | every filing lane's body is BYTE-IDENTICAL to a clean pre-S188 checkout plus exactly `\n<envelope>\n` (7 lanes — `E-log`, the `lcars log` lane, added in fix round 1 when D2 brought it into the composer) |
| `midflight-silence.sh` | a real stage TRANSITION fires exactly one edit at the transfer point and zero elsewhere |
| `verify-entry.sh` | Verify entry pushes when the body changed, and nothing on a re-entry |
| `refresh-edges.sh` | the `.issue-body.sha` marker: failed push → no marker → retry; corrupt marker → re-push; temp-file hygiene on gh failure |
| `envelope-attacks.sh` | crafted PRDs / branch names vs the envelope and the parse helpers |
| `pill-scrape.sh` | the REAL `github_adapter._pills_from_body` over a REAL composed body, every level word |
| `feedback-mirror.sh` | one living comment, both entries, self-healing after a failed create |
| `logged-bug.sh` | the `lcars log` Mission lane (D2: no envelope at filing; D1: provenance lost at refresh) |
| `estimate-drop.sh` | can a refresh silently delete the `## Estimate` section (and every board pill) — D4 |
| `record-attacks.sh` | fix round 3: the CARRY-FORWARD itself — a PRD that carries an `## Estimate` heading (NEW-1) and documents the ADR field names (NEW-2), the ADR-removal decision (NEW-3), a 0-byte `adr.md`, and whether the composer's part record is honest about what it is |
| `guard-attacks.sh` | the round-1 regression guard turned on itself: false refusals (rule 2's exact 0.5 cliff, a PRD's own `---`), the heal path, whether a refusal halts a stage, and an absent / empty / stale `.issue-body.last` baseline (added by the VERIFICATION-round tester). **Round 2 re-aimed A0/A3/A6/A7/A9 at the part model that replaced that guard — see the header for what changed and why** |

`lane-parity.sh` needs a pre-S188 checkout. Make one and point at it:

    git worktree add --detach /tmp/wt-08eed26 08eed26
    LCARS_PRE_S188_WORKTREE=/tmp/wt-08eed26 bash tests/drives/s188/lane-parity.sh
    git worktree remove /tmp/wt-08eed26
