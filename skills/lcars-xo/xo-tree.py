#!/usr/bin/env python3
"""Who is still running — two ways of asking, in one file.

    closure <pid> <recorded-pgid> <asker-pid>
        every process the chain OWNS, walked DOWN from a recorded pid.
    census [<mission-id> [<tag>…]] [--tag T] [--seed PID[:PGID]] [--asker PID]
        every process ON THE MACHINE that belongs to one mission, found by
        PROVENANCE, union the recorded closure above.

WHY THE SECOND ONE EXISTS (S245). `closure` walks DOWN from a pid, and therefore
reports NOTHING the moment that pid dies — which is exactly the state a stop
creates. MEASURED: a stop killed the recorded group leader, printed
AFTER_COUNT=0, and two billable processes were alive the whole time. A
before/after walk rooted at a recorded pid does not fail in that situation; it
PASSES VACUOUSLY, and "I can no longer see anything" was read as "there is
nothing there". The fix is not a cleverer walk — a walk cannot reach a tree whose
root it has just removed. It is to stop starting from the root.

So `census` starts from PROVENANCE: a live process whose argv names the mission,
or one of the driver's own paths, IS this mission's process, whether or not
anything that spawned it is still alive, whether it sits at ppid 1, and whether
or not it leads a group of its own. That set SEEDS the same fixpoint `closure`
uses, so the unnamed leaves below it (a bare `copilot -p …`) still come along by
parenthood — and the recorded pids and groups from the pid files are unioned in,
so nothing `closure` could reach is lost.

RECORDED BEATS INFERRED, and here is the split, stated because the next reader
needs to know which half to trust:
  • RECORDED — the pids and the groups in `xo.pid` / `xo-resolve.pid`, written by
    `xo_write_pidfile` at the instant of the spawn and passed in as `--seed`.
    A recorded GROUP is honoured EVEN WHEN ITS LEADER IS DEAD, which is the
    dead-leader cure: the group was ours when it was written down, and a dead
    leader does not hand it to anybody else.
  • INFERRED — the argv match. It is the NET for what nobody wrote down (a
    worker minted after the pidfile, a stage orphaned to init). Because an
    inference over text eventually meets a human writing that same text, it is
    narrowed by a second, declared condition: the argv must ALSO name something
    LCARS launches (`$CENSUS_EXECS`). So `grep <mission-id>` in the captain's
    own shell is not a census member, and `run.sh drive --mission <id>` is.

WHAT IS NEVER IN EITHER SET — same rules as `closure`, applied to the seed and to
every expansion: pid 0 and 1; the asker and every ancestor of it; this walker
itself and everything it spawned; the asker's own process group.
"""
__doc_closure__ = """closure <pid> <recorded-pgid> <asker-pid> — every process the chain OWNS.

WHY A GRAPH WALK AND NOT A pgid (S240 fix round 5, D1). `lcars xo off` used to
stop a detached chain by signalling the one process group the pidfile recorded.
MEASURED live, immediately after such a stop said "you have the conn":

    pid     ppid    pgid    what
    31634   1       30311   run.sh drive --mission …    ← orphaned to init
    36323   31634   30311   run.sh validate …
    36610   36610   36610   worker-adapter.sh spawn copilot …   ← OWN group
    36662   36610   36610   copilot -p …                ← the PAID assistant

The worker is in a DIFFERENT process group ON PURPOSE: `skills/lcars-run/run.sh`
launches every worker through `perl -e 'use POSIX qw(setsid); … exec @ARGV'`
(run.sh:10000, :20068, :20221) so that nested workers which reparent, and the
forked test pools vitest/jest spawn, cannot outlive a stop. That is BUG-048's
cure and it is correct. The consequence is simply that `kill -<driver pgid>`
can never reach a worker, and a stop must therefore ENUMERATE.

So the chain is closed over two relations at once, to a fixpoint:

  • PARENTHOOD — every child of a member is a member.
  • GROUP MEMBERSHIP, but only for a group THE CHAIN LEADS — a group g is ours
    only when g is itself a pid in the set (a process group's id is its
    leader's pid), or when the pidfile recorded g as a group its own process
    leads. Parenthood alone is not enough: the stage above was at ppid 1, so
    walking down from the driver finds nothing, while its group still holds it.

NEITHER RELATION ALONE IS SUFFICIENT and that is the whole point. Parenthood
misses the orphan; the recorded group misses the worker.

WHAT IS NEVER IN THE SET, so a stop cannot shoot the captain:
  • pid 0 and pid 1;
  • the asking process, and every ancestor of it — the look that started the
    job, the shell `lcars xo off` was typed into, and the viewscreen above it;
  • the asker's own process group, which is never reported as ours to signal.
Those exclusions are applied to the SEED and to every expansion, so nothing
enters the set by a route that skips them.

A group is only ever reported when the chain genuinely leads it, so a caller
handed this output cannot kill a group it does not own.

Output, one fact per line, pids newest-first:
    PID <pid>        … a process to signal and then to check for
    GROUP <pgid>     … a whole group the chain owns and may be signalled
Exit 0 always; an empty output means "nothing of that chain is on the table".
"""
import os
import subprocess
import sys

