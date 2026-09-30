"""The daemon's copy of THE ONE RULE for "may LCARS start this worker CLI?" (S217).

The rule, its reasons and its limits live in skills/lcars-init/worker-guard.sh;
this is the same rule for the three places the daemon spawns a worker itself
(the warm Align / Log turn, the holodeck turn, the hand-off derive pass). It is
held to the bash copy — same verdict, byte-identical sentence — by the parity
checks in tests/lcars-worker-guard.test.sh. Change one, change both.

NOTHING HERE EVER EXECUTES THE BINARY: `shutil.which`, `os.path.realpath` and a
64 KB read of a `#!` script are all it does.
"""

import os
import shutil

_SHIM_DIR = "/github.copilot-chat/copilotCli/"
_SHIM_MARKER = b"copilotCLIShim"

# Where the real CLI is assumed to live when PATH holds no non-shim `copilot`.
FALLBACK_DIR = "/opt/homebrew/bin"

# The daemon's own call-site hint: the picker's engine outranks
# $LCARS_WORKER_BIN here, so no variable is named — the PATH fix is the
# DAEMON's PATH, which only a restart picks up.
DAEMON_HINT = "restart the viewscreen"


def resolve(bin_):
    """The real file `bin_` would run, every symlink followed, or ""."""
    path = bin_ or ""
    if "/" not in path:
        path = shutil.which(path) or ""
        if "/" not in path:
            return ""
    if not os.path.exists(path):
        return ""
    return os.path.realpath(path)


def _is_shim(real):
    """True when the RESOLVED file is VS Code's shim by either recorded fact."""
    if _SHIM_DIR in real:
        return True
    try:
        with open(real, "rb") as fh:
            head = fh.read(65536)
    except OSError:
        return False
    return head.startswith(b"#!") and _SHIM_MARKER in head


def real_dir():
    """The first PATH dir whose `copilot` is NOT the shim (resolved, never
    run), else FALLBACK_DIR — the bash rule's lcars_worker_bin_real_dir."""
    for d in os.environ.get("PATH", "").split(":"):
        if not d:
            continue
        if d != "/" and d.endswith("/"):
            d = d[:-1]
        c = d + "/copilot"
        if not (os.path.isfile(c) and os.access(c, os.X_OK)):
            continue
        real = resolve(c)
        if real and not _is_shim(real):
            return d
    return FALLBACK_DIR


def _is_var(hint):
    return (bool(hint) and "A" <= hint[0] <= "Z"
            and all("A" <= c <= "Z" or "0" <= c <= "9" or c == "_" for c in hint))


def editor_shim_refusal(bin_, hint=""):
    """"" when LCARS may start `bin_`; otherwise ONE plain sentence naming the
    path it resolved to and the fix — the caller refuses with it, pre-spawn.

    The fix leads with the one that works everywhere (PATH order; or, for an
    absolute bin, the real path in its place) and names a variable only when
    `hint` is a variable the caller knows wins at its call site; any other
    `hint` is appended as the last step (S217 fix round 1, D2)."""
    real = resolve(bin_)
    if not real or not _is_shim(real):
        return ""
    d = real_dir()
    if "/" in (bin_ or ""):
        lead = "give LCARS %s/copilot in place of %s wherever that path was set" % (d, bin_)
    else:
        lead = "put %s ahead of it on PATH so `copilot` finds the real CLI first" % d
    tail = ""
    if hint:
        if _is_var(hint):
            tail = (", or, when you run this from a terminal, prefix the "
                    "command with %s=%s/copilot" % (hint, d))
        else:
            tail = ", then %s" % hint
    return ("Refusing to start %s: it resolves to %s, which is VS Code's own "
            "copilot shim, and that shim calls `copilot` back by name until the "
            "machine runs out of processes — %s%s." % (bin_, real, lead, tail))
