"""Presentation context only; never grants a seat or decides Mission ownership."""
import json
from pathlib import Path
import sys


record = Path(sys.argv[1]) / "autopilot.json"
data = json.loads(record.read_text()) if record.exists() else {}
units = {
    seat["unit"] for seat in (data.get("delegates") or {}).values()
    if seat.get("unit") and not seat.get("validates")
}
if len(sys.argv) > 2:
    units.add(sys.argv[2])
print("yes" if len(units) > 1 else "no")
