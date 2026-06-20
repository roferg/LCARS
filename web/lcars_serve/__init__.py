"""LCARS serve — the local Kanban daemon (Python 3 stdlib only).

Modules:
  board         the adapter-neutral board shape + helpers (STAGES, normalise).
  local_adapter reads .git/lcars/missions/* into the board shape.
  github_adapter reads gh issues+labels into the SAME board shape.
  actions       the LOCAL-BRIDGE write layer — dispatch operator POSTs to the
                `lcars` skill scripts (local adapter only; ADR-002/006).
  server        the http.server daemon serving static assets + the read API +
                (when an Actions is injected) the operator write endpoints.
"""
