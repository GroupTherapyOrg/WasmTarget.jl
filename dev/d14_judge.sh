#!/bin/bash
# dev/d14_judge.sh <the check's exit status>: the status dev/ship.sh lands on (throughput P0, the owner's "STOP pausing
# EVER", 2026-11-13). D14's band judges a landing check's cost, and only a check that began and ended on a quiet
# machine is evidence of it. When the check read red on the band alone (dev/check.sh's 10) and the climb's lander
# named its question (WT_D14_ASK), this asks it (<ask>.req) and waits WT_D14_WAIT seconds for its answer (<ask>.ans):
# `judged` (the machine quiet at the check's start and its end) keeps 10, a D14 red as before; `unjudged` (not quiet
# at either end) gives 0, so the check lands on correctness alone (every test, the ratchet and the canaries passed:
# 10 is check.sh's last verdict, after all of them) and its time teaches nothing (the lander records it unjudged). No
# answer, or no question, keeps the status: the band applies, never a green past a gap (D9). Prints the status.
rc=$1
[ "$rc" = 10 ] && [ -n "${WT_D14_ASK:-}" ] || { echo "$rc"; exit 0; }
rm -f "$WT_D14_ASK.ans"; echo 10 > "$WT_D14_ASK.req"
for _ in $(seq "${WT_D14_WAIT:-120}"); do [ -s "$WT_D14_ASK.ans" ] && break; sleep 1; done
case "$(head -1 "$WT_D14_ASK.ans" 2>/dev/null)" in
  unjudged) echo "ship: the check read past D14's band on a machine not quiet at its start or its end: its time unjudged, it lands on its tests" >&2; echo 0 ;;
  *) echo 10 ;;
esac
