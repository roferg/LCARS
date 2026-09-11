# S196 tester drives — the handoff repairs, on the real surface

Built by the Session 196 TESTER sub-agent (captain stand-in). They **inherit**
`tests/drives/s189/lib.sh` (real `gh`, the real private fixture
`roferg/lcars-mp-fixture`, two real clones, both engines behind argv-recording
PATH shims) and `tests/drives/s190`'s daemon/Chrome discipline. Nothing here
rebuilds a rig that already existed.

    S189_HOME=/tmp/s189 bash tests/drives/s189/setup.sh     # once
    S189_HOME=/tmp/s189 bash tests/drives/s196/collision.sh # then any drive

| file | what it proves |
| --- | --- |
| `collision.sh` | **THE HEADLINE.** A git worktree of this repo at `8b6faf8` (pre-S196) files on BOTH clones, so two real laptops genuinely mint the identical LEGACY id. Laptop A then ships its mission for real (real branch, real PR, real `gh pr merge`), and adopts laptop B's colliding issue. The shipped mission's `state.json` must be BYTE-IDENTICAL afterwards and adopt must refuse, naming the mission it protected. |
| `widened-id.sh` | Two cold clones, same repo/user/host/day → DIFFERENT ids; the 4-hex tag really is `cloneId[0:4]` of a persisted uuid4, `cloneId` sits at the TOP of config.json, the two SHARED-REMOTE branch names differ; a mixed missions dir (legacy + fingerprinted + junk) sequences without an arithmetic error; and a LEGACY id still lists, still resolves and still adopts into a cold third clone under its ORIGINAL id. |
| `engine.sh` | Every engine claim **by invocation count**, with FULL ARGV recorded. Mission filed copilot + config claude → free 3 / billed 0; `$LCARS_WORKER_BIN` still outranks; copilot genuinely removed from PATH (`/opt/homebrew/bin` holds a REAL one — it cannot be on the drive PATH) → non-interactive adopt refuses and creates nothing; a REAL pty (`script`) → adopt ASKS, records `workerBin`/`engineSource`, and the converted engine then beats a disagreeing config.json 3–0. |
| `lock.sh` | `pause` / `resume` / `resolve-logs` refuse with the sentence `ownership.sh lock-reason` gives the board, compared BYTE for BYTE; the five older verbs still do; nothing moves on disk or on the forge; reads are never blocked; unassigned and an unreachable forge are never locks; `LCARS_OWNER_ENFORCE=0` is the only way past. |
| `attacks.sh` | A PRD that QUOTES a decoy `lcars:handoff` envelope (wrong id/branch/base/type/parent) — no decoy string may reach `state.json` and no decoy branch may be cut; a ONE-LINE `config.json` survives the lazy `cloneId` backfill as valid JSON; an unreachable `gh` mid-run must not ERASE the owner cache. |
| `rig.sh` | daemon + real headed Chrome on free ports, recorded PIDs only (never kill by name). |
| `shoot.js` | generic CDP driver: navigate, probe the live DOM, clip-screenshot any selector. |
| `measure.js` | median painted colour + WCAG contrast between two PNG crops (PNG reader lifted from `s190/owner-paint.js`). |
| `shots/` | the walkthrough captures — see the numbered names. |

## Traps this rig paid for — do not re-pay

* **`run.sh` takes a SUBCOMMAND**: `run.sh drive --mission <id> [--step]`, or a
  stage name (`research`). `run.sh --mission <id>` is "unknown subcommand", and a
  drive that greps its output for "no mission" will score that as a PASS.
* **A REAL `copilot` lives at `/opt/homebrew/bin/copilot`.** "Copilot is not on
  this machine" cannot be produced by shim juggling — homebrew's bin must be off
  PATH entirely, with `gh` symlinked into a private tools dir instead.
* **`command -v` reads bash's hash table**; a `PATH=… command -v copilot` probe
  needs `hash -r` first or it answers about the outer shell.
* **Drive a mission and it leaves `align`.** `adopt` then refuses it as
  mid-pipeline, which is correct and will look like the engine refusal you were
  testing for. Use a SECOND mission for the adopt legs.
* `lcars log` takes `--parent <id> --prd <file>`, never a bare sentence.
* `pause.sh` and `run.sh` both address BY BASENAME — a partial id is resolved by
  the front door (`skills/lcars/resolve.sh`), not by these scripts.
