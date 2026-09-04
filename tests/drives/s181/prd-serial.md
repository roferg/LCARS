# Mission: A staged ingest pipeline, each stage consuming the last

**Type:** feature

**Goal:** Build an ingest pipeline in an existing Node service. This is a
genuinely SEQUENTIAL mission: each stage reads the artifact the previous stage
produced and cannot be started, tested, or even typed before that artifact
exists. Nothing here is a sibling of anything else. A plan that flattens these
into parallel waves would be WRONG.

**Acceptance Criteria:**
- A **raw reader** module reads the source file and emits a `RawRecord[]` type it defines
- A **normalizer** consumes that `RawRecord[]` type and emits a `NormalRecord[]` type it defines
- A **validator** consumes `NormalRecord[]` and emits `ValidatedRecord[]`, rejecting bad rows
- A **deduplicator** consumes `ValidatedRecord[]` and emits `UniqueRecord[]`
- An **enricher** consumes `UniqueRecord[]` and emits `EnrichedRecord[]` with looked-up fields
- A **grouper** consumes `EnrichedRecord[]` and emits the `GroupedBatch` shape it defines
- A **serializer** consumes `GroupedBatch` and emits the on-disk `batch.json` format
- A **writer** consumes that serializer's output format and persists it
- A **manifest builder** reads what the writer persisted and emits `manifest.json`
- A **verifier** reads `manifest.json` and re-checks it against the persisted batch
- A **reporter** reads the verifier's result object and renders the run summary
- An **orchestrator** wires the eleven stages above in order and is testable end to end

**Out of Scope:**
- Any parallel or streaming execution model — the pipeline is strictly sequential
- Changing the test runner, build config, or package manifest
- A UI of any kind

**Constraints:**
- Each stage's input type is DEFINED BY the stage before it; no stage may guess
  or re-declare a type it consumes
- Each stage's tests exercise it against the real output of the prior stage
