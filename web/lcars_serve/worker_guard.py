"""The daemon's copy of THE ONE RULE for "may LCARS start this worker CLI?" (S217).

The rule, its reasons and its limits live in skills/lcars-init/worker-guard.sh;
this is the same rule for the places the daemon spawns a worker itself (the
warm Align / Log turn, the holodeck turn and its engine probe, the hand-off
derive pass) and for the START button, which refuses a drive it can see run.sh
would refuse. It is held to the bash copy by the parity checks in
tests/lcars-worker-guard.test.sh. Change one, change both.

PARITY MEANS THE BEHAVIOUR, NOT ONLY THE SENTENCE (S238 fix round 1). For a year
the parity loop compared the refusal TEXT byte for byte — and the two copies had
nonetheless diverged in what they DID: bash auto-repaired a shim-first PATH via
the S231 fallback while this file refused it, so the daemon refused to spawn
run.sh in exactly the case where run.sh would have started the real CLI. The
parity rows now compare rc, the bin chosen, and the note, because the sentence
being identical is what hid it.

NOTHING HERE EVER EXECUTES THE BINARY: `shutil.which`, `os.path.realpath` and a
64 KB read of a `#!` script are all it does.
"""

import os
import shutil

_SHIM_DIR = "/github.copilot-chat/copilotCli/"
_SHIM_MARKER = b"copilotCLIShim"

# Where the real CLI is assumed to live when PATH holds no non-shim `copilot`.
FALLBACK_DIR = "/opt/homebrew/bin"

# The ABSOLUTE locations a real CLI is looked for at before refusing a bare
# `copilot` that PATH-resolved to the shim — the bash rule's
# $LCARS_WORKER_BIN_FALLBACKS default, same list, same order. See fallback_bin.
FALLBACK_BINS = ("/opt/homebrew/bin/copilot", "/usr/local/bin/copilot")

# The daemon's own call-site hint (S238 fix round 1, D2). It names
# $LCARS_COPILOT_BIN — the one variable that cures this at a daemon call site,
# because the picker's bare engine NAME outranks $LCARS_WORKER_BIN but
# explicit_override below replaces that bare name with the file this variable
# points at. The PATH fix is the DAEMON's PATH, so the restart stays as the
# last step: both parts are true, and both are needed. Until this fix the hint
# was "restart the viewscreen" alone, so every daemon refusal sent the operator
# to reorder PATH and NEVER mentioned the variable he could not discover.
DAEMON_HINT = "LCARS_COPILOT_BIN restart the viewscreen"


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


def fallback_bin():
    """The first REAL (non-shim) `copilot` at a known ABSOLUTE location, or "".

    The bash rule's `lcars_worker_bin_fallback`, same contract: resolution only
    (lcars_worker_bin_resolve + the shim facts, nothing executed), a location
    that is ITSELF a shim is no fallback, and $LCARS_WORKER_BIN_FALLBACKS
    overrides the list — set-but-EMPTY means "no fallback", so a test can pin it
    off and never touch the captain's real install."""
    env = os.environ.get("LCARS_WORKER_BIN_FALLBACKS")
    cands = list(FALLBACK_BINS) if env is None else env.split()
    for c in cands:
        if not c:
            continue
        real = resolve(c)
        if not real or _is_shim(real):
            continue
        return c
    return ""


def shim_fallback(bin_):
    """(the bin to start, ONE note or "") — the S231 work-around, which the
    daemon's copy of the rule DID NOT HAVE until S238 fix round 1.

    THE DEFECT THIS CLOSES, MEASURED in the IDENTICAL shim-first PATH: the bash
    rule returned rc 0 and `/opt/homebrew/bin/copilot`, auto-repairing with zero
    configuration; this file REFUSED, with the PATH lecture, because FALLBACK_DIR
    was only ever used to WORD a refusal. So the daemon refused to spawn `run.sh`
    in exactly the case where run.sh itself would have shrugged and used the real
    CLI — a red card with `stageFailure=1` on POST /api/mission/<id>/start while
    POST /api/align/start worked. The parity test held the SENTENCE byte-identical
    and never noticed the BEHAVIOUR diverge; it now compares the behaviour.

    THE RULE, UNCHANGED FROM THE BASH COPY. A GUI/editor PATH commonly omits
    /opt/homebrew/bin, so a bare `copilot` that resolves to the shim is not yet
    doomed — the real CLI at a known absolute location was never looked for.
    When one is found, this returns IT plus one plain sentence saying so. With no
    real CLI anywhere it returns `bin_` untouched and the refusal below stands,
    and a bin someone named by PATH is never rescued this way (its slash sends it
    straight to the refusal, so the person fixes it where they set it).

    Nothing is executed here either: resolution and a 64 KB read.
    """
    bin_ = bin_ or ""
    if not bin_ or "/" in bin_:
        return bin_, ""
    real = resolve(bin_)
    if not real or not _is_shim(real):
        return bin_, ""
    fb = fallback_bin()
    if not fb:
        return bin_, ""
    return fb, ("Worked around VS Code's copilot shim (%s): starting the real "
                "CLI at %s in its place." % (real, fb))


