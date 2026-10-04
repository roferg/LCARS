#!/usr/bin/env python3
"""closure <pid> <recorded-pgid> <asker-pid> — every process the chain OWNS.

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
import subprocess
import sys


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


def main(argv):
    if len(argv) < 2 or argv[1] != "closure":
        sys.stderr.write("usage: xo-tree.py closure <pid> <pgid> <asker-pid>\n")
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
