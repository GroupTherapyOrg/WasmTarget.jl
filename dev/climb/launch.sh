#!/usr/bin/env bash
# dev/climb/launch.sh — start the climb (dev/climb/HILL.md), every part of it a program run by
# dev/climb/climb.py; no resident agent waits on anything.
#
#   bash dev/climb/launch.sh          stop the stale loops, queue the paused lanes' work, then start the loops in
#                                     the background: the scoreboard, a lander, and one loop per slot. Each loop runs
#                                     one iteration of climb.py per process, so every move, landing and score runs the
#                                     current code: a change to the climb needs no restart, and nothing waits for one
#   bash dev/climb/launch.sh stop     stop them and every claude and julia they started (each runs in its own
#                                     process group); a stopped move's work stays on its slot, salvaged next time
#   bash dev/climb/launch.sh pause    the climbers start no new move until `resume`
#   bash dev/climb/launch.sh resume
#   bash dev/climb/launch.sh status   the scoreboard (`python3 dev/climb/climb.py report`)
#
# Run it from a worktree at origin/wt2 (the one the driver's templates are read from).
set -uo pipefail
cd "$(dirname "$0")/../.."
common="$(git rev-parse --path-format=absolute --git-common-dir)"
state="$(dirname "$common")"; [ "$(basename "$common")" = .git ] || state="$common"
state="$(dirname "$state")/.wt-climb"; mkdir -p "$state/logs"   # outside the repository: no agent's sandbox can write it
py="python3 dev/climb/climb.py"
case "${1:-start}" in
  stop)
    for p in "$state"/pids/*; do
      [ -f "$p" ] || continue; pid=$(cat "$p")
      kill -TERM -- "-$pid" 2>/dev/null && echo "stopping $(basename "$p") and its children"
      for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -0 "$pid" 2>/dev/null && { kill -KILL -- "-$pid" 2>/dev/null; echo "  killed $(basename "$p") after 60 s"; }
      rm -f "$p"
    done
    exit 0 ;;
  pause)  touch "$state/PAUSE"; echo "paused: no new move starts"; exit 0 ;;
  resume) rm -f "$state/PAUSE"; echo "resumed"; exit 0 ;;
  status) $py report; exit 0 ;;
  start) ;;
  *) echo "launch: start|stop|pause|resume|status"; exit 2 ;;
esac
git fetch -q origin wt2
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/wt2)" ] || { echo "launch: this tree is not at origin/wt2; land the harness first"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
$py preflight --kill || true
sleep 10   # the stale loops exit before preflight looks again
$py preflight || { echo "launch: preflight still fails; fix what it names first"; exit 1; }
$py harvest
mkdir -p "$state/pids"
set -m   # each loop in its own process group, so `stop` ends a loop with the move it runs
loop() {   # a loop of one part, $1 its name, $2 its pause after an idle (exit 3) iteration, the rest its command
  local name=$1 idle=$2; shift 2
  ( while :; do PYTHONDONTWRITEBYTECODE=1 "$@"; rc=$?; [ $rc -eq 0 ] || sleep "$([ $rc -eq 3 ] && echo "$idle" || echo 30)"; done ) \
    >> "$state/logs/$name.log" 2>&1 &
  echo $! > "$state/pids/$name"; echo "started $name (pid $!, log $state/logs/$name.log)"
}
loop scoreboard 0 sh -c "$py score-tick; sleep 120"
loop lander 0 sh -c "$py lander; sleep 600"
for i in $(seq "$($py nslots)"); do loop "climb-$i" 120 $py slot "climb-$i"; done
# the judge's eval runs while the first score does (climbers wait for a scored head anyway); once, then on demand
[ -f "$state/judge-eval.json" ] || { nohup $py judge-eval > "$state/logs/judge-eval.log" 2>&1 & }
echo
$py report
