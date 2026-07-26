---
name: lcars-viewscreen
description: Start the LCARS Kanban web board — the bridge **viewscreen**, a local, browser-based command-and-control view of every active Mission (PRD §5.1–5.2, §6; ADR-001/002/003/007). `lcars viewscreen` (alias `lcars serve`, the older power verb that still works) launches a Python-3-stdlib-only daemon (NO pip/npm/build step) that serves a vanilla LCARS-themed static front end rendering the Kanban board: all active Missions as cards in their correct Stage columns, each with one cost pill + two difficulty pills (reasoning + implementation, low=teal/med=amber/high=red), awaiting-you and paused card states, nested ticket rows, and Implement wave/ticket progress. `lcars viewscreen --open` is the one-command launcher — it boots on a free port and opens the board in your browser. It exposes a small read API (`GET /api/board`, `GET /api/mission/<id>`) plus a live channel (SSE) that pushes on state change, and — on the LOCAL adapter — operator write endpoints (file / start / pause / resume / respond / verify / log) that dispatch to the `lcars` skills; the GitHub adapter and `--read-only` keep it view-only. ONE adapter-neutral board shape backs two interchangeable read adapters (ADR-003): a LOCAL adapter parsing `.git/lcars/missions/*` (default) and a GITHUB adapter reading issues + `lcars:*` labels via `$LCARS_GH_BIN`; the front end depends only on the shape, so a hosted view-only build is a configuration away. Use when the captain runs `lcars viewscreen` or `lcars serve`, asks to open / start / launch the LCARS viewscreen / board / web UI / Kanban / dashboard in a browser, or wants a live visual view of the mission fleet.
---

# lcars viewscreen

`lcars viewscreen` starts the **LCARS Kanban interface** — the bridge
viewscreen, the browser-based command-and-control board promised in `vision.md`
→ *Future: The Kanban Interface*, specified in the Kanban PRD §5.1–5.2 and §6. It
removes the terminal from the daily glance: every active Mission shows as a card
in its Stage column, with its estimator pills, gate/paused state, nested tickets,
and live Implement progress, refreshing as the harness advances.

> **Power alias:** `lcars serve` is the older verb and **still works** (the LCARS
> "old verbs stay as power aliases" pattern). It execs the exact same launcher
> via a thin `serve.sh` shim next to `viewscreen.sh`, so any script or
> muscle-memory keeps working; the documented verb is now `lcars viewscreen`.

The bundled `viewscreen.sh` launches the daemon so the skill stays testable; you
(Claude) just announce the action, print the URL, and report.

## Start the board

```bash
lcars-viewscreen
# the power alias is identical: lcars-serve
```

