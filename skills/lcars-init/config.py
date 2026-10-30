#!/usr/bin/env python3
"""Validated config reads and atomic writes, preserving untargeted text on set."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate config key: {key}")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def parse(text):
    value = json.loads(text, object_pairs_hook=object_pairs,
                       parse_constant=invalid_constant)
    if not isinstance(value, dict):
        raise ValueError("config must be a JSON object")
    return value


def dump(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def spans(text):
    decoder = json.JSONDecoder()
    pos = text.index("{") + 1
    while True:
        while text[pos].isspace():
            pos += 1
        if text[pos] == "}":
            return
        key, pos = decoder.raw_decode(text, pos)
        while text[pos].isspace() or text[pos] == ":":
            pos += 1
        start = pos
        _, pos = decoder.raw_decode(text, pos)
        yield key, start, pos
        while text[pos].isspace():
            pos += 1
        if text[pos] == ",":
            pos += 1


def save(path, text, expected):
    if parse(text) != expected:
        raise ValueError("config read-back differs from requested settings")
    fd, temp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        if path.exists():
            os.chmod(temp, stat.S_IMODE(path.stat().st_mode))
        if parse(Path(temp).read_text()) != expected:
            raise ValueError("temporary config failed read-back")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    operation, filename, *args = sys.argv[1:]
    path = Path(filename)
    text = path.read_text() if path.exists() else "{}"
    data = parse(text)
    if operation == "get-raw":
        if args[0] in data:
            print(dump(data[args[0]]))
        return
    if operation == "merge":
        desired, dry = args
        merged, added, present = {}, [], []
        for pair in desired.splitlines():
            if not pair:
                continue
            key, default = pair.split("=", 1)
            if key in data:
                merged[key] = data[key]
                present.append(key)
            else:
                merged[key] = json.loads(default, parse_constant=invalid_constant)
                added.append(key)
        output = "{\n" + ",\n".join(
            "  " + dump(key) + ": " + dump(value) for key, value in merged.items()) + "\n}\n"
        if dry != "--dry-run":
            save(path, output, merged)
        print(" ".join(added))
        print(" ".join(present))
        print(output, end="")
        return
    key, value, after = args
    if not path.is_file():
        raise ValueError(f"config does not exist: {path}")
    value = (json.loads(value, object_pairs_hook=object_pairs,
                        parse_constant=invalid_constant) if operation == "set-raw" else value)
    entries = list(spans(text))
    replacement = dump(value)
    for name, start, end in entries:
        if name == key:
            text = text[:start] + replacement + text[end:]
            break
    else:
        for name, _, end in entries:
            pos = end
            while text[pos].isspace():
                pos += 1
            if name == after and text[pos] == ",":
                pos += 1
                text = text[:pos] + "\n  " + dump(key) + ": " + replacement + "," + text[pos:]
                break
        else:
            pos = text.index("{") + 1
            text = (text[:pos] + "\n  " + dump(key) + ": " + replacement
                    + ("," if data else "\n") + text[pos:])
    data[key] = value
    save(path, text, data)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"lcars config: {error}; nothing was written.", file=sys.stderr)
        sys.exit(1)
