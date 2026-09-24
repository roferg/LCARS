#!/bin/bash
cd ~/Projects/DX-Scorecard || exit 9
a=$(ls node_modules | wc -l | tr -d ' '); b=$(shasum package-lock.json | cut -c1-12); npm ls --depth=0 >/dev/null 2>&1; c=$?; d=$(git status --porcelain | wc -l | tr -d ' ')
ok=OK; [ "$a" = 196 ] && [ "$b" = 844702627f6a ] && [ "$c" = 0 ] && [ "$d" = 0 ] || ok=CHANGED
echo "tripwire $ok: nm=$a lock=$b npmls=$c porcelain=$d procs=$(ps -A | wc -l | tr -d ' ') branch=$(git branch --show-current)"
