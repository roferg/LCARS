import os, signal, subprocess, sys, time
# cage.py TIMEOUT cmd...  -> own process group, SIGKILL the whole group on timeout
to = float(sys.argv[1]); cmd = sys.argv[2:]
t0 = time.time()
p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, start_new_session=True,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    out = p.communicate(timeout=to)[0]
    print("ELAPSED %.1fs EXIT %d" % (time.time()-t0, p.returncode))
    sys.stdout.write(out.decode("utf-8","replace"))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    print("ELAPSED %.1fs *** TIMED OUT -> HUNG (group killed) ***" % (time.time()-t0))
