# tests/lib — shared test EQUIPMENT (not rigs)

A clone of LCARS has to stay testable (`CLAUDE.md`'s golden rule), so this is
the one place under `tests/` that carries executable helpers besides the
suites themselves.

## `MANIFEST` is the source of truth, not this table

`tests/lib/MANIFEST` is a **closed allow-list**: `tests/no-rigs.test.sh`
refuses any tracked path under `tests/lib/` that has no row in it, so a rig
cannot be smuggled in by dropping it beside the equipment. **A new file here
fails the build until you add a row.** That friction is the point.

The gate also checks each row's git mode and its `status` column, so the
inventory below cannot drift the way it did before: the earlier version of
this README stated a flat rule — *"everything here is sourced or exec'd by a
shipped suite"* — that three of its own entries did not meet, and nothing
checked the claim.

| file | status | who needs it |
|---|---|---|
| `cage.py` | exercised | `harness`, `lcars-buddy`, `lcars-xo-observe`, `lcars-xo-press`, `lcars-xo-phone`, `lcars-xo-evidence`, `lcars-xo-render-gate` |
| `drive-rig.sh` | exercised | `establish-vision`, `foundation-gate` (was `tests/drives/s182/rig.sh`) |
| `real-worker.sh` | exercised | `real-worker-resolution` |
| `phone-mkfixture.py` | exercised | `lcars-xo-phone` (was `tests/drives/s213/phone/mkfixture.py`) |
| `ptyrun.py` | exercised | `harness` |
| `stdin_guard.py` | exercised | `harness` (reached as `"$DIR/lib/stdin_guard.py"`, not by full path) |
| `shims/holodeck/copilot`, `shims/deploy-watcher/copilot`, `shims/align-heal-faultinj/copilot` | exercised | `lcars-worker-guard` — committed CLI stubs the worker guard must ALLOW |
| `shims/holodeck/claude`, `shims/deploy-watcher/claude` | **unused** | the claude half of each shim pair. **No suite runs these.** Kept because engines are separate end-to-end paths in LCARS and a copilot stub without its claude sibling is half a fixture — but they are exercised by nobody today, and the manifest says so out loud. |
| `README.md`, `shims/holodeck/README.md` | doc | documentation, not scanned either way |

## Equipment vs rig

A **rig** is one session's drive harness. Rigs are **not** committed to this
repo (captain's ruling, 2026-09-25) — they live in `lcars-dev/tests/drives/`,
and `tests/no-rigs.test.sh` fails the build if one reappears here under any
name. The dividing line is *declaration*, not a guess from the filename: if
it has a row in `tests/lib/MANIFEST` it is equipment, if it has a row in
`tests/fixtures/MANIFEST` it is fixture data, and everything else tracked
under `tests/` must be a `*.test.sh` suite or `run.sh`. Anything else is
refused by default.

`tests/fixtures/` is a **second closed inventory**, with its own manifest —
it was not always. It used to be open, with one narrow refusal on the exec
bit, and a fresh tester walked 120 real rig files through it at mode 644
while the gate printed the clean-tree tally: a rig script at 644 runs
perfectly under `bash`, and the recorded `.json`/`.log` artefacts that were
the actual bulk of the original 109 MB are inert data no exec-bit rule can
ever reach. So **a new fixture fails the build until you add a row to
`tests/fixtures/MANIFEST`**, exactly as a new file here does. The manifest
declares a mode as well as a path, so an executable or a symlink planted at
a declared path is still refused.

## `cage.py` — the one gotcha worth knowing

It is the process-group hang cage: `start_new_session=True`, `killpg` on
timeout, `stdin=DEVNULL`, and it prints `ELAPSED` so a fast pass is
distinguishable from a kill.

```
python3 tests/lib/cage.py 420 bash tests/<name>.test.sh
```

**It always exits 0.** Pass, fail and hang all come back as status 0 — the
verdict is in the text it prints (`EXIT <n>`, `*** TIMED OUT — exceeded the <d>s deadline ***`).
Never key a decision on `$?` from a caged run; parse the output.
