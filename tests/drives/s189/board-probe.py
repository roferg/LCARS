"""Is a mission on the VIEWSCREEN board? (S189 tester probe, read-only.)

`lcars status` reads state.json with sed and never notices malformed JSON; the
board's local adapter parses it with json.load and drops any mission it cannot
parse (`local_adapter._card` returns None). This probe is the difference.

    LCARS_SRC=<checkout> python3 board-probe.py <repo> <mission-id>
"""
import os
import sys

sys.path.insert(0, os.path.join(os.environ["LCARS_SRC"], "web"))
from lcars_serve.local_adapter import LocalAdapter  # noqa: E402

repo, mid = sys.argv[1], sys.argv[2]
try:
    board = LocalAdapter(repo).board()
    ids = [c["id"] for col in board["columns"].values() for c in col]
except Exception as exc:  # a broken board is a finding, not a crash
    print("ADAPTER-ERROR", type(exc).__name__, exc)
    raise SystemExit(0)
print("BOARD_IDS", ids)
print("PRESENT" if mid in ids else "MISSING")
