# S346 plan-validator controls

These three JSON files are byte-preserved test data used by
`tests/plan-validator.test.sh`, not a retained test rig.

`vacuous-asset-plan.json` is a **RECONSTRUCTION**, not a recovered
pre-feedback plan. b151's `plan.json` and `approved-plan.json` were overwritten
identically; the original measurement texts survive only in the corrected
plan's `serves` fields.

`corrected-plan.json` retains the corrected plan; `corrected-declared.json`
declares its existing content criterion. Keep every array on one line:
the plan parser is line-oriented, and expanding these arrays changes what
the controls exercise.
