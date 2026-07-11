# S111 spike — per-engine actual usage for a cold worker (DECISION NOTE)

Author-local decision record for the usage-and-progress round (S111–115). This
is the committed output of the **S111 HARD GATE**: *does each engine expose a
reliable way to know what one cold `-p` worker invocation actually consumed
(input/output tokens + model), without breaking the tools-denied / text-stdout
invariants or the `.worker.out` consumers?*

**Verdict: GATE PASSES.** Both claude and copilot have a viable, symmetric
mechanism. S112–S113 are UNBLOCKED. Real tiny `-p` calls were run against both
live CLIs (claude opus-4.8, copilot claude-opus-4.8); the raw usage-bearing
artifacts are captured (redacted) under `tests/fixtures/usage/`.

---

## The shape (identical for both engines)

The preferred mechanism — chosen over piping `--output-format json` to
`.worker.out`, which WOULD break the text consumers (test-writer read
run.sh:6808, empty-output run.sh:2566, hang-guard run.sh:8055) and is therefore a
spike FAIL per *What we are NOT changing* — is **side-channel session-file
parsing keyed by a minted `--session-id`**:

1. When usage capture is ENABLED, the worker-adapter mints a fresh UUID and
   passes `--session-id <uuid>` to the spawn. Both CLIs accept `--session-id` to
   *set the UUID for a new session* (verified in `--help` for both).
2. The primary stdout format is **UNCHANGED** — claude stays `--output-format
   text`, copilot stays `-s` silent. `.worker.out` therefore receives
   byte-identical content and EVERY consumer is untouched. The only argv delta
   is the added `--session-id` token.
3. After the worker exits, usage capture reads the CLI's own on-disk session
   artifact for that UUID (a SIDE channel — never the answer stream) and sums the
   per-turn usage. This is post-completion; there is no live cost ticker.

**Correlation key: the minted `--session-id`.** It is OUR id, deterministic, one
per spawn — not a guess against session history. This is what makes the
attribution "THIS worker, not the session's past" airtight.

**Invariant preservation.** `--session-id` is added ONLY when capture is enabled.
Capture off / unsupported → argv is byte-for-byte today's (the sacred no-usage
path holds; worker-adapter.test.sh stays green). Capture failing to find the
artifact NEVER fails a stage — it degrades to a `"source":"unavailable"` record.

---

## claude — mechanism

- **Artifact:** `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` — the session
  transcript. **Filename IS the minted session-id** (exact correlation). The
  `<cwd-slug>` is the worker's cwd with path separators slugified; derive it from
  the worker cwd, or glob `**/<session-id>.jsonl` (the UUID is unique).
- **Usage location:** each `assistant` line carries `message.usage`
  = `{input_tokens, output_tokens, cache_read_input_tokens,
  cache_creation_input_tokens, ...}` and `message.model`
  (e.g. `claude-opus-4-8`). A multi-turn worker (e.g. the Implementer with tool
  use) writes several `assistant` lines — **sum them**; model is per-line.
- **Cannot know:** the transcript has no per-line `total_cost_usd` (that field is
  `--output-format json`-only). Irrelevant — LCARS computes cost by code from
  `pricing.json` (reuse `cost_compute`/`cost_token_usd`), which needs only tokens
  + model. Both are present.
- **Fixtures:** `tests/fixtures/usage/claude-transcript.jsonl` (the preferred
  side-channel form), `tests/fixtures/usage/claude-output-json.json` (the
  `--output-format json` result object — recorded for reference; it carries the
  richest data incl. `total_cost_usd` + `modelUsage`, but is NOT the chosen path
  because it would clobber the text stdout consumers).

## copilot — mechanism

- **Artifact:** `~/.copilot/session-state/<session-id>/events.jsonl` — keyed by
  the minted session-id (the directory name). (`--log-dir` default
  `~/.copilot/logs/` is process-keyed, not session-keyed — do NOT use it.)
- **Usage location:** the terminal `session.shutdown` event's `data`:
  - `modelMetrics.<model>.usage` = `{inputTokens, outputTokens, cacheReadTokens,
    cacheWriteTokens, reasoningTokens}` — per-model, authoritative session totals.
  - `totalPremiumRequests` (legacy billing) and `totalNanoAiu` (usage/credit
    billing — nano-AI-Units, ÷1e9 for AIU) — copilot's NATIVE billing figures.
  - `currentModel` / per-event `assistant.message.model` for the model string
    (e.g. `claude-opus-4.8`).
- **Cannot know:** the shutdown totals are per-SESSION. A cold worker is exactly
  one session = one stage, so session-total == stage-total (safe). If the worker
  crashes before `session.shutdown` is written → no record → `unavailable`
  degrade. Per-turn splitting mid-session isn't needed (one stage per spawn).
- **`copilot billing` subcommand** (candidate c) was NOT chosen: account-level,
  lagged, and can't attribute to THIS run. Recorded only as a fallback.
- **Fixtures:** `tests/fixtures/usage/copilot-events.jsonl`,
  `copilot-events-2.jsonl`.

---

## usage.json schema (what S112 will write)

Sibling artifact to `estimate.json` — `$MISSION_DIR/usage.json`, **append one
record per cold-worker spawn** (never mutates the estimate). Each record:

```json
{
  "stage": "research",
  "role": "researcher",
  "engine": "claude",
  "model": "claude-opus-4-8",
  "inputTokens": 2,
  "outputTokens": 3,
  "cacheReadTokens": 16907,
  "cacheWriteTokens": 8660,
  "premiumRequests": 15,
  "sessionId": "<minted-uuid>",
  "source": "session-transcript",
  "ts": "2026-07-10T16:35:00Z",

  "billingUnit": "usd",
  "costUsd": 0.0951,
  "cost": 0.0951
}
```

- `source` ∈ `session-transcript` (claude) · `session-state` (copilot) ·
  `unavailable` (capture found nothing — tokens omitted/zero, stage still
  succeeded).
- `cacheWriteTokens` maps claude `cache_creation_input_tokens` / copilot
  `cacheWriteTokens`. `premiumRequests` is copilot-only (drives the legacy
  billing model). Fields absent when not applicable.
- **Cost is computed by code** from `pricing.json` (`cost_token_usd` + rates),
  NEVER read from the artifact — claude & copilot-usage both map tokens→USD via
  the opus/sonnet `inputPerMTok`/`outputPerMTok` (+ cacheRead/Write mults);
  copilot-legacy maps `premiumRequests`→USD via `premiumRequestMultiplier` +
  `overagePerRequest`. `billingUnit` records which unit the card should render
  (`usd` vs `premiumRequests`), matching the estimate pill's unit rules.

## Correlation-key summary (per engine)

| Engine  | Artifact                                             | Key            | Usage record                                  | Cannot know                        |
|---------|------------------------------------------------------|----------------|-----------------------------------------------|------------------------------------|
| claude  | `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`   | session-id = filename | sum `assistant.message.usage` lines; model per line | per-line USD (compute from tokens) |
| copilot | `~/.copilot/session-state/<session-id>/events.jsonl` | session-id = dir name | `session.shutdown.modelMetrics.<model>.usage` + `totalPremiumRequests`/`totalNanoAiu` | per-turn split (1 stage/session = moot) |
