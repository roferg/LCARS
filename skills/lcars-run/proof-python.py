"""Observe code called during tests, not modules merely loaded by discovery."""
import contextlib
import functools
import inspect
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import sys
import unittest


class Calls:
    def __init__(self):
        self.paths = set()
        self.frames = []

    @contextlib.contextmanager
    def testing(self):
        self.frames.append(sys._getframe(2))
        try:
            yield
        finally:
            self.frames.pop()

    def during_test(self):
        if not self.frames:
            return False
        frame = sys._getframe(1)
        while frame is not None:
            if frame is self.frames[-1]:
                return True
            if frame.f_code.co_name == "<module>":
                return False
            frame = frame.f_back
        return False

    def started(self, code, offset):
        # Class/module bodies and comprehensions run while importing too.
        if code.co_flags & inspect.CO_NEWLOCALS and self.during_test():
            self.paths.add(str(Path(code.co_filename).resolve()))

    def calling(self, code, offset, function, arg):
        # A class with object.__init__ has no Python function-start event.
        if isinstance(function, type) and self.during_test():
            try:
                filename = inspect.getfile(function)
            except (TypeError, OSError):
                return
            self.paths.add(str(Path(filename).resolve()))

    def testing_call(self, function, *args, **kwargs):
        with self.testing():
            return function(*args, **kwargs)

    def wrap(self, function):
        @functools.wraps(function)
        def wrapped(*args, **kwargs):
            return self.testing_call(function, *args, **kwargs)
        return wrapped

    def start(self):
        monitoring = getattr(sys, "monitoring", None)
        self.tool = None
        if monitoring is None:
            print("proof-gate: sys.monitoring unavailable; helper calls cannot be observed",
                  file=sys.stderr)
            return
        self.tool = next((i for i in range(5, -1, -1)
                          if monitoring.get_tool(i) is None), None)
        if self.tool is None:
            print("proof-gate: no free sys.monitoring tool slot; helper calls cannot be observed",
                  file=sys.stderr)
            return
        monitoring.use_tool_id(self.tool, "lcars-proof")
        monitoring.register_callback(self.tool, monitoring.events.PY_START, self.started)
        monitoring.register_callback(self.tool, monitoring.events.CALL, self.calling)
        monitoring.set_events(self.tool, monitoring.events.PY_START | monitoring.events.CALL)
        # Discovery/imports happen outside these phases. Setup and cleanup code
        # belongs to the selected tests, but collecting a class does not.
        unittest.TestCase.run = self.wrap(unittest.TestCase.run)
        for name in ("_handleClassSetUp", "_handleModuleFixture",
                     "_tearDownPreviousClass", "_handleModuleTearDown"):
            setattr(unittest.TestSuite, name, self.wrap(getattr(unittest.TestSuite, name)))

    def stop(self):
        if self.tool is not None:
            sys.monitoring.set_events(self.tool, 0)
            sys.monitoring.free_tool_id(self.tool)


def observed_command(command, directory):
    suffix = ' || { rc=$?; [ "$rc" -eq 5 ] || exit "$rc"; }'
    body = command[:-len(suffix)] if command.endswith(suffix) else command
    try:
        args = shlex.split(body)
    except ValueError:
        return command
    if (len(args) < 3 or args[1] != "-m"
            or args[2] not in ("unittest", "pytest")
            or any(c in body for c in (";", "&", "|", ">", "<", "`", "$("))):
        return command
    words = list(re.finditer(r"""(?:[^\s'"\\]|\\[\s\S]|'[^']*'|"(?:\\[\s\S]|[^"\\])*")+""", body))
    if [shlex.split(w.group())[0] for w in words] != args:
        return command
    prefix = "{} {} run {} {}".format(
        words[0].group(), shlex.quote(str(Path(__file__).resolve())),
        shlex.quote(directory), shlex.quote(args[2]))
    return prefix + body[words[2].end():] + command[len(body):]


if sys.argv[1] == "command":
    print(observed_command(sys.argv[2], sys.argv[3]), end="")
elif sys.argv[1] == "read":
    root, directory = Path(sys.argv[2]).resolve(), Path(sys.argv[3])
    called = set()
    for record in directory.glob("*.json"):
        called.update(json.loads(record.read_text()))
    for relative in sys.stdin.read().splitlines():
        if relative and str((root / relative).resolve()) in called:
            print(relative)
elif sys.argv[1] == "run":
    directory, module = sys.argv[2:4]
    sys.argv = [module] + sys.argv[4:]
    # Match `python -m`: the repo's cwd, not this bundled script's directory.
    sys.path[0] = os.getcwd()
    calls = Calls()
    calls.start()
    try:
        if module == "pytest":
            import pytest

            class TestPhases:
                @pytest.hookimpl(wrapper=True)
                def pytest_runtest_setup(self):
                    with calls.testing():
                        return (yield)

                @pytest.hookimpl(wrapper=True)
                def pytest_runtest_call(self):
                    with calls.testing():
                        return (yield)

                @pytest.hookimpl(wrapper=True)
                def pytest_runtest_teardown(self):
                    with calls.testing():
                        return (yield)

            raise SystemExit(pytest.main(sys.argv[1:], plugins=[TestPhases()]))
        runpy.run_module(module, run_name="__main__", alter_sys=True)
    finally:
        calls.stop()
        if Path(directory).is_dir():
            (Path(directory) / ("%s.json" % os.getpid())).write_text(json.dumps(sorted(calls.paths)))
        else:
            # Recorded commands remain replayable after the gate's cleanup.
            print("proof-gate: call evidence directory was removed; no call evidence recorded",
                  file=sys.stderr)