# THE DECLARED LIST OF THINGS LCARS LAUNCHES. The argv half of the census is an
# inference, so it is narrowed by a fact: a census member is an LCARS process.
# This is the list of executables LCARS actually spawns — the drivers, the
# adapters, the walkers, and the two engines — and it is overridable from the
# environment so a test (or a future engine) never needs this file edited.
#
# `lcars` is deliberately NOT in it: every mission id begins with "lcars-", so
# that one token would match every argv the mission half already matched and the
# narrowing would be theatre.
CENSUS_EXECS = (
    os.environ.get("LCARS_XO_CENSUS_EXECS")
    or "run.sh xo.sh resolve-logs.sh worker-adapter.sh launch.sh "
       "xo-run.py xo-drive.js claude copilot"
).split()


def table():
    """Every live process as (pid, ppid, pgid), read from ps — never guessed."""
    try:
        out = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid=,pgid="],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        try:
            rows.append((int(f[0]), int(f[1]), int(f[2])))
        except ValueError:
            continue
    return rows


def table_args():
    """Every live process as (pid, ppid, pgid, argv-string) — read from ps."""
    try:
        out = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid=,pgid=,args="],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        f = line.split(None, 3)
        if len(f) < 4:
            continue
        try:
            rows.append((int(f[0]), int(f[1]), int(f[2]), f[3]))
        except ValueError:
            continue
    return rows


def protected(rows, askers):
    """pid 0, pid 1, every asker and every ANCESTOR of one, and this walker
    plus everything it spawned. Applied to the seed and to every expansion, so
    nothing enters the set by a route that skips it."""
    parent_of = {pid: ppid for pid, ppid, _, _ in rows}
    kids = {}
    for pid, ppid, _, _ in rows:
        kids.setdefault(ppid, []).append(pid)
    protect = {0, 1}
    # THIS WALKER'S OWN ANCESTRY, not just the declared asker. A command
    # substitution puts a SUBSHELL between the asker and this process, and that
    # subshell carries the asker's whole argv — the mission id included — so the
    # provenance half named it and the stop was handed its own fork to kill.
    # MEASURED: a census of a quiet mission reported exactly one pid, `argv`.
    askers = list(askers) + [os.getppid()]
    for a in askers:
        if not a:
            continue
        protect.add(a)
        cur, hops = a, 0
        while hops < 64:
            parent = parent_of.get(cur)
            if parent is None or parent in protect:
                break
            protect.add(parent)
            cur = parent
            hops += 1
    # EVERYTHING THIS WALKER SPAWNED, TOO: `ps` is a child of this process, and a
    # census that reported the tool it used to take the census would hand its
    # caller its own pid to kill.
    stack = [os.getpid()]
    seen = set()
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        protect.add(cur)
        stack.extend(kids.get(cur, ()))
    return protect


