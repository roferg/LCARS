# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.7.1 — 2026-07-05

Genesis release: the LCARS harness through the image-paste round. LCARS is a
reusable AI harness that drives a human idea all the way to a merged PR through
the full pipeline — Align → Research → Validate → Plan → Plan Review → Schedule
→ Implement → Verify — with each headless stage spawned as a cold, isolated
worker. It runs on either supported CLI (dual-CLI: `claude` and `copilot`),
surfaces every active Mission on the viewscreen Kanban board, lets the captain
log bugs against an in-flight Mission and drive them through mission-log
grounding (a read-only worker anchors each symptom to the parent Mission's
existing code before a fix is planned), and accepts pasted images as Mission
input threaded through the cold stages. Full history prior to 2026.7.1 lives in
git — see `git log`.