> **From either CLI.** `lcars-viewscreen` (alias `lcars-serve`) is a real command
> on your `PATH` — `./install.sh` drops a wrapper into `~/.local/bin` that execs
> the repo's `viewscreen.sh` by absolute path, with no `~/.claude` (or
> `~/.copilot`) path. The daemon runs in the **foreground** and is
> **session-bound** — it stays up for that terminal session and closing the
> session stops the board. There is no separate stop command.
>
> **Run it from a plain terminal, NOT from inside a Claude Code / Copilot
> session.** An agent session is sandboxed, so the board would load but DEPLOY
> MAIN / `lcars launch` can't reach the desktop windowing session to actually
> start an app (mach_port 1100). So when `viewscreen.sh` detects an agent session
> (`CLAUDECODE=1`, or Copilot's `COPILOT_RUN_APP=1` / `COPILOT_CLI_BINARY_VERSION`)
> it **refuses to launch and prints a copy-paste `cd … && lcars-viewscreen --open`
> to run in a real terminal**, unless `LCARS_VIEWSCREEN_ALLOW_AI=1` is set (the
> bypass tests/automation use to boot a headless daemon deliberately).

This launches a **Python-3-stdlib-only** `http.server` daemon (no pip, no npm, no
build step — ADR-007) bound to `127.0.0.1:8765` by default, serving:

- `GET /` — the static, vanilla **Kanban board** (all nine Stage columns; each
  active Mission a card in its current Stage column with one **cost** pill + two
  **difficulty** pills — reasoning and implementation, low=teal/med=amber/high=red
  — an **AWAITING YOU** state when gated, a paused state, nested **ticket** rows,
  and an Implement **wave/ticket progress** strip). It shares ONE LCARS token
  stylesheet with `docs/lcars.css` (served at `/lcars.css`) — the palette is
  never forked.
- `GET /api/board` — the full **adapter-neutral board JSON**.
- `GET /api/mission/<id>` — mission detail including the **activity feed**.
- `GET /api/events` — a **live channel** (Server-Sent Events) that pushes exactly
  one update whenever Mission state changes on disk, so the board re-renders
  itself live.

### Operator actions (write layer — LOCAL adapter only)

The LOCAL-adapter daemon also serves the operator **write endpoints**, each of
which **dispatches to the matching `lcars` skill** (ADR-002 — the harness stays
the single implementation; the daemon never reimplements Stage logic):

- `POST /api/mission` — file a mission `{idea, engine?, type?}` → `file.sh`
- `POST /api/mission/<id>/start` — drive the run `{override?}` → `run.sh drive`
- `POST /api/mission/<id>/pause` / `…/resume` → `pause.sh`
- `POST /api/mission/<id>/respond` — answer a gate `{answer}` → `respond.sh`
- `POST /api/mission/<id>/verify` — `{decision:"approve"|"send-back", feedback?}`
  → `approve.sh` (approve) **or** `feedback.sh` (send-back)
- `POST /api/mission/<id>/log` — preview the linked bug missions (read)
- `POST /api/mission/<id>/log/run` — drive the logged bugs → `resolve-logs.sh`

Each returns `{ "ok": true, "state": … }`; a missing required field is `400` and
an unknown mission id is `404`. A write that changes `.git/lcars` moves the
adapter fingerprint, so the existing `/api/events` SSE channel pushes one update
and the board re-renders — no extra push path.

**View-only safety (ADR-006).** The write layer is a LOCAL-BRIDGE concern. The
GitHub adapter and an explicit `--read-only` flag run the daemon with **no write
layer**: the GET read/render path keeps working unchanged and every POST is
declined with `403`. So a hosted view-only build drops the write layer with no
rewrite.

Each skill path is **env-injected** (so tests stub it): `LCARS_FILE_SCRIPT`,
`LCARS_RUN_SCRIPT`, `LCARS_PAUSE_SCRIPT`, `LCARS_RESPOND_SCRIPT`,
`LCARS_APPROVE_SCRIPT`, `LCARS_FEEDBACK_SCRIPT`, `LCARS_LOG_SCRIPT`,
`LCARS_RESOLVE_SCRIPT` (defaults point at the installed `~/.claude/skills/…`).

### Enter the interface

```bash
lcars-viewscreen --open
```

`--open` boots the daemon on a **free port** (the OS assigns one; the daemon
reads it back), prints the resolved URL, and opens it in the system browser.
Auto-open is guarded by **`LCARS_SERVE_NO_OPEN`** so scripts/tests never spawn a
browser; `lcars viewscreen` with no `--open` stays **headless** on the fixed
port.

Open the printed URL (default `http://127.0.0.1:8765/`) in a browser. Stop with
Ctrl-C.

## Two adapters, one shape (ADR-003)

ONE adapter-neutral board shape backs two interchangeable read adapters; the
renderer depends only on the shape, never on which adapter served it — which is
what keeps a future view-only hosted build a configuration, not a rewrite:

- **LOCAL adapter (default)** — parses `.git/lcars/missions/*/{state,pending,
  plan,waves,estimate}.json` and `events.jsonl` directly for a low-latency board.
  It mirrors `status.sh`'s gate rule exactly: a Mission parked behind a gate
  stays in its **real in-flight Stage column** (from `pending.json.stage`, NOT
  the `state.json.stage` resume pointer) and renders the AWAITING-YOU state.
- **GITHUB adapter** — reads open issues + `lcars:*` labels (+ S65 mirrored
  comments) via `$LCARS_GH_BIN`, mapping them to the SAME board shape. This is
  the read path a hosted reader would use.

Select the adapter via flag or env (flag wins, then `LCARS_SERVE_ADAPTER`, then a
`serveAdapter` key in `.git/lcars/config.json`, else `local`):

```bash
lcars-viewscreen --adapter github
# or
LCARS_SERVE_ADAPTER=github lcars-viewscreen
```

## Options (all via flag or env)

- `--host` / `LCARS_SERVE_HOST` (default `127.0.0.1`)
- `--port` / `LCARS_SERVE_PORT` (default `8765`)
- `--adapter` / `LCARS_SERVE_ADAPTER` — `local` | `github`
- `--repo-root` / `LCARS_SERVE_REPO_ROOT` — the working tree whose `.git/lcars`
  the local adapter reads (defaults to the repo `lcars viewscreen` is run in)
- `--gh-bin` / `LCARS_GH_BIN` — the `gh` binary for the GitHub adapter
- `--gh-repo` / `LCARS_SERVE_GH_REPO` — `owner/name` for the GitHub adapter

## Report

After starting, tell the captain the board is live at the printed URL, which
adapter is serving, whether operator actions are available (LOCAL adapter) or it
is view-only (GitHub adapter / `--read-only`), and that it refreshes itself as
the harness advances. Stop with Ctrl-C.

## Implementation

The launcher is `viewscreen.sh` next to this file (with a thin `serve.sh` shim
preserving the `lcars serve` power alias — it just execs `viewscreen.sh`); the
daemon + static front end live in the repo's `web/` directory (Python package
`lcars_serve` + `web/static/` — the package name and the `LCARS_SERVE_*` env
names are intentionally unchanged; only the user-facing verb was renamed). Its
behaviour is covered by `web/tests/` (run with `cd web && python3 -m unittest
discover`) and a smoke test in `tests/lcars-viewscreen.test.sh` (run with `bash
tests/run.sh`). `LCARS_PYTHON_BIN`, `LCARS_WEB_DIR`, and `LCARS_GH_BIN` are taken
via env so tests can stub them. `./install.sh` both symlinks the skill in and
drops the on-PATH **`lcars-viewscreen`** launcher (alias `lcars-serve`) into
`~/.local/bin` — a generated wrapper that execs this repo's `viewscreen.sh` by
absolute path, so the one command works from any shell on either CLI and `git
pull` keeps it current with no re-install. Always edit the repo copy, never
`~/.claude` or `~/.copilot` (those are install targets only).
