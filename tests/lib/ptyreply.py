#!/usr/bin/env python3
"""Run a command with scripted answers delivered through a real terminal."""
import os
import pty
import subprocess
import sys

master, slave = pty.openpty()
try:
    os.write(master, sys.stdin.buffer.read())
    result = subprocess.run(sys.argv[1:], stdin=slave, timeout=120)
finally:
    os.close(slave)
    os.close(master)
sys.exit(result.returncode)
