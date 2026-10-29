#!/usr/bin/env bash
# dev/lanetest.sh — a lane runs one test file of its own, on a performance core when one of LANE_SLOTS is free
#
#   bash dev/lanetest.sh test/src/<file>.jl [args...]
#
# A lane's own test files ran at background QoS (taskpolicy -b), so with the corpus's shards and six lanes
# all on the six efficiency cores each ran at a third of its speed while the four performance cores sat idle
# between landings (march-monitor-a, 08:56: ten background Julia processes, none at normal priority). Two
# slots let two lanes' runs take performance cores; a third waits for none and runs at background QoS. A
# landing's check beside them runs slower on the clock but is judged by its instructions and CPU seconds
# (dev/check.sh), never by its wall time. The whole suite (test/src_tests.jl) is never a lane's run: it
# refuses at normal priority outside a landing. Every run has a hard limit (a hang is never allowed).
set -uo pipefail
LANE_SLOTS=2      # a literal: half the performance cores, the other half the landing check's
LANE_LIMIT=900    # seconds, a literal naming the file when it is passed
[ $# -ge 1 ] || { echo "lanetest: name a test file"; exit 2; }
case "$1" in */src_tests.jl) echo "lanetest: the whole suite is the landing check's run, never a lane's"; exit 2;; esac
cd "$(git rev-parse --show-toplevel)"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
slots="$common/wt-lanetest"; mkdir -p "$slots"
prefix="taskpolicy -b"; mine=""
# a landing's check running now holds the performance cores (a ratchet and three shards): no slot then, so
# the check keeps its cores (march-monitor-a, 08:58)
busy=0
for l in "$common"/wt-ship/*.lock; do
  [ -d "$l" ] || continue
  h=$(cat "$l/pid" 2>/dev/null || true); [ -n "$h" ] && kill -0 "$h" 2>/dev/null && busy=1
done
[ $busy -eq 1 ] || for s in $(seq 1 $LANE_SLOTS); do
  holder=$(cat "$slots/$s/pid" 2>/dev/null || true)
  [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null && rm -rf "$slots/$s"
  if mkdir "$slots/$s" 2>/dev/null; then echo $$ > "$slots/$s/pid"; mine="$slots/$s"; prefix=""; break; fi
done
[ -n "$mine" ] && trap 'rm -rf "$mine"' EXIT
echo "lanetest: $1 $([ -n "$mine" ] && echo "on a performance core (slot $(basename "$mine"))" || echo "at background QoS (both slots held, or a landing's check running)"), limit ${LANE_LIMIT}s"
perl -e 'alarm shift; exec @ARGV' "$LANE_LIMIT" $prefix julia --project=. --startup-file=no "$@"
rc=$?
[ $rc -eq 142 ] && echo "lanetest: $1 passed its hard limit of ${LANE_LIMIT}s"
exit $rc