def _is_var(hint):
    return (bool(hint) and "A" <= hint[0] <= "Z"
            and all("A" <= c <= "Z" or "0" <= c <= "9" or c == "_" for c in hint))


def editor_shim_refusal(bin_, hint=""):
    """"" when LCARS may start `bin_`; otherwise ONE plain sentence naming the
    path it resolved to and the fix — the caller refuses with it, pre-spawn.

    The fix leads with the one that works everywhere (PATH order; or, for an
    absolute bin, the real path in its place) and names a variable only when
    `hint` is a variable the caller knows wins at its call site; any other
    `hint` is appended as the last step (S217 fix round 1, D2). A hint that is
    a variable name FOLLOWED BY plain text gets both, in that order — the
    daemon's DAEMON_HINT is that shape (S238 fix round 1, D2).

    There is NOTHING to refuse when the S231 work-around applies: a bare name
    that hit the shim while a real CLI sits at a known absolute location is
    answered by `shim_fallback`, exactly as the bash rule answers it."""
    real = resolve(bin_)
    if not real or not _is_shim(real):
        return ""
    if shim_fallback(bin_)[1]:
        return ""
    d = real_dir()
    if "/" in (bin_ or ""):
        lead = "give LCARS %s/copilot in place of %s wherever that path was set" % (d, bin_)
    else:
        lead = "put %s ahead of it on PATH so `copilot` finds the real CLI first" % d
    tail = ""
    if hint:
        first, _sp, rest = hint.partition(" ")
        if _is_var(first):
            tail = (", or, when you run this from a terminal, prefix the "
                    "command with %s=%s/copilot" % (first, d))
            if rest:
                tail += ", then %s" % rest
        else:
            tail = ", then %s" % hint
    return ("Refusing to start %s: it resolves to %s, which is VS Code's own "
            "copilot shim, and with no real CLI behind it that shim prints an "
            "install prompt and exits 0 with no model output, so the turn looks "
            "like a success and is silently empty — %s%s."
            % (bin_, real, lead, tail))


# ── S238: AN EXPLICIT OVERRIDE BEATS A BARE ENGINE NAME ─────────────────────
# MEASURED (S238 gating spike). The board's New Mission / START ALIGNMENT picker
# always sends a bare engine NAME in the POST body ("copilot"), and every daemon
# spawn site resolves `engine or self.worker_bin` — so the picker's bare name
# OUTRANKS an operator's `LCARS_WORKER_BIN=/opt/homebrew/bin/copilot` with no
# effect and no warning. An operator who points LCARS at a binary he has just
# run by hand, and watches it be ignored in silence, cannot tell that apart from
# the binary being broken. That silence is the defect.
#
# WHY IT IS A SEPARATE, ENGINE-SPECIFIC VARIABLE AND NOT A PRECEDENCE CHANGE.
# Re-ordering `engine or self.worker_bin` would make the picker a decoration:
# a captain who chooses claude on the card would get whatever the daemon was
# started with. $LCARS_COPILOT_BIN says only "when something resolves to a bare
# `copilot`, THIS file is the copilot I mean" — the picker still chooses the
# ENGINE, this chooses the FILE. $LCARS_COPILOT_BIN is the name install.sh
# already uses for exactly that, so there is no second spelling to learn.
#
# IT ONLY EVER REPLACES A BARE NAME. A bin someone named by path (absolute or
# relative) is THEIR choice, late-bound to nothing, and is returned untouched —
# the shim guard above still judges it, and its refusal still sends them to the
# place they set it.
#
# AND IT IS NEVER SILENT. An override pointing at something that is not an
# executable file is REFUSED BY NAME, with the path quoted. Falling back to PATH
# there would re-create the very silence this exists to end.
#
# NOTHING HERE EXECUTES ANYTHING: os.path.isfile + os.access(X_OK).
OVERRIDE_VARS = (("copilot", "LCARS_COPILOT_BIN"),)


def override_var(bin_):
    """The env var that may name the FILE for engine `bin_`, or "" for none."""
    base = os.path.basename(bin_ or "").lower()
    for name, var in OVERRIDE_VARS:
        if name in base:
            return var
    return ""


def explicit_override(bin_):
    """(the bin to start, "") — or (bin_, ONE refusal sentence) when an operator
    pointed the override at something this machine cannot start.

    `bin_` is returned unchanged whenever there is nothing to say: it already
    names a path, no override variable covers that engine, or the variable is
    unset / empty ("no override", the same set-but-empty idiom
    $LCARS_WORKER_BIN_FALLBACKS uses).
    """
    bin_ = bin_ or ""
    if not bin_ or "/" in bin_:
        return bin_, ""
    var = override_var(bin_)
    if not var:
        return bin_, ""
    path = (os.environ.get(var) or "").strip()
    if not path:
        return bin_, ""
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        return bin_, (
            'Refusing to start %s: %s names "%s", which is not an executable '
            "file on this machine, and LCARS will not quietly ignore an engine "
            "you set and fall back to PATH — point it at the real CLI, or unset "
            "it to let PATH decide." % (bin_, var, path))
    return path, ""
