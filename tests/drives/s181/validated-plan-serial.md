# Validated plan — a staged ingest pipeline

## What already exists (not built by this mission)

An existing Node + TypeScript service with its tooling established and green:
`package.json`, the lockfile, the test runner and its config, and the CI
workflow are all present and unchanged by this mission.

## The work

An ingest pipeline of twelve stages. Every stage after the first consumes the
type and the values the previous stage produces. No stage can be written,
typed, or tested before the stage ahead of it exists, because the shape it
consumes is DEFINED BY that prior stage and is not declared anywhere else.

1. **Raw reader** — reads the source file; defines and emits `RawRecord[]`.
2. **Normalizer** — consumes `RawRecord[]`; defines and emits `NormalRecord[]`.
3. **Validator** — consumes `NormalRecord[]`; defines and emits `ValidatedRecord[]`, rejecting bad rows.
4. **Deduplicator** — consumes `ValidatedRecord[]`; defines and emits `UniqueRecord[]`.
5. **Enricher** — consumes `UniqueRecord[]`; defines and emits `EnrichedRecord[]`.
6. **Grouper** — consumes `EnrichedRecord[]`; defines and emits `GroupedBatch`.
7. **Serializer** — consumes `GroupedBatch`; defines the on-disk `batch.json` format.
8. **Writer** — consumes the serializer's format; persists it to disk.
9. **Manifest builder** — reads what the writer persisted; emits `manifest.json`.
10. **Verifier** — reads `manifest.json`; re-checks it against the persisted batch.
11. **Reporter** — reads the verifier's result object; renders the run summary.
12. **Orchestrator** — wires the eleven stages above in order; tested end to end.

## How the stages relate to each other

Strictly in a line. Each stage reads the artifact the stage before it produced.
A stage's tests exercise it against the real output of its predecessor, not
against a hand-written stand-in, so the predecessor must be built and passing
first. There are no siblings anywhere in this mission.

## Risks

- The pipeline is only as correct as the type each stage publishes; a stage that
  guesses its input shape instead of importing the published one will compile
  and still be wrong.