def names_mission(args, mission, tags):
    if mission and mission in args:
        return True
    for t in tags:
        if t and t in args:
            return True
    return False


def is_lcars_exec(args):
    for marker in CENSUS_EXECS:
        if marker and marker in args:
            return True
    return False


def census(mission, tags, seeds, askers):
    """Every live pid that belongs to this mission, by provenance UNION the
    recorded closure. Returns (found, owned, why)."""
    rows = table_args()
    kids, members, pgid_of = {}, {}, {}
    for pid, ppid, pgid, _ in rows:
        kids.setdefault(ppid, []).append(pid)
        members.setdefault(pgid, []).append(pid)
        pgid_of[pid] = pgid

    protect = protected(rows, askers)
    protect_groups = set(protect)
    for a in askers:
        if a and pgid_of.get(a):
            protect_groups.add(pgid_of[a])
    if pgid_of.get(os.getpid()):
        protect_groups.add(pgid_of[os.getpid()])

    found, owned, why = set(), set(), {}

    # ── THE RECORDED HALF. A pid file's pid, and the group it recorded.
    args_of = {pid: args for pid, _p, _g, args in rows}
    for pid, pgid in seeds:
        leader_live = bool(pid) and pid not in protect and pid in pgid_of
        if leader_live:
            found.add(pid)
            why.setdefault(pid, "recorded")
        # THE DEAD-LEADER CURE. A recorded group is honoured EVEN WHEN THE
        # LEADER IS DEAD — `xo_write_pidfile` only ever records a group the
        # process genuinely LED, so the chain created it, and a dead leader does
        # not hand its group to anybody else. This is the fact the old walk could
        # not use: it required the leader to be alive before it would look at the
        # group, and the stop had just killed the leader.
        #
        # ONE GUARD ON IT, because a pgid is a recycled number too: when the
        # leader is GONE, the group is claimed only if at least one of its live
        # members' argv names this mission. With the leader alive the pid file's
        # identity check (`xo_census_seed_file`) has already vouched for it.
        if not pgid or pgid in protect_groups or not members.get(pgid):
            continue
        if leader_live:
            owned.add(pgid)
            continue
        if not mission and not tags:
            # NOTHING TO CHECK IT AGAINST. The caller gave no mission and no tag
            # — `signal-pidfile` on a bare pid file does exactly that — so the
            # recorded group is all there is, and a record is better than a
            # refusal. MEASURED: without this, a stop driven through
            # `signal-pidfile` lost a whole orphaned group the moment the gentle
            # TERM took its leader, and reported success over a live assistant.
            owned.add(pgid)
            continue
        for m in members.get(pgid, ()):
            if m in protect:
                continue
            if names_mission(args_of.get(m, ""), mission, tags):
                owned.add(pgid)
                break

    # ── THE INFERRED HALF: the net for what nobody wrote down.
    for pid, _ppid, _pgid, args in rows:
        if pid in protect or pid in found:
            continue
        if not names_mission(args, mission, tags):
            continue
        if not is_lcars_exec(args):
            continue
        found.add(pid)
        why[pid] = "argv"

    # ── THE SAME FIXPOINT `closure` USES, over both seeds at once: every child
    #    of a member, and every group a member LEADS. That is what carries the
    #    unnamed leaves (a bare `copilot -p …`) along with their adapter.
    changed = True
    while changed:
        changed = False
        for m in sorted(found):
            for c in kids.get(m, ()):
                if c not in found and c not in protect:
                    found.add(c)
                    why.setdefault(c, "child")
                    changed = True
            g = pgid_of.get(m)
            if g and g not in owned and g not in protect_groups and g in found:
                owned.add(g)
                changed = True
        for g in sorted(owned):
            for p in members.get(g, ()):
                if p not in found and p not in protect:
                    found.add(p)
                    why.setdefault(p, "group")
                    changed = True
    return found, owned, why


