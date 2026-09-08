# S188 golden issue bodies — captured from PRE-session code

These five files are the EXACT bytes `gh` was handed as the issue body by each
filing lane in `skills/lcars-file/file.sh`, captured at commit `08eed26`
(VERSION 2026.9.3) **before** the S188 composer existed. They are the parity
lock for `lcars_issue_body_compose`: every lane's body must still start with
these bytes, and may differ only by the appended `lcars:handoff` envelope.

| file | lane | site (pre-S188) |
| --- | --- | --- |
| `laneA-park.body` | park (`--park`) | `file.sh:479` `gh issue create` |
| `laneB-complete-edit.body` | `--complete`, issue exists | `file.sh:669` `gh issue edit` |
| `laneC-complete-create.body` | `--complete`, no issue (gh down at park) | `file.sh:676` `gh issue create` |
| `laneD-prd-adr-est.body` | grill-first `--prd --adr` + estimate | `file.sh:1179` `gh issue create` |
| `laneD-prd-only.body` | grill-first `--prd`, no adr, no estimate | `file.sh:1179` (`BODY_FILE` = `prd.md` verbatim) |

Lanes B and D produce IDENTICAL bytes for identical inputs — that is the
invariant the composer now enforces structurally rather than by luck.

Regenerate ONLY by checking out pre-S188 code; a golden edited to match new
output is not a golden. `tests/handoff-payload.test.sh` drives them.
