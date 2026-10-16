"""Preserve interrupted disk evidence, without producing a verdict or state."""

import json
import os
from pathlib import Path
import sys


def diagnostic(path, error):
    print(f"lcars xo: partial report: {path}: {error}", file=sys.stderr)


def read(path):
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    except (OSError, UnicodeError) as error:
        diagnostic(path, error)
        return ""


def preserve(mission):
    xo = mission / "xo"
    sections = []
    notes = read(xo / "notes.md")
    if notes.strip():
        sections.append("## Recorded notes (verbatim)\n\n" + notes)

    path = xo / "observations.json"
    text = read(path)
    if text.strip():
        try:
            data = json.loads(text)
            if not isinstance(data, dict) or not isinstance(data.get("observations"), list):
                raise ValueError("expected an object with an observations array")
            observations = []
            for index, observation in enumerate(data["observations"]):
                if not isinstance(observation, dict):
                    diagnostic(path, f"observation {index + 1}: expected an object")
                elif observation:
                    observations.append(observation)
            if observations:
                sections.append("## Recorded observations\n\n```json\n"
                                + json.dumps(observations, indent=2, ensure_ascii=False)
                                + "\n```")
        except (ValueError, TypeError) as error:
            diagnostic(path, error)

    path = mission / "number-one.jsonl"
    records = []
    for number, line in enumerate(read(path).splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("expected a journal object")
            # Test outcomes are evidence even without a detail sentence; setup
            # records such as launched/noted/stood-down are not findings.
            if record.get("action") in {
                "tested", "observed", "found", "touched", "paired", "steps-effect", "no-page"
            }:
                records.append(record)
        except (ValueError, TypeError) as error:
            diagnostic(path, f"line {number}: {error}")
    if records:
        sections.append("## Recorded journal evidence (number-one.jsonl)\n\n```json\n"
                        + json.dumps(records, indent=2, ensure_ascii=False) + "\n```")
    if not sections:
        return

    report = (
        "# INTERRUPTED — partial report\n\n"
        "This look was interrupted. This is partial disk evidence, not a completed verdict.\n"
        "No inferred score or merge recommendation is supplied. Checks not recorded here "
        "remain unverified; any next steps below are the original notes, not invented work.\n\n"
        + "\n\n".join(sections) + "\n"
    )
    destination = xo / "partial-report.md"
    staging = xo / f".partial-report.{os.getpid()}.md"
    try:
        xo.mkdir(exist_ok=True)
        with staging.open("x", encoding="utf-8") as output:
            output.write(report)
        os.replace(staging, destination)
    except OSError as error:
        diagnostic(destination, error)
        raise SystemExit(1)
    finally:
        try:
            staging.unlink(missing_ok=True)
        except OSError as error:
            diagnostic(staging, error)


if __name__ == "__main__":
    preserve(Path(sys.argv[1]))