def cmd_census(argv):
    mission, tags, seeds, askers = "", [], [], []
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--tag" and i + 1 < len(argv):
            tags.append(argv[i + 1]); i += 2; continue
        if a == "--asker" and i + 1 < len(argv):
            try:
                askers.append(int(argv[i + 1]))
            except ValueError:
                pass
            i += 2; continue
        if a == "--seed" and i + 1 < len(argv):
            spec = argv[i + 1]
            pid, _, pgid = spec.partition(":")
            try:
                p = int(pid)
            except ValueError:
                p = 0
            try:
                g = int(pgid) if pgid else 0
            except ValueError:
                g = 0
            if p or g:
                seeds.append((p, g))
            i += 2; continue
        if a.startswith("--"):
            i += 1; continue
        rest.append(a); i += 1
    if rest:
        mission = rest[0]
        tags.extend(rest[1:])
    if not mission and not tags and not seeds:
        sys.stderr.write(
            "usage: xo-tree.py census [<mission-id> [<tag>…]] "
            "[--tag T] [--seed PID[:PGID]] [--asker PID]\n")
        return 2

    found, owned, why = census(mission, tags, seeds, askers)
    for p in sorted(found, reverse=True):
        print("PID %d" % p)
    for g in sorted(owned):
        print("GROUP %d" % g)
    # WHY each one is here, for the reader of a failed stop. Prefixed so every
    # existing consumer (`sed -n 's/^PID //p'`) ignores it.
    for p in sorted(found, reverse=True):
        print("WHY %d %s" % (p, why.get(p, "?")))
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "census":
        return cmd_census(argv[2:])
    if len(argv) < 2 or argv[1] != "closure":
        sys.stderr.write(
            "usage: xo-tree.py closure <pid> <pgid> <asker-pid>\n"
            "       xo-tree.py census [<mission-id> [<tag>…]] "
            "[--tag T] [--seed PID[:PGID]] [--asker PID]\n")
        return 2
    try:
        seed = int(argv[2])
    except (IndexError, ValueError):
        return 0
    try:
        seed_pgid = int(argv[3])
    except (IndexError, ValueError):
        seed_pgid = 0
    try:
        asker = int(argv[4])
    except (IndexError, ValueError):
        asker = 0

    rows = table()
    kids, members, pgid_of = {}, {}, {}
    for pid, ppid, pgid in rows:
        kids.setdefault(ppid, []).append(pid)
        members.setdefault(pgid, []).append(pid)
        pgid_of[pid] = pgid

    # THE PROTECTED SET. The asker, everything it descends from, and init.
    parent_of = {pid: ppid for pid, ppid, _ in rows}
    protect = {0, 1}
    if asker:
        protect.add(asker)
        cur, hops = asker, 0
        while hops < 64:
            parent = parent_of.get(cur)
            if parent is None or parent in protect:
                break
            protect.add(parent)
            cur = parent
            hops += 1
    protect_groups = set(protect)
    if asker and pgid_of.get(asker):
        protect_groups.add(pgid_of[asker])

    if seed in protect or seed not in pgid_of:
        return 0

    found = {seed}
    owned = set()
    # The pidfile's own claim: a group recorded there counts as ours only when
    # the process it was written about genuinely LEADS it, which is the only
    # case `xo_write_pidfile` ever records. It is seeded separately because the
    # leader may already be dead while its group still holds the chain — which
    # is exactly the state the live stop left behind.
    if seed_pgid and seed_pgid == seed and seed_pgid not in protect_groups:
        owned.add(seed_pgid)

    changed = True
    while changed:
        changed = False
        for m in sorted(found):
            for c in kids.get(m, ()):
                if c not in found and c not in protect:
                    found.add(c)
                    changed = True
            g = pgid_of.get(m)
            if g and g not in owned and g not in protect_groups and g in found:
                owned.add(g)
                changed = True
        for g in sorted(owned):
            for p in members.get(g, ()):
                if p not in found and p not in protect:
                    found.add(p)
                    changed = True

    for p in sorted(found, reverse=True):
        print("PID %d" % p)
    for g in sorted(owned):
        print("GROUP %d" % g)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
