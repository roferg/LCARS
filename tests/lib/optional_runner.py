"""Shared optional-runner preflight: unavailable means SKIPPED, never PASS/FAIL."""

import shutil
import subprocess


def runner_available(name, executable, dependency, remedy, *, results, module=None):
    reason = None
    if shutil.which(executable) is None:
        reason = f"{executable!r} is not available"
    elif module:
        try:
            probe = subprocess.run(
                [executable, "-c", "import " + module],
                capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            reason = str(error)
        else:
            if probe.returncode != 0:
                reason = " ".join((probe.stdout + probe.stderr).splitlines())
                if not reason:
                    reason = f"import {module} exited {probe.returncode}"
    if reason is None:
        return True
    message = f"missing optional dependency {dependency}: {reason}; {remedy}"
    results.append(dict(case=name, passed=False, skipped=True, reason=message))
    print("  SKIPPED", name, message, flush=True)
    return False
