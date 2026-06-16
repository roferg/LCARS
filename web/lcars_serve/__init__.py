"""LCARS serve — the local read-only Kanban daemon (Python 3 stdlib only).

Modules:
  board         the adapter-neutral board shape + helpers (STAGES, normalise).
  local_adapter reads .git/lcars/missions/* into the board shape.
  github_adapter reads gh issues+labels into the SAME board shape.
  server        the http.server daemon serving static assets + the read API.
"""
